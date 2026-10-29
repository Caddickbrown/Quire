//
//  JournalStore.swift
//  Quire
//
//  SwiftUI facade over Quire's Rust journal core. Swift owns folder access,
//  iCloud watching, widgets, backup scheduling and native media transcoding.
//  Parsing, migration and journal mutations go through CoreJournal / AppleVault.
//  Drafts: inbox/YYYY/MM/DD.md; filed: journal/YYYY/MM/DD.md;
//  split journals: split/<tag>/YYYY/MM/DD.md; sidecars: .quire/.
//

import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
#if os(iOS) || os(macOS)
import WidgetKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// How often Quire copies the journal folder to the backup location by itself.
enum BackupInterval: String, CaseIterable, Identifiable {
    case off, daily, weekly, monthly, onChange
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:      return "Off"
        case .daily:    return "Daily"
        case .weekly:   return "Weekly"
        case .monthly:  return "Monthly (30 days)"
        case .onChange: return "On every change"
        }
    }

    /// Seconds that must pass before another scheduled backup is due — nil for
    /// the settings that aren't time-based (`off`, `onChange`).
    var scheduledGap: TimeInterval? {
        switch self {
        case .daily:  return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        case .monthly: return 30 * 24 * 60 * 60
        default:      return nil
        }
    }
}

@MainActor
final class JournalStore: ObservableObject {

    // MARK: Published state
    @Published private(set) var inboxDrafts: [Entry] = []
    /// Filed days with a lightweight summary, newest first.
    /// Bumped on every reload so views can cheaply observe "data changed".
    @Published private(set) var revision = 0
    @Published private(set) var archiveDays: [ArchiveDay] = []
    /// False until the first index of the journal has been published, so a
    /// screen can say it is still reading rather than that nothing is there.
    @Published private(set) var indexed = false
    /// The parsed corpus (dated journal files), newest day first — built
    /// off-main with the index. The one copy every list reads from.
    @Published private(set) var archiveEntries: [(date: String, entries: [Entry])] = []
    /// Parsed split-journal entries, by journal name — same lifecycle.
    @Published private(set) var splitEntriesCache: [String: [Entry]] = [:]
    /// Total bytes reclaimed by Data Saver, merged across all devices (sum of
    /// every per-device record in `<base>/.quire/`). Recomputed on reload.
    @Published private(set) var dataSaved = 0
    /// Non-nil while a batch media compression runs, for a progress indicator.
    @Published private(set) var mediaProgress: (done: Int, total: Int)?
    /// The last read or write that didn't happen, phrased for a toast. Every
    /// edit path sets it instead of failing silently, so the UI can never show
    /// a change that never reached disk. Whoever displays it clears it.
    @Published var lastWriteError: String?

    struct ArchiveDay: Identifiable, Hashable {
        let date: String     // "YYYY-MM-DD"
        let count: Int
        let preview: String
        var hasPhoto = false
        var hasVideo = false
        var hasAudio = false
        var hasStarred = false
        var id: String { date }
        var year: String { String(date.prefix(4)) }
    }

    struct SplitJournal: Identifiable, Hashable {
        let name: String
        let count: Int
        var id: String { name }
    }

    /// All `@tags` (archive + inbox) with counts, cached — built off-main on reload.
    @Published private(set) var tagCounts: [(tag: String, count: Int)] = []
    /// Tag-routed split journals, cached — built off-main on reload.
    @Published private(set) var splitJournals: [SplitJournal] = []
    /// Where data actually lives once resolved; nil while still resolving, and
    /// nil for as long as `unavailableFolder` is set — a nil base is what stops
    /// every write path, so an unreachable folder can't be written around.
    @Published private(set) var baseURL: URL?
    /// Where journal data currently lives.
    @Published private(set) var storageMode: StorageMode = .local
    /// Name of the remembered custom folder when it can't be reached (the
    /// volume is unmounted, the folder was deleted, the bookmark is dead).
    /// Quire stops reading and writing until it's found again or the default is
    /// taken back — falling through to iCloud would quietly start a second
    /// journal, and the next launch would hide everything written into it.
    @Published private(set) var unavailableFolder: String?

    /// The unavailable-folder banner's copy, in one place.
    var storageUnavailableMessage: String? {
        guard let name = unavailableFolder else { return nil }
        return "Quire can't reach “\(name)”. Nothing is being saved until you find the folder again."
    }

    enum StorageMode: Equatable {
        case custom, iCloud, local
        var label: String {
            switch self {
            case .custom: return "Custom folder"
            case .iCloud: return "iCloud Drive"
            case .local:  return "On this device"
            }
        }
    }

    // MARK: Config
    /// Tags routed to `split/<tag>/YYYY/MM/DD.md` (jnl JNL_SPLIT_TAGS).
    /// Read live from the "splitTags" preference (space/comma separated).
    var splitTags: [String] {
        let raw = UserDefaults.standard.string(forKey: "splitTags") ?? ""
        return raw.split(whereSeparator: { $0 == " " || $0 == "," })
            .map { let s = String($0); return s.hasPrefix("@") ? s : "@" + s }
    }

    private let fm = FileManager.default
    private var cachedCore: (base: URL, journal: CoreJournal)?
    var core: CoreJournal? {
        guard let baseURL else { cachedCore = nil; return nil }
        if cachedCore?.base != baseURL { cachedCore = (baseURL, CoreJournal(base: baseURL)) }
        return cachedCore?.journal
    }
    func sidecarRecords(prefix: String) throws -> [Data] {
        guard let core else { throw JournalError.journalUnavailable }
        let rows: [String] = try core.call("records", ["prefix": prefix])
        return rows.map { Data($0.utf8) }
    }
    func readSidecar(name: String) throws -> Data? {
        guard let core else { throw JournalError.journalUnavailable }
        let current = try core.text(".quire/" + name)
        let text = current.isEmpty ? try core.text(".nook/" + name) : current
        return text.isEmpty ? nil : Data(text.utf8)
    }
    func writeSidecar(name: String, data: Data) throws {
        guard let core else { throw JournalError.journalUnavailable }
        try core.write(core.sidecar(write: true) + "/" + name, String(decoding: data, as: UTF8.self))
    }
    private var lastWritten: CoreWritten?
    private var composerEntry: Entry?

    /// Use the exact raw and location returned by Rust for the next autosave.
    func writtenEntry(fallback: Entry) -> Entry {
        guard let lastWritten, var e = JournalParser.parseEntries(lastWritten.raw).first else { return fallback }
        e.file = lastWritten.file; e.fileIndex = lastWritten.index
        return e
    }
    /// Editor writes return their own reference, never a shared last-write slot.
    /// A conflict leaves the caller's text and original reference untouched.
    func saveEditorEntry(_ original: Entry, source: EntrySource, text: String) -> (entry: Entry, source: EntrySource)? {
        guard let result = coreMutation({ try $0.update(original, text: text) }),
              var entry = JournalParser.parseEntries(result.raw).first else { return nil }
        entry.file = result.file
        entry.fileIndex = result.index
        let destination: EntrySource
        switch source {
        case .archive: destination = .archive(date: entry.date)
        default: destination = source
        }
        publishCoreChange()
        return (entry, destination)
    }

    /// Always inserts a distinct draft, including for explicit conflict recovery.
    /// Returns nil on failure instead of returning a previous timestamp as success.
    func createEditorDraft(timestamp: String, title: String, body: String) -> Entry? {
        let result: CoreWritten? = coreMutation { core in
            var ts = timestamp
            let used = Set(try core.inbox().map(\.ts))
            while used.contains(ts) {
                let next = Self.timestamp(after: ts)
                guard next != ts else { throw JournalError.journalUnavailable }
                ts = next
            }
            return try core.call("new", ["ts": ts, "title": title, "body": body])
        }
        guard let result, var entry = JournalParser.parseEntries(result.raw).first else { return nil }
        entry.file = result.file
        entry.fileIndex = result.index
        publishCoreChange()
        return entry
    }

    private func coreMutation<T>(_ action: (CoreJournal) throws -> T) -> T? {
        guard let core else { lastWriteError = "The journal folder is unavailable."; return nil }
        do {
            let result = try action(core)
            lastWriteError = nil
            lastLocalWriteAt = Date()
            journalDidChange()
            return result
        } catch { lastWriteError = journalErrorMessage(error); return nil }
    }
    private func publishCoreChange(reindex: Bool = true) {
        if reindex { loadInbox(); rebuildIndex() }
    }


    // Passing nil to the ubiquity API uses the app's first/default container.
    private let ubiquityContainerID: String? = nil
    /// Also read by the headless paths (App Intents), which resolve the folder
    /// themselves without an instance to ask.
    nonisolated static let bookmarkKey = "customFolderBookmark"
    /// Retained so we can release security-scoped access when the folder changes.
    private var securityScopedURL: URL?

    init() {
        loadLastBackupDate()
        resolveBaseAndReload()
    }

    #if DEBUG
    /// True only for a store built by `init(testingBase:)`.
    private var isTestStore = false

    /// A store rooted at `base`, for tests.
    ///
    /// It deliberately skips folder resolution, so it can never reach iCloud
    /// or the user's real journal, and starts no sync watcher and no backup
    /// timer. It also suppresses the share drain: that moves whatever the
    /// share extension has captured into the base folder, and a test run must
    /// not swallow the pending shares of whoever is running it.
    init(testingBase base: URL) {
        isTestStore = true
        try? fm.createDirectory(at: base.appendingPathComponent("journal", isDirectory: true),
                                withIntermediateDirectories: true)
        baseURL = base
        storageMode = .local
        reload()
    }
    #endif

    // MARK: Base directory resolution (custom folder → iCloud → local)

    /// `url` is nil only when a custom folder is remembered but unreachable —
    /// `unavailable` then names it for the banner.
    struct Resolved {
        let url: URL?
        let mode: StorageMode
        let scoped: Bool
        var unavailable: String? = nil
    }

    private func resolveBaseAndReload() {
        // Both the bookmark resolve and forUbiquityContainerIdentifier can block,
        // so do them off the main actor.
        let containerID = ubiquityContainerID
        let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey)
        Task { [weak self] in
            let resolved = await Task.detached(priority: .userInitiated) {
                Self.resolveBase(bookmark: bookmark, containerID: containerID)
            }.value
            self?.applyResolved(resolved)
        }
    }

    private func applyResolved(_ resolved: Resolved) {
        composerEntry = nil; lastWritten = nil; cachedCore = nil
        lastHeavyStats = HeavyStats()
        inboxDrafts = []; archiveDays = []; archiveEntries = []; splitEntriesCache = [:]
        splitJournals = []; tagCounts = []
        if let old = securityScopedURL {
            old.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
        unavailableFolder = resolved.unavailable
        storageMode = resolved.mode
        guard let url = resolved.url else {
            // Nothing to watch and nothing to write. `reload()` clears the
            // caches through its nil-base guards, so no view shows entries
            // from a folder we can't currently reach.
            baseURL = nil
            stopSyncWatcher()
            reload()
            return
        }
        if resolved.scoped, url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
        baseURL = url
        try? fm.createDirectory(at: url.appendingPathComponent("journal"),
                                withIntermediateDirectories: true)
        Self.sweepStaleTempFiles(under: url)
        startSyncWatcher()
        reload()
    }

    /// Resolution order: a user-chosen custom folder (security-scoped bookmark),
    /// else the iCloud ubiquity container's Documents folder, else a local
    /// Documents/Quire folder. The chosen folder is the journal base directly —
    /// same layout as jnl's `JNL_DIR`, so pointing it at an existing jnl notes
    /// folder just works. A remembered custom folder that won't resolve stops
    /// here as `unavailable` rather than falling through — the fallback would
    /// be a second, empty journal that the folder's return then hides again.
    private nonisolated static func resolveBase(bookmark: Data?, containerID: String?) -> Resolved {
        let fm = FileManager.default
        if let data = bookmark {
            guard let found = FolderAccess.resolve(data) else {
                return Resolved(url: nil, mode: .custom, scoped: false,
                                unavailable: FolderAccess.name(inBookmark: data) ?? "your journal folder")
            }
            // A stale bookmark still resolves, but only for now — mint a fresh
            // one from the folder we just found so a move or rename doesn't
            // turn into an unavailable folder on some later launch.
            if found.stale, let fresh = FolderAccess.remint(found.url) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
            return Resolved(url: found.url, mode: .custom, scoped: true)
        }
        if let container = fm.url(forUbiquityContainerIdentifier: containerID) {
            let docs = container.appendingPathComponent("Documents", isDirectory: true)
            try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
            return Resolved(url: docs, mode: .iCloud, scoped: false)
        }
        let local = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quire", isDirectory: true)
        try? fm.createDirectory(at: local, withIntermediateDirectories: true)
        return Resolved(url: local, mode: .local, scoped: false)
    }

    /// Human-readable location for display (e.g. "…/Notes" or an iCloud path).
    var storagePath: String {
        if let baseURL { return baseURL.path }
        if let name = unavailableFolder { return "“\(name)” — not available" }
        return "Resolving…"
    }

    /// Dates ("YYYY-MM-DD") that still have unfiled drafts sitting in the inbox.
    /// The calendars shade these differently from filed journal days.
    var inboxDays: Set<String> { Set(inboxDrafts.map(\.date)) }

    // MARK: Choosing the journal folder

    /// Point Quire at a user-selected folder (from a file importer). It becomes
    /// the journal base and is remembered across launches via a bookmark.
    func setCustomFolder(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = FolderAccess.makeBookmark(url) else {
            // Say so rather than appearing to accept the folder and then
            // quietly carrying on writing somewhere else.
            lastWriteError = "Couldn't get lasting access to “\(url.lastPathComponent)” — the journal folder is unchanged."
            return
        }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        resolveBaseAndReload()
    }

    /// Forget the custom folder and fall back to iCloud / local.
    func useDefaultFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        resolveBaseAndReload()
    }

    // MARK: Backup

    private let backupBookmarkKey = "backupFolderBookmark"
    static let backupIntervalKey = "backupInterval"
    static let backupKeepKey = "backupKeepCount"
    private let lastBackupKey = "lastBackupAt"
    /// Backups closer together than this are skipped on the "every change"
    /// setting, so a burst of edits can't spin the disk copying all day.
    private static let changeBackupFloor: TimeInterval = 300

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private func resolveBackupURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: backupBookmarkKey),
              let found = FolderAccess.resolve(data) else { return nil }
        if found.stale, let fresh = FolderAccess.remint(found.url) {
            UserDefaults.standard.set(fresh, forKey: backupBookmarkKey)
        }
        return found.url
    }

    /// Display name of the chosen backup folder, or nil if none.
    var backupFolderName: String? { resolveBackupURL()?.lastPathComponent }
    /// Full path of the chosen backup folder, or nil if none.
    var backupFolderPath: String? { resolveBackupURL()?.path }

    func setBackupFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if let data = FolderAccess.makeBookmark(url) {
            UserDefaults.standard.set(data, forKey: backupBookmarkKey)
        }
    }

    // MARK: Automatic backup

    /// When the last successful backup (manual or automatic) finished.
    @Published private(set) var lastBackupAt: Date?
    /// True while a copy is in flight, so the UI can show progress and we never
    /// start a second one on top of the first.
    @Published private(set) var backupRunning = false

    private var backupDebounce: Task<Void, Never>?

    private var backupInterval: BackupInterval {
        BackupInterval(rawValue: UserDefaults.standard.string(forKey: Self.backupIntervalKey) ?? "") ?? .off
    }
    /// How many timestamped copies to keep before pruning the oldest.
    private var backupKeepCount: Int {
        let n = UserDefaults.standard.integer(forKey: Self.backupKeepKey)
        return n > 0 ? n : 10
    }

    private func loadLastBackupDate() {
        let t = UserDefaults.standard.double(forKey: lastBackupKey)
        lastBackupAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Run a scheduled (Daily / Weekly) backup if one is overdue. Safe to call
    /// as often as you like — app launch, foreground, after a write.
    func autoBackupIfDue() {
        guard let gap = backupInterval.scheduledGap else { return }
        if let last = lastBackupAt, Date().timeIntervalSince(last) < gap { return }
        Task { await runBackup() }
    }

    /// A journal file just changed on disk. Drives the "On every change"
    /// setting (debounced, so a burst of edits produces one copy) and lets a
    /// long-running session still take its daily/weekly backup.
    private func journalDidChange() {
        guard backupInterval == .onChange else {
            autoBackupIfDue()
            return
        }
        backupDebounce?.cancel()
        backupDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // Inside the floor, wait it out rather than giving up: returning
            // here dropped the last edit of a burst for good, because nothing
            // else was coming to reschedule it.
            if let last = self.lastBackupAt {
                let wait = Self.changeBackupFloor - Date().timeIntervalSince(last)
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                }
            }
            await self.runBackup()
        }
    }

    /// Copy the whole journal folder into a timestamped subfolder of the backup
    /// location, then prune to the newest `backupKeepCount` copies. The copy runs
    /// off the main actor so a big assets folder never blocks writing.
    @discardableResult
    func runBackup() async -> (ok: Bool, message: String) {
        guard !backupRunning else { return (false, "A backup is already running.") }
        guard let base = baseURL else { return (false, "No journal folder to back up.") }
        guard let backupBase = resolveBackupURL() else {
            return (false, "Choose a backup folder first.")
        }
        if let clash = Self.nestingProblem(base: base, backupBase: backupBase) { return (false, clash) }
        backupRunning = true
        defer { backupRunning = false }
        let name = "Quire-Backup-\(Self.stampFormatter.string(from: Date()))"
        let keep = backupKeepCount
        let result = await Task.detached(priority: .utility) {
            Self.copyTree(from: base, into: backupBase, named: name, keep: keep)
        }.value
        if result.ok {
            let now = Date()
            lastBackupAt = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastBackupKey)
        }
        return result
    }

    /// A backup folder inside the journal (or the reverse) turns backup into
    /// recursion and restore into deleting its own source — refuse both.
    nonisolated static func nestingProblem(base: URL, backupBase: URL) -> String? {
        let b = base.standardizedFileURL.path + "/"
        let k = backupBase.standardizedFileURL.path + "/"
        if k.hasPrefix(b) { return "The backup folder is inside the journal folder — choose one outside it." }
        if b.hasPrefix(k) { return "The journal folder is inside the backup folder — choose a separate backup location." }
        return nil
    }

    /// The copy + prune itself, off-main. Security-scoped access is held around
    /// both so a sandboxed user-picked backup folder stays writable.
    private nonisolated static func copyTree(
        from base: URL, into backupBase: URL, named name: String, keep: Int
    ) -> (ok: Bool, message: String) {
        let fm = FileManager.default
        let scoped = backupBase.startAccessingSecurityScopedResource()
        defer { if scoped { backupBase.stopAccessingSecurityScopedResource() } }
        do {
            try fm.copyItem(at: base, to: backupBase.appendingPathComponent(name))
        } catch {
            return (false, "Backup failed: \(error.localizedDescription)")
        }
        prune(in: backupBase, keep: keep)
        return (true, "Backed up to \(name).")
    }

    // MARK: Restore

    struct BackupCopy: Identifiable, Sendable {
        let name: String       // "Quire-Backup-YYYY-MM-dd-HH-mm-ss"
        let date: Date?
        var id: String { name }
    }

    /// The timestamped copies in the backup folder, newest first.
    func listBackups() async -> [BackupCopy] {
        guard let backupBase = resolveBackupURL() else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let scoped = backupBase.startAccessingSecurityScopedResource()
            defer { if scoped { backupBase.stopAccessingSecurityScopedResource() } }
            let names = ((try? FileManager.default.contentsOfDirectory(
                at: backupBase, includingPropertiesForKeys: nil)) ?? [])
                .map(\.lastPathComponent)
                .filter { $0.hasPrefix("Quire-Backup-") }
                .sorted(by: >)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return names.map {
                BackupCopy(name: $0, date: f.date(from: String($0.dropFirst("Quire-Backup-".count))))
            }
        }.value
    }

    /// Replace the journal with a backup copy. A safety copy of the current
    /// folder is taken first (never pruned by this call), so a restore is
    /// itself restorable. Runs off-main; reloads on success.
    func restoreBackup(named name: String) async -> (ok: Bool, message: String) {
        guard !backupRunning else { return (false, "A backup is already running.") }
        guard let base = baseURL else { return (false, "No journal folder to restore into.") }
        guard let backupBase = resolveBackupURL() else { return (false, "Choose a backup folder first.") }
        if let clash = Self.nestingProblem(base: base, backupBase: backupBase) { return (false, clash) }
        backupRunning = true
        defer { backupRunning = false }
        let safetyName = "Quire-Backup-\(Self.stampFormatter.string(from: Date()))"
        let result = await Task.detached(priority: .userInitiated) {
            // Safety copy first, with keep: 0 so pruning can't delete the very
            // backup that's about to be restored.
            let safety = Self.copyTree(from: base, into: backupBase, named: safetyName, keep: 0)
            guard safety.ok else {
                return (false, "Couldn't take a safety copy first — nothing was changed. \(safety.message)")
            }
            return Self.replaceTree(base: base, from: backupBase.appendingPathComponent(name))
        }.value
        if result.0 {
            let now = Date()
            lastBackupAt = now   // the safety copy counts
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastBackupKey)
            reload()
        }
        return (ok: result.0, message: result.1)
    }

    /// Empty the base folder and copy the backup's contents in. The backup is
    /// verified to look like a journal (inbox.md or journal/) before anything
    /// is deleted.
    private nonisolated static func replaceTree(base: URL, from backup: URL) -> (Bool, String) {
        let fm = FileManager.default
        let scoped = backup.deletingLastPathComponent().startAccessingSecurityScopedResource()
        defer { if scoped { backup.deletingLastPathComponent().stopAccessingSecurityScopedResource() } }
        guard fm.fileExists(atPath: backup.appendingPathComponent("inbox").path)
                || fm.fileExists(atPath: backup.appendingPathComponent("split").path)
                || fm.fileExists(atPath: backup.appendingPathComponent("inbox.md").path)
                || fm.fileExists(atPath: backup.appendingPathComponent("journal").path) else {
            return (false, "That folder doesn't look like a Quire backup — nothing was changed.")
        }
        do {
            for item in try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
                try fm.removeItem(at: item)
            }
            for item in try fm.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil) {
                try fm.copyItem(at: item, to: base.appendingPathComponent(item.lastPathComponent))
            }
        } catch {
            return (false, "Restore failed partway: \(error.localizedDescription). A safety copy of the pre-restore journal is in the backup folder.")
        }
        return (true, "Restored \(backup.lastPathComponent). The pre-restore journal was saved as a new backup.")
    }

    /// Keep only the newest `keep` backups. The timestamped names sort
    /// lexicographically == chronologically, the same trick jnl uses for entries.
    private nonisolated static func prune(in backupBase: URL, keep: Int) {
        guard keep > 0 else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: backupBase, includingPropertiesForKeys: nil)
        else { return }
        let names = items
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("Quire-Backup-") }
            .sorted(by: >)
        for stale in names.dropFirst(keep) {
            try? fm.removeItem(at: backupBase.appendingPathComponent(stale))
        }
    }

    // MARK: Paths
    private var inboxURL: URL? { baseURL?.appendingPathComponent("inbox", isDirectory: true) }
    private var journalDirURL: URL? { baseURL?.appendingPathComponent("journal", isDirectory: true) }

    /// journal/YYYY/MM/DD.md for a "YYYY-MM-DD" date.
    private func journalFileURL(for date: String) -> URL? {
        let parts = date.split(separator: "-")
        guard parts.count == 3, let dir = journalDirURL else { return nil }
        return dir.appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))
            .appendingPathComponent("\(parts[2]).md")
    }

    // MARK: Loading

    func reload() {
        reloadStartedAt = Date()
        drainPendingShares()
        loadInbox()
        rebuildIndex()   // bumps `revision`
        dataSaved = totalDataSaved()
    }

    /// What the journal looked like at the last reload — a stat-only walk
    /// (count + mtimes + sizes), no file reads.
    private var lastFingerprint = ""
    private var reloadStartedAt = Date.distantPast

    /// Foreground/activation path: skip the full reload when nothing on disk
    /// changed. Every app-switch used to trigger a complete corpus re-read.
    func reloadIfChanged() {
        guard let base = baseURL else { return }
        // The first index is still being built (it records the fingerprint when
        // it lands), so there is nothing yet to compare against: a second full
        // read here would double the time to open the journal.
        if !indexed, Date().timeIntervalSince(reloadStartedAt) < 120 { return }
        let previous = lastFingerprint
        Task.detached(priority: .userInitiated) { [weak self] in
            let fp = Self.contentFingerprint(base: base)
            guard fp != previous else { return }
            await MainActor.run { [weak self] in
                guard let self, self.baseURL == base else { return }
                self.lastFingerprint = fp
                self.reload()
            }
        }
    }

    /// Cheap change detector over inbox.md + every journal/split md file.
    nonisolated static func contentFingerprint(base: URL) -> String {
        let fm = FileManager.default
        var parts: [String] = []
        for directory in ["inbox", "journal", "split", ".quire", ".nook"] {
            guard let en = fm.enumerator(at: base.appendingPathComponent(directory), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "md" || url.pathExtension == "json" {
                if let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                    parts.append("\(url.path):\(v.fileSize ?? 0):\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)")
                }
            }
        }
        for url in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "md" {
            if let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                parts.append("\(url.path):\(v.fileSize ?? 0):\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        return parts.sorted().joined(separator: "|")
    }

    private func loadInbox() {
        guard let core else { inboxDrafts = []; return }
        do {
            try core.migrate()
            inboxDrafts = JournalParser.withOccurrences(try core.inbox().map(\.entry))
        } catch { lastWriteError = journalErrorMessage(error) }

    }

    struct BuiltIndex {
        var days: [ArchiveDay] = []
        var tags: [(tag: String, count: Int)] = []
        var splits: [SplitJournal] = []
        /// The stats pass, computed from the same file reads as the index.
        var heavy = HeavyStats()
        /// The parsed corpus, captured while the index pass is reading every
        /// file anyway — published so Journal/Starred/Stream/Search/Random
        /// never walk the disk on the main actor again.
        var corpus: [(date: String, entries: [Entry])] = []
        var splitEntries: [String: [Entry]] = [:]
    }

    /// Coalesce a burst of mutations into one rebuild. The caches were already
    /// patched synchronously by the mutation, so nothing waits on this — it
    /// reconciles tags, stats, the widget, and Spotlight in the background.
    private var rebuildDebounce: Task<Void, Never>?
    private var indexGeneration = 0
    private func scheduleRebuild() {
        rebuildDebounce?.cancel()
        rebuildDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.rebuildIndex()
        }
    }

    /// Rebuild the archive/tags/split-journal index off the main thread and
    /// publish the results, so no view body ever does directory-wide file reads.
    private func rebuildIndex() {
        indexGeneration &+= 1
        let generation = indexGeneration
        guard let base = baseURL else {
            archiveDays = []; tagCounts = []; splitJournals = []
            archiveEntries = []; splitEntriesCache = [:]
            revision &+= 1
            return
        }
        let inboxTags = inboxDrafts.flatMap { $0.tags }
        // Drafts dated today count toward today's words (the goal is about
        // writing, not about filing) — computed here so the detached pass
        // needn't re-read the inbox.
        let todayISO = Self.nowDate()
        let draftsToday = inboxDrafts.filter { $0.date == todayISO }
        let inboxWordsToday = draftsToday.reduce(0) { $0 + $1.wordCount }
        // …and count as having written today, so the daily reminder doesn't
        // nag someone whose entry is sitting unfiled in the inbox.
        let hasDraftToday = !draftsToday.isEmpty
        let triggerDownloads = storageMode == .iCloud
        Task.detached(priority: .userInitiated) {
            // ONE pass: the index, the parsed corpus, and the stats all come
            // out of the same read of each file — this used to be two full
            // corpus reads per rebuild.
            let initial: BuiltIndex
            do { initial = try Self.buildIndex(base: base, triggerDownloads: triggerDownloads) }
            catch {
                await MainActor.run { [weak self] in
                    guard let self, self.baseURL == base, self.indexGeneration == generation else { return }
                    self.lastWriteError = journalErrorMessage(error)
                }
                return
            }
            var built = initial
            built.heavy.wordsToday += inboxWordsToday
            built.heavy.hasEntryToday = built.heavy.hasEntryToday || hasDraftToday
            let idx = built
            let heavy = idx.heavy
            let fp = Self.contentFingerprint(base: base)
            await MainActor.run { [weak self] in
                guard let self, self.baseURL == base, self.indexGeneration == generation else { return }
                self.lastFingerprint = fp
                self.archiveDays = idx.days
                var map = Dictionary(uniqueKeysWithValues: idx.tags.map { ($0.tag, $0.count) })
                for t in inboxTags { map[t, default: 0] += 1 }
                self.tagCounts = map.map { (tag: $0.key, count: $0.value) }
                    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
                self.splitJournals = idx.splits
                self.archiveEntries = idx.corpus
                self.indexed = true
                self.splitEntriesCache = idx.splitEntries
                self.lastHeavyStats = heavy
                // Announced here, at publication — every mutation funnels into
                // this rebuild, and views reloading on `.task(id: revision)`
                // must find the fresh corpus already in place when they fire.
                self.revision &+= 1
                self.writeWidgetSnapshot()
                ReminderScheduler.refresh(hasEntryToday: heavy.hasEntryToday,
                                          streak: heavy.currentStreak)
                #if canImport(CoreSpotlight)
                SpotlightIndexer.scheduleReindex(source: { self.spotlightSource() })
                #endif
            }
        }
    }

    /// The last full-corpus stats pass, computed off-main alongside the index.
    private var lastHeavyStats = HeavyStats()
    /// What the widget was last told, so unchanged rebuilds don't burn
    /// WidgetKit's reload budget.
    private var lastSnapshotSent: QuireSnapshot?

    /// Write a QuireSnapshot to the shared App Group so the widget can
    /// display up-to-date stats without accessing the journal directly.
    /// Skipped entirely when nothing the widget shows has moved.
    private func writeWidgetSnapshot() {
        #if os(iOS) || os(macOS)
        let heavy = lastHeavyStats
        let defaults = UserDefaults.standard
        var snap = QuireSnapshot()
        snap.currentStreak = heavy.currentStreak
        snap.bestStreak    = heavy.bestStreak
        snap.totalDays     = heavy.days
        snap.totalEntries  = heavy.entries
        snap.totalWords    = heavy.words
        snap.inboxDrafts   = inboxDrafts.count
        snap.accentRaw     = defaults.string(forKey: "accentColor") ?? "blue"
        // QuireTheme.storageKey; the Design files aren't compiled into the tests.
        snap.themeID       = defaults.string(forKey: "quireTheme") ?? "auto"
        snap.day           = QuireSnapshot.dayKey(Date())
        snap.wordsToday    = heavy.wordsToday
        snap.filedToday    = heavy.filedToday
        snap.wroteToday    = heavy.hasEntryToday
        let goalEnabled = defaults.bool(forKey: "wordGoalEnabled")
        // `object(forKey:)`: an untouched goal is the app's 750, not 0.
        let goal = defaults.object(forKey: "wordGoal") as? Int ?? 750
        snap.wordGoal = goalEnabled ? max(goal, 1) : 0
        if heavy.onThisDayCount > 0 {
            snap.onThisDayPreview  = heavy.onThisDayPreview
            snap.onThisDayExcerpt  = heavy.onThisDayExcerpt.isEmpty ? nil : heavy.onThisDayExcerpt
            snap.onThisDayYearsAgo = heavy.onThisDayYearsAgo
            snap.onThisDayDate     = heavy.onThisDayDate
            snap.onThisDayTS       = heavy.onThisDayTS
        }
        if let last = lastSnapshotSent {
            var unchanged = last
            unchanged.updatedAt = snap.updatedAt
            if unchanged == snap { return }
        }
        snap.updatedAt = Date()
        lastSnapshotSent = snap
        snap.save()
        // Tell WidgetKit to reload its timelines.
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// The first body line worth showing under an entry's preview: not the
    /// preview itself, not a media link.
    nonisolated static func excerpt(of entry: Entry) -> String {
        let preview = entry.preview.trimmingCharacters(in: .whitespaces)
        let line = entry.body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("![") && $0 != preview } ?? ""
        return line.count <= 140 ? line : String(line.prefix(140)).trimmingCharacters(in: .whitespaces) + "…"
    }

    #if canImport(CoreSpotlight)
    /// The whole journal as index-ready values, straight from the caches —
    /// occurrence-suffixed ids so same-second twins don't collide.
    func spotlightSource() -> [SpotlightIndexer.IndexableEntry] {
        var out: [SpotlightIndexer.IndexableEntry] = []
        var seen: [String: Int] = [:]
        func add(_ e: Entry, base: String) {
            let n = seen[base, default: 0]
            seen[base] = n + 1
            out.append(SpotlightIndexer.IndexableEntry(
                id: n == 0 ? base : "\(base)#\(n)",
                title: e.preview.isEmpty ? "Journal entry" : e.preview,
                body: String(e.body.prefix(400)),
                keywords: e.tags.map { String($0.dropFirst()) },
                ts: e.ts))
        }
        for e in inboxDrafts { add(e, base: "inbox|\(e.ts)") }
        for day in archiveEntries {
            for e in day.entries { add(e, base: "archive|\(day.date)|\(e.ts)") }
        }
        return out
    }
    #endif

    nonisolated private static let reservedFiles: Set<String> = ["inbox.md", "transfer.md", "export.md", "quire-export.md"]

    nonisolated static func buildIndex(base: URL, triggerDownloads: Bool = true) throws -> BuiltIndex {
        var idx = BuiltIndex()

        let ymd = DateFormatter()
        ymd.dateFormat = "yyyy-MM-dd"
        ymd.locale = Locale(identifier: "en_US_POSIX")
        let todayISO = ymd.string(from: Date())
        let monthDay = String(todayISO.suffix(5))
        let currentYear = Int(todayISO.prefix(4)) ?? 0
        var latestOnThisDayYear = 0
        var statDates: [Date] = []

        let all = try CoreJournal(base: base).load()
        let grouped = Dictionary(grouping: all.filter { $0.source == "journal" }, by: \.date)
        let urls = grouped.keys.sorted(by: >).map { base.appendingPathComponent("journal/" + $0.replacingOccurrences(of: "-", with: "/") + ".md") }
        var tagMap: [String: Int] = [:]
        for u in urls {
            let entries = JournalParser.withOccurrences((grouped[staticFileToDate(u)] ?? []).map(\.entry))
            let content = entries.map(\.raw).joined(separator: "\n\n")
            var day = ArchiveDay(date: staticFileToDate(u),
                                 count: entries.count,
                                 preview: entries.first?.preview ?? "")
            day.hasStarred = entries.contains { $0.isStarred }
            for path in mediaPaths(in: content) {
                switch MediaKind(path: path) {
                case .image: day.hasPhoto = true
                case .video: day.hasVideo = true
                case .audio: day.hasAudio = true
                }
            }
            idx.days.append(day)
            if !entries.isEmpty { idx.corpus.append((date: day.date, entries: entries)) }
            for t in JournalParser.splitTags(content) { tagMap[t, default: 0] += 1 }

            // Stats, from the same read.
            let w = content.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
            idx.heavy.days += 1; idx.heavy.entries += entries.count; idx.heavy.words += w
            if w > idx.heavy.longestDayWords { idx.heavy.longestDayWords = w; idx.heavy.longestDay = day.date }
            if day.date == todayISO {
                idx.heavy.hasEntryToday = true
                idx.heavy.filedToday += entries.count
                idx.heavy.wordsToday += entries.reduce(0) { $0 + $1.wordCount }
            } else if day.date.hasSuffix(monthDay), let y = Int(day.date.prefix(4)), y < currentYear {
                // Same calendar day, an earlier year — the "On this day" pool.
                idx.heavy.onThisDayCount += entries.count
                if y > latestOnThisDayYear, let first = entries.first {
                    latestOnThisDayYear = y
                    idx.heavy.onThisDayPreview = first.preview
                    idx.heavy.onThisDayExcerpt = Self.excerpt(of: first)
                    idx.heavy.onThisDayYearsAgo = currentYear - y
                    idx.heavy.onThisDayDate = day.date
                    idx.heavy.onThisDayTS = first.ts
                }
            }
            if let d = ymd.date(from: day.date) { statDates.append(d) }
        }
        finishHeavyStats(&idx.heavy, base: base, dates: statDates)

        for (name, values) in Dictionary(grouping: all.filter { $0.source == "split" }, by: { $0.split ?? "" }) {
            let entries = JournalParser.withOccurrences(values.map(\.entry))
            idx.splits.append(SplitJournal(name: name, count: entries.count))
            idx.splitEntries[name] = entries
        }
        idx.splits.sort { $0.name < $1.name }
        idx.tags = tagMap.map { (tag: $0.key, count: $0.value) }
        return idx
    }

    /// Kick off a download for an iCloud file that isn't local yet. Reads still
    /// return whatever is on disk until it lands; the next reload picks it up.
    nonisolated static func ensureDownloaded(_ url: URL) {
        let fm = FileManager.default
        guard fm.isUbiquitousItem(at: url) else { return }
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus
        if status != .current { try? fm.startDownloadingUbiquitousItem(at: url) }
    }

    /// Extract the paths from markdown media links in some content.
    nonisolated static func mediaPaths(in content: String) -> [String] {
        MediaLinks.paths(in: content)
    }

    nonisolated static func staticFileToDate(_ url: URL) -> String {
        let day = url.deletingPathExtension().lastPathComponent
        let month = url.deletingLastPathComponent().lastPathComponent
        let year = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return "\(year)-\(month)-\(day)"
    }


    /// journal/2026/05/10.md → "2026-05-10".


    /// All filed entries grouped by day, newest day first (each day
    /// chronological). An alias for the published cache — no disk walk.
    func allEntriesByDay() -> [(date: String, entries: [Entry])] {
        archiveEntries
    }

    /// Entries filed on a given day, chronological.
    func entries(for date: String) -> [Entry] {
        guard let core else { return [] }
        do { return JournalParser.withOccurrences(try core.load().filter { $0.source == "journal" && $0.date == date }.map(\.entry)) }
        catch { lastWriteError = journalErrorMessage(error); return [] }
    }

    // MARK: Tags (jnl cmdTags / cmdTag)

    /// Filed entries containing a tag, newest day first. Mirrors jnl `tag <name>`.
    /// Served from the cached corpus.
    func entries(taggedWith name: String) -> [(date: String, entry: Entry)] {
        let tag = name.hasPrefix("@") ? name : "@" + name
        var result: [(String, Entry)] = []
        for day in archiveEntries {
            for e in day.entries where e.raw.contains(tag) {
                result.append((day.date, e))
            }
        }
        return result
    }

    // MARK: Tag review (find near-duplicate tags, merge/rename)

    struct TagGroup: Identifiable, Sendable {
        let variants: [Variant]
        let caseOnly: Bool     // true = identical apart from case; false = 1-char apart
        /// Stable key so an "ignore" choice sticks regardless of ordering.
        var id: String { variants.map(\.tag).sorted().joined(separator: "|") }

        struct Variant: Sendable { let tag: String; let count: Int }
    }

    private let ignoredTagGroupsKey = "ignoredTagGroups"

    func ignoreTagGroup(_ group: TagGroup) {
        var ignored = UserDefaults.standard.stringArray(forKey: ignoredTagGroupsKey) ?? []
        if !ignored.contains(group.id) { ignored.append(group.id) }
        UserDefaults.standard.set(ignored, forKey: ignoredTagGroupsKey)
    }

    /// Compute the tag groups off the main thread (levenshtein clustering can be
    /// O(n²) over the tag set). Snapshot the inputs on the main actor first.
    func similarTagGroupsAsync() async -> [TagGroup] {
        let counts = tagCounts.map { TagGroup.Variant(tag: $0.tag, count: $0.count) }
        let ignored = Set(UserDefaults.standard.stringArray(forKey: ignoredTagGroupsKey) ?? [])
        return await Task.detached { Self.computeTagGroups(counts, ignored: ignored) }.value
    }

    /// Two tiers of possibly-duplicate tags: case-only variants (@tags/@Tags),
    /// then one-character-apart lookalikes (journaling/journalling — but also
    /// false friends like food/mood, which the user can ignore). Case-only first.
    nonisolated static func computeTagGroups(_ counts: [TagGroup.Variant], ignored: Set<String>) -> [TagGroup] {
        var order: [String] = [], buckets: [String: [TagGroup.Variant]] = [:]
        for item in counts {
            let key = item.tag.dropFirst().lowercased()
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }

        var groups: [TagGroup] = []
        // Tier 1: keys that cover more than one actual tag → only case differs.
        for key in order where (buckets[key]?.count ?? 0) > 1 {
            let variants = (buckets[key] ?? []).sorted { $0.count > $1.count }
            let g = TagGroup(variants: variants, caseOnly: true)
            if !ignored.contains(g.id) { groups.append(g) }
        }
        // Tier 2: distinct keys within one edit of each other.
        var used = Set<String>()
        for i in order.indices where !used.contains(order[i]) {
            var cluster = [order[i]]
            for j in order.indices where j > i && !used.contains(order[j]) {
                if min(order[i].count, order[j].count) >= 4,
                   levenshtein(order[i], order[j]) == 1 {
                    cluster.append(order[j])
                }
            }
            guard cluster.count > 1 else { continue }
            cluster.forEach { used.insert($0) }
            let variants = cluster.flatMap { buckets[$0] ?? [] }.sorted { $0.count > $1.count }
            let g = TagGroup(variants: variants, caseOnly: false)
            if !ignored.contains(g.id) { groups.append(g) }
        }
        return groups
    }

    nonisolated private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        var d = Array(0...b.count)
        for i in 1...a.count {
            var prev = d[0]; d[0] = i
            for j in 1...b.count {
                let temp = d[j]
                d[j] = a[i-1] == b[j-1] ? prev : min(prev, d[j], d[j-1]) + 1
                prev = temp
            }
        }
        return d[b.count]
    }

    /// Apply several tag renames in one pass over each file, reloading once.
    func mergeTags(_ merges: [(from: String, to: String)]) {
        for merge in merges { _ = renameTag(from: merge.from, to: merge.to) }
    }

    /// Rename all occurrences of one @tag to another across inbox, journal, and
    /// split-journal files. Whole-token match, so @tag doesn't touch @tags.
    @discardableResult
    func renameTag(from old: String, to new: String) -> Int {
        let changed: Int = coreMutation { try $0.call("rename_tag", ["from": [old], "to": new]) } ?? 0
        reload()
        return changed
    }


    /// Served from the cached corpus (the editing paths below re-read disk
    /// themselves, so this staying cache-backed is safe).
    func entries(inJournal name: String) -> [Entry] {
        splitEntriesCache[name] ?? []
    }

    /// Returns false when the entry couldn't be found or the write failed — the
    /// editor must not advance its baseline on a write that didn't happen.
    @discardableResult
    func updateJournalEntry(name: String, original: Entry, newText: String, reindex: Bool = true) -> Bool {
        guard let result = coreMutation({ try $0.update(original, text: newText) }) else { return false }
        lastWritten = result
        publishCoreChange(reindex: reindex)
        return true
    }

    @discardableResult
    func deleteJournalEntry(name: String, entry: Entry) -> Bool {
        let ok = coreMutation { try $0.delete(entry); return true } ?? false
        publishCoreChange()
        return ok
    }

    // MARK: Starred entries (trailing `*` on the title)

    /// Add or remove the trailing `*` star marker on an entry, rewriting it in
    /// whichever file it lives (inbox / archive day / split journal).
    func toggleStar(_ entry: Entry, source: EntrySource) {
        let newTitle = Entry.togglingStarMarker(entry.suffix)
        let newText = Self.makeEntry(timestamp: entry.ts, title: newTitle, body: entry.body).raw
        switch source {
        case .inbox:            updateDraft(entry, newText: newText)
        case .archive(let d):   updateFiledEntry(date: d, original: entry, newText: newText)
        case .journal(let n):   updateJournalEntry(name: n, original: entry, newText: newText)
        }
    }

    /// Every starred entry across the archive, inbox and split journals, paired
    /// with the source it came from so it can be opened/edited in place.
    func starredEntries() -> [(entry: Entry, source: EntrySource)] {
        var out: [(entry: Entry, source: EntrySource)] = []
        for day in archiveEntries {
            for e in day.entries where e.isStarred {
                out.append((e, .archive(date: day.date)))
            }
        }
        for d in inboxDrafts where d.isStarred { out.append((d, .inbox)) }
        for (name, entries) in splitEntriesCache.sorted(by: { $0.key < $1.key }) {
            for e in entries where e.isStarred {
                out.append((e, .journal(name: name)))
            }
        }
        return out
    }

    // MARK: Composer autosave (jnl cmdNew)

    /// Build an Entry from title + timestamp + body in the jnl header format:
    /// title lands on the header line (`[ts] title`), body on the lines below.
    /// One entry in, one entry out: a body carrying its own `[timestamp]` lines
    /// (pasted from a day file, say) would parse back as several entries, so
    /// those lines are escaped — an editor holding one entry can never write
    /// more than one.
    static func makeEntry(timestamp: String, title: String, body: String) -> Entry {
        JournalParser.parseEntries(makeText(ts: timestamp, title: title, body: body))[0]
    }

    /// Create or update the composer's working draft. `previous` is the last
    /// timestamp this draft was saved under (so changing the date picker moves the
    /// same draft rather than orphaning it). Empty title+body removes the draft.
    /// Returns the timestamp actually used: a brand-new draft landing on a
    /// second that is already taken is nudged forward until free, so the
    /// composer can never overwrite an unrelated same-second draft (an import,
    /// a Siri quick-add, a second device).
    @discardableResult
    func upsertDraft(previous: String?, timestamp: String, title: String, body: String, reindex: Bool = true) -> String? {
        guard let core else { return previous }
        if previous == nil { composerEntry = nil }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let composerEntry { _ = coreMutation { try $0.delete(composerEntry); return true } }
            self.composerEntry = nil
            publishCoreChange(reindex: reindex)
            return nil
        }
        // The composer's own reference survives unpublished autosaves. Never
        // identify an existing draft solely by a timestamp shared by twins.
        if composerEntry == nil, let previous {
            do {
                let matches = try core.inbox().filter { $0.ts == previous }
                guard matches.count == 1 else { throw JournalError.journalUnavailable }
                composerEntry = matches[0].entry
            } catch { lastWriteError = journalErrorMessage(error); return previous }
        }
        let result: CoreWritten? = coreMutation { core in
            if let composerEntry { return try core.update(composerEntry, text: Self.makeEntry(timestamp: timestamp, title: title, body: body).raw) }
            var ts = timestamp
            let used = Set(try core.inbox().map(\.ts))
            while used.contains(ts) { ts = Self.timestamp(after: ts) }
            return try core.call("new", ["ts": ts, "title": title, "body": body])
        }
        guard let result else { return previous }
        lastWritten = result
        composerEntry = writtenEntry(fallback: Self.makeEntry(timestamp: timestamp, title: title, body: body))
        publishCoreChange(reindex: reindex)
        return composerEntry?.ts
    }

    /// The jnl timestamp one second after `ts` (the input itself on parse failure —
    /// callers bound their retry loops, so this can never spin).
    private static func timestamp(after ts: String) -> String {
        guard let d = tsFormatter.date(from: ts) else { return ts }
        return tsFormatter.string(from: d.addingTimeInterval(1))
    }

    func removeDraft(timestamp: String) {
        guard let entry = composerEntry.flatMap({ $0.ts == timestamp ? $0 : nil }) ?? inboxDrafts.first(where: { $0.ts == timestamp }) else { return }
        deleteDraft(entry)
        if composerEntry?.ts == timestamp { composerEntry = nil }
    }

    /// Remove every inbox draft whose text matches one of `entries` (one draft
    /// per match). The composer's Import uses it to clear everything the working
    /// text already put in the inbox before splitting it up — an inbox left
    /// polluted by an earlier build's autosave would otherwise be imported on
    /// top of. Returns how many were removed.
    @discardableResult
    func removeDrafts(matching entries: [Entry]) -> Int {
        var removed = 0
        for wanted in entries {
            guard let current = inboxDrafts.first(where: { $0.raw.trimmingCharacters(in: .newlines) == wanted.raw.trimmingCharacters(in: .newlines) }) else { continue }
            if coreMutation({ core in try core.delete(current); return true }) == true { removed += 1; loadInbox() }
        }
        if removed > 0 { rebuildIndex() }
        return removed
    }

    /// Import pasted text as separate inbox drafts (jnl `transfer` parsing): if it
    /// contains `[timestamp]` headers each becomes its own draft; otherwise each
    /// blank-line-separated paragraph becomes a draft stamped with the current time.
    /// Returns how many drafts were added.
    @discardableResult
    func importDrafts(from text: String) -> Int {
        let count: Int = coreMutation { try $0.call("import", ["text": text, "ts": Self.nowTS()]) } ?? 0
        publishCoreChange()
        return count
    }

    // MARK: Media assets (Obsidian-style: <base>/assets/<file>, markdown links)

    private var assetsDirURL: URL? { baseURL?.appendingPathComponent("assets", isDirectory: true) }
    private var newAssetsDirURL: URL? {
        assetsDirURL?.appendingPathComponent(String(Self.nowDate().prefix(7)).replacingOccurrences(of: "-", with: "/"), isDirectory: true)
    }
    private func assetRelativePath(_ url: URL) -> String {
        guard let baseURL else { return "" }
        return Self.relativePath(of: url, under: baseURL)
    }

    /// `url`'s path below `base`, by path components after resolving symlinks.
    /// Trimming by character count went wrong when one side came back as
    /// `/private/var/…` and the other as `/var/…` (iOS does both).
    nonisolated static func relativePath(of url: URL, under base: URL) -> String {
        let b = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let u = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard u.count > b.count, Array(u.prefix(b.count)) == b else {
            return String(url.path.dropFirst(base.path.count + 1))
        }
        return u.dropFirst(b.count).joined(separator: "/")
    }


    /// Absolute URL for a relative asset path like "assets/foo.png".
    func assetURL(forRelative path: String) -> URL? {
        baseURL?.appendingPathComponent(path)
    }

    struct AssetItem: Identifiable, Hashable {
        let url: URL
        /// Last-modified date and size on disk, so the browser can sort by them.
        var modified: Date = .distantPast
        /// Timestamp of the earliest entry linking this file, when one does.
        /// Nil for orphans, and for the plain `allAssets()` listing which
        /// doesn't read the journal.
        var entryDate: Date? = nil
        var size: Int = 0
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        /// The date the gallery sorts and groups by: when the file was written
        /// about, not when it landed on disk. A photo imported today into a
        /// back-dated entry belongs to that entry's day.
        var date: Date { entryDate ?? modified }
    }

    /// All files in the assets folder, with file dates only — the callers that
    /// use this (orphan sweeps) don't need `entryDate` and shouldn't pay for
    /// the journal-wide scan it costs.
    func allAssets() -> [AssetItem] {
        guard let dir = assetsDirURL else { return [] }
        return Self.listAssets(in: dir)
    }

    /// The Assets browser's listing, off the main actor — stat-ing every file in
    /// a large assets folder (and reading the journal for their entry dates) is
    /// far too slow to do while the Assets view is appearing.
    func allAssetsAsync() async -> [AssetItem] {
        guard let dir = assetsDirURL, let base = baseURL else { return [] }
        return await Task.detached(priority: .userInitiated) {
            Self.listAssets(in: dir, entryDates: Self.assetEntryDates(base: base))
        }.value
    }

    nonisolated private static func listAssets(in dir: URL,
                                               entryDates: [String: Date] = [:]) -> [AssetItem] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let items = enumerator.allObjects.compactMap { $0 as? URL }
        return items
            .filter { !$0.hasDirectoryPath && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return AssetItem(url: url,
                                 modified: values?.contentModificationDate ?? .distantPast,
                                 entryDate: entryDates["assets/" + relativePath(of: url, under: dir)],
                                 size: values?.fileSize ?? 0)
            }
            .sorted { $0.name < $1.name }
    }

    /// Root-relative asset path → timestamp of its earliest referencing entry, built in
    /// one pass over the inbox, the day files and the split journals. One scan
    /// for the whole gallery: `usages(ofAsset:)` per file would re-read the
    /// entire journal once per thumbnail.
    nonisolated static func assetEntryDates(base: URL) -> [String: Date] {
        let stamps = DateFormatter()
        stamps.dateFormat = "yyyy-MM-dd HH:mm:ss"; stamps.locale = Locale(identifier: "en_US_POSIX")
        var map: [String: Date] = [:]
        for value in (try? CoreJournal(base: base).load()) ?? [] {
            guard let date = stamps.date(from: value.ts) else { continue }
            for path in MediaLinks.paths(in: value.raw) {
                guard let rel = MediaLinks.resolved(path, file: value.file) else { continue }
                if let current = map[rel], current <= date { continue }
                map[rel] = date
            }
        }
        return map
    }

    func deleteAsset(_ url: URL) { try? fm.removeItem(at: url) }

    nonisolated private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp",
    ]

    /// Conservatively checked unused assets; clearing retains recovery copies.
    func orphanAssets() -> [URL] {
        guard let baseURL, let core else { return [] }
        do { let files: [String] = try core.call("orphans"); return files.map { baseURL.appendingPathComponent($0) } }
        catch { lastWriteError = journalErrorMessage(error); return [] }
    }

    @discardableResult
    func deleteOrphanAssets() -> Int {
        let count: Int = coreMutation { try $0.call("delete_orphans") } ?? 0
        if count > 0 { scheduleRebuild() }
        return count
    }

    /// Entries that reference an asset by file name (for "go to file").
    func usages(ofAsset url: URL) -> [(entry: Entry, source: EntrySource)] {
        let wanted = assetRelativePath(url)
        func uses(_ entry: Entry) -> Bool {
            MediaLinks.paths(in: entry.raw).contains {
                MediaLinks.resolved($0, file: entry.file ?? "inbox.md") == wanted
            }
        }
        var result: [(entry: Entry, source: EntrySource)] = []
        for entry in inboxDrafts where uses(entry) { result.append((entry, .inbox)) }
        for day in archiveEntries {
            for entry in day.entries where uses(entry) { result.append((entry, .archive(date: day.date))) }
        }
        for (name, entries) in splitEntriesCache {
            for entry in entries where uses(entry) { result.append((entry, .journal(name: name))) }
        }
        return result
    }

    func usages(ofAsset fileName: String) -> [(entry: Entry, source: EntrySource)] {
        let needle = fileName
        var result: [(Entry, EntrySource)] = []
        for e in inboxDrafts where MediaLinks.paths(in: e.raw).contains(where: { ($0 as NSString).lastPathComponent == needle }) { result.append((e, .inbox)) }
        for day in archiveEntries {
            for e in day.entries where MediaLinks.paths(in: e.raw).contains(where: { ($0 as NSString).lastPathComponent == needle }) {
                result.append((e, .archive(date: day.date)))
            }
        }
        for (name, entries) in splitEntriesCache {
            for e in entries where MediaLinks.paths(in: e.raw).contains(where: { ($0 as NSString).lastPathComponent == needle }) {
                result.append((e, .journal(name: name)))
            }
        }
        return result
    }

    #if os(macOS)
    func revealAsset(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Reveal the markdown file backing an entry (inbox.md, a journal day file, or
    /// a split journal) in Finder, selecting it.
    func revealEntry(source: EntrySource) {
        let url: URL?
        switch source {
        case .inbox:            url = inboxURL
        case .archive(let d):   url = journalFileURL(for: d)
        case .journal(let n):   url = baseURL?.appendingPathComponent("split/\(n)")
        }
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    #endif

    /// Copy an existing file (e.g. a recorded video) into assets/ and return the
    /// relative path. Better than loading large media into memory.
    func importAsset(from url: URL) -> String? {
        guard let dir = newAssetsDirURL else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            try fm.copyItem(at: url, to: dest)
            let rel = assetRelativePath(dest)
            scheduleCompression(assetRelPath: rel)   // video/audio, in the background
            return rel
        } catch { return nil }
    }

    /// Save image data into the journal's assets folder and return the relative
    /// markdown-friendly path ("assets/<uuid>.<ext>"), or nil on failure. When
    /// Data Saver is on, raster images are downsampled/re-compressed first (format
    /// and extension preserved, so the markdown link stays valid).
    /// `text` with a link to `rel` as its own paragraph at `caret` (a UTF-16
    /// offset), or at the end when there's no caret to go by.
    nonisolated static func linking(_ rel: String, into text: String, at caret: Int?) -> String {
        let md = "![](\(rel))"
        let ns = text as NSString
        guard let caret, caret >= 0, caret < ns.length else {
            return text.isEmpty ? md : text + "\n\n" + md
        }
        let before = ns.substring(to: caret), after = ns.substring(from: caret)
        let lead = before.isEmpty || before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
        let trail = after.hasPrefix("\n\n") ? "" : after.hasPrefix("\n") ? "\n" : "\n\n"
        return before + lead + md + trail + after
    }

    func saveAsset(_ data: Data, ext: String) -> String? {
        guard let dir = newAssetsDirURL else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        var lower = ext.lowercased()
        var out = data
        let dataSaver = UserDefaults.standard.bool(forKey: "dataSaver")
        // An iPhone photo arrives as HEIC, which Wander on Linux and Android
        // can't show: it is stored as a JPEG instead (Data Saver's size applies
        // in the same pass, so it isn't encoded twice).
        if ImageDownsampler.convertible.contains(lower),
           let jpg = ImageDownsampler.jpeg(data, dataSaver: dataSaver) {
            out = jpg
            lower = "jpg"
        } else if dataSaver,
           ImageDownsampler.compressible.contains(lower),
           let shrunk = ImageDownsampler.downsample(data), shrunk.count < data.count {
            out = shrunk
        }
        let name = "\(id).\(lower)"
        do {
            try out.write(to: dir.appendingPathComponent(name), options: .atomic)
            if out.count < data.count { recordCompression(assetID: id, saved: data.count - out.count) }
            let rel = assetRelativePath(dir.appendingPathComponent(name))
            // Images are handled synchronously above; video/audio compress in the background.
            if !ImageDownsampler.compressible.contains(lower) { scheduleCompression(assetRelPath: rel) }
            return rel
        } catch {
            return nil
        }
    }

    // MARK: Data Saver (image compression + merged, per-device savings tally)

    /// One device's compression record. Each device writes ONLY its own file, so
    /// syncing several devices' files into `<base>/.quire/` never conflicts; the
    /// displayed total is the sum, and `assets` prevents re-compressing (and thus
    /// double-counting) an image another device already handled.
    private struct DataSaverRecord: Codable { var savedBytes = 0; var assets: [String] = [] }

    /// Stable per-device id (one per Mac/iPhone), generated once and kept locally.
    private var dataSaverDeviceID: String {
        let key = "dataSaverDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
    private func loadMyRecord() -> DataSaverRecord? {
        do {
            guard let data = try readSidecar(name: "datasaver-\(dataSaverDeviceID).json") else { return DataSaverRecord() }
            return try JSONDecoder().decode(DataSaverRecord.self, from: data)
        } catch { lastWriteError = journalErrorMessage(error); return nil }
    }
    private func saveMyRecord(_ rec: DataSaverRecord) {
        do { try writeSidecar(name: "datasaver-\(dataSaverDeviceID).json", data: JSONEncoder().encode(rec)) }
        catch { lastWriteError = journalErrorMessage(error) }
    }

    /// Every device record file in `<base>/.quire/`.
    private func allDataSaverRecords() -> [DataSaverRecord] {
        do { return try sidecarRecords(prefix: "datasaver-").map { try JSONDecoder().decode(DataSaverRecord.self, from: $0) } }
        catch { lastWriteError = journalErrorMessage(error); return [] }
    }

    /// Bytes saved across ALL devices (merged sum — the number shown in Settings).
    func totalDataSaved() -> Int { allDataSaverRecords().reduce(0) { $0 + $1.savedBytes } }

    /// Asset uuids already compressed on ANY device, so batch runs never repeat one.
    private func allCompressedAssetIDs() -> Set<String> {
        Set(allDataSaverRecords().flatMap(\.assets))
    }

    private func recordCompression(assetID: String, saved: Int) {
        guard var rec = loadMyRecord() else { return }
        rec.savedBytes += max(0, saved)
        if !rec.assets.contains(assetID) { rec.assets.append(assetID) }
        saveMyRecord(rec)
        dataSaved = totalDataSaved()
    }

    /// Mark an asset as handled (no bytes gained) so batch runs skip it next time.
    private func markHandled(assetID: String) {
        guard var rec = loadMyRecord() else { return }
        guard !rec.assets.contains(assetID) else { return }
        rec.assets.append(assetID)
        saveMyRecord(rec)
    }

    /// Kick off background video/audio transcoding for a just-attached asset (when
    /// Data Saver is on). The original is stored/returned immediately; the file is
    /// swapped in place (same name/extension) once the export finishes.
    func scheduleCompression(assetRelPath: String) {
        guard UserDefaults.standard.bool(forKey: "dataSaver"),
              let url = assetURL(forRelative: assetRelPath) else { return }
        let ext = url.pathExtension.lowercased()
        guard MediaTranscoder.video.contains(ext) || MediaTranscoder.audio.contains(ext) else { return }
        let id = url.deletingPathExtension().lastPathComponent
        Task.detached(priority: .background) {
            #if os(iOS)
            // Give the export a grace period if the app is backgrounded mid-encode.
            let bgTask = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "quire.compress") }
            defer { if bgTask != .invalid { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTask) } } }
            #endif
            let saved = await MediaTranscodeQueue.shared.run { await MediaTranscoder.compressInPlace(url: url, ext: ext) }
            await MainActor.run {
                if let saved, saved > 0 { self.recordCompression(assetID: id, saved: saved) }
                else { self.markHandled(assetID: id) }
            }
        }
    }

    struct MediaCompressionResult { var images = 0; var videos = 0; var audios = 0; var bytesSaved = 0; var converted = 0 }

    /// Turn every HEIC/HEIF in assets/ into a JPEG under the same UUID, and point
    /// every link at it, so the photo shows in Wander on Linux and Android too.
    /// Not filtered by the Data Saver ledger: a HEIC another device has marked
    /// handled (Quire on Linux can't read one) still wants converting.
    ///
    /// The JPEG is written first, then every file linking to the HEIC is
    /// rewritten, and only then is the HEIC removed — stopped at any point, every
    /// link still resolves. A file that can't be read (an iCloud placeholder, say)
    /// keeps the HEIC for the next run rather than leaving that file's link dead.
    @discardableResult
    func convertHEICAssets() -> Int {
        let items = allAssets().map(\.url)
        let heics = items.filter { ImageDownsampler.convertible.contains($0.pathExtension.lowercased()) }
        guard !heics.isEmpty else { return 0 }
        let dataSaver = UserDefaults.standard.bool(forKey: "dataSaver")
        let files = allContentFileURLs()

        var converted = 0
        for heic in heics {
            let jpgURL = heic.deletingLastPathComponent().appendingPathComponent("\(heic.deletingPathExtension().lastPathComponent).jpg")
            guard let data = try? Data(contentsOf: heic),
                  let jpg = ImageDownsampler.jpeg(data, dataSaver: dataSaver),
                  (try? jpg.write(to: jpgURL, options: .atomic)) != nil else { continue }
            var relinked = true
            for file in files where fm.fileExists(atPath: file.path) {
                guard let text = try? readContentFile(file) else { relinked = false; continue }
                guard let renamed = MediaLinks.renaming(text, from: heic.lastPathComponent,
                                                        to: jpgURL.lastPathComponent) else { continue }
                do { try writeFile(file, renamed) } catch { relinked = false }
            }
            if relinked {
                try? fm.removeItem(at: heic)
                converted += 1
            }
        }
        if converted > 0 { reload() }
        return converted
    }

    /// Compress existing media (images, video, audio) that no device has processed
    /// yet, in place (same filename/format, so markdown links are untouched). Images
    /// re-encode synchronously; video/audio transcode via the serial queue. Skips
    /// anything already handled elsewhere so nothing is compressed — or counted —
    /// twice. Async because video/audio export is long-running.
    @discardableResult
    func compressExistingMedia() async -> MediaCompressionResult {
        let converted = convertHEICAssets()
        let items = allAssets().map(\.url)
        let already = allCompressedAssetIDs()
        let candidates = items.filter { url in
            guard !url.hasDirectoryPath else { return false }
            let ext = url.pathExtension.lowercased()
            let known = ImageDownsampler.compressible.contains(ext)
                || MediaTranscoder.video.contains(ext) || MediaTranscoder.audio.contains(ext)
            return known && !already.contains(url.deletingPathExtension().lastPathComponent)
        }
        var res = MediaCompressionResult()
        res.converted = converted
        mediaProgress = (0, candidates.count)
        for (i, url) in candidates.enumerated() {
            let ext = url.pathExtension.lowercased()
            let id = url.deletingPathExtension().lastPathComponent
            if ImageDownsampler.compressible.contains(ext) {
                if let data = try? Data(contentsOf: url),
                   let shrunk = ImageDownsampler.downsample(data), shrunk.count < data.count,
                   (try? shrunk.write(to: url, options: .atomic)) != nil {
                    res.images += 1
                    res.bytesSaved += data.count - shrunk.count
                    recordCompression(assetID: id, saved: data.count - shrunk.count)
                } else {
                    markHandled(assetID: id)
                }
            } else {
                let saved = await MediaTranscodeQueue.shared.run { await MediaTranscoder.compressInPlace(url: url, ext: ext) }
                if let saved, saved > 0 {
                    if MediaTranscoder.video.contains(ext) { res.videos += 1 } else { res.audios += 1 }
                    res.bytesSaved += saved
                    recordCompression(assetID: id, saved: saved)
                } else {
                    markHandled(assetID: id)
                }
            }
            mediaProgress = (i + 1, candidates.count)
        }
        mediaProgress = nil
        reload()
        return res
    }

    // MARK: Headless add (App Intents)

    /// Append a draft to the inbox from outside the UI (Shortcuts/Siri/Spotlight).
    /// Resolves the journal folder exactly as the app does. Returns false if both
    /// title and body are empty.
    static func quickAddDraft(title: String, body: String) throws -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let resolved = resolveBase(bookmark: UserDefaults.standard.data(forKey: bookmarkKey), containerID: nil)
        guard let base = resolved.url else { throw JournalError.journalUnavailable }
        let started = resolved.scoped && base.startAccessingSecurityScopedResource()
        defer { if started { base.stopAccessingSecurityScopedResource() } }
        let core = CoreJournal(base: base)
        try core.migrate()
        let _: CoreWritten = try core.call("new", ["ts": nowTS(), "title": title, "body": body])
        return true
    }

    /// Number of drafts currently in the inbox (headless — for App Intents).
    static func inboxDraftCount() -> Int {
        let resolved = resolveBase(bookmark: UserDefaults.standard.data(forKey: bookmarkKey), containerID: nil)
        guard let base = resolved.url else { return 0 }
        let started = resolved.scoped && base.startAccessingSecurityScopedResource()
        defer { if started { base.stopAccessingSecurityScopedResource() } }
        return (try? CoreJournal(base: base).load().filter { $0.source == "inbox" }.count) ?? 0
    }


    /// Remove leftover `.quire-*.tmp` files from writes that never completed.
    /// Age-guarded so an in-flight write from another process (the intents
    /// extension) is never swept out from under it.
    nonisolated static func sweepStaleTempFiles(under base: URL) {
        Task.detached(priority: .background) { sweepStaleTempFilesNow(under: base) }
    }

    nonisolated private static func sweepStaleTempFilesNow(under base: URL) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for case let url as URL in en
        where url.lastPathComponent.hasPrefix(".quire-") && url.pathExtension == "tmp" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // MARK: Review actions (jnl cmdReview)

    /// File a draft into its day's journal file (or a split-tag file), then
    /// remove it from the inbox. Returns the label it was filed under.
    @discardableResult
    func fileDraft(_ entry: Entry) -> String? {
        let label: String? = coreMutation { core in
            var fields = try core.reference(entry); fields["tags"] = splitTags
            return try core.call("file", fields)
        }
        publishCoreChange()
        guard let label else { return nil }
        let parts = label.split(separator: "/")
        if parts.first == "split", parts.count > 1 { return "@" + String(parts[1]) }
        return entry.date
    }


    /// Send a filed entry (archive day or split journal) back to the inbox as a
    /// draft — the inverse of `fileDraft`. The entry is appended to the inbox
    /// verbatim first and only removed from its file once that write landed,
    /// so a failed write leaves it where it was rather than losing it.
    @discardableResult
    func returnToInbox(_ entry: Entry, source: EntrySource) -> Bool {
        guard source != .inbox else { return false }
        let written: CoreWritten? = coreMutation { try $0.call("unfile", $0.reference(entry)) }
        publishCoreChange()
        return written != nil
    }

    func deleteDraft(_ entry: Entry) {
        _ = coreMutation { try $0.delete(entry); return true }
        publishCoreChange()
    }

    /// Replace a draft's text (from the editor) and persist the inbox. Returns
    /// false when the draft couldn't be found or the write failed.
    @discardableResult
    func updateDraft(_ entry: Entry, newText: String, reindex: Bool = true) -> Bool {
        guard let result = coreMutation({ try $0.update(entry, text: newText) }) else { return false }
        lastWritten = result
        publishCoreChange(reindex: reindex)
        return true
    }

    func deleteEditorDraft(_ entry: Entry) -> Bool {
        let ok = coreMutation { try $0.delete(entry); return true } ?? false
        if ok { publishCoreChange() }
        return ok
    }

    /// Sort the inbox into date order in place (jnl cmdSort).
    func sortInbox() {
        let _: Bool? = coreMutation { try $0.call("sort") }
        publishCoreChange()
    }

    // MARK: Filed-entry editing (archive)

    /// Replace a filed entry within its day file. Matches the original entry by
    /// its raw text (falling back to an unambiguous timestamp). Removes the day
    /// file if it ends up empty. Re-dating an entry moves it to the day file its
    /// new timestamp belongs to — it used to stay behind under a foreign date
    /// header, invisible to every list that reads the file by name.
    /// Returns the source the entry now lives in, or nil if nothing was written.
    @discardableResult
    func updateFiledEntry(date: String, original: Entry, newText: String, reindex: Bool = true) -> EntrySource? {
        guard let result = coreMutation({ try $0.update(original, text: newText) }) else { return nil }
        lastWritten = result
        publishCoreChange(reindex: reindex)
        let date = String((JournalParser.parseEntries(result.raw).first?.ts ?? original.ts).prefix(10))
        return .archive(date: date)
    }

    /// Delete a filed entry from its day file (removes the file if now empty).
    @discardableResult
    func deleteFiledEntry(date: String, entry: Entry) -> Bool {
        let ok = coreMutation { try $0.delete(entry); return true } ?? false
        publishCoreChange()
        return ok
    }

    @discardableResult
    func fileTransfer() -> Int {
        let added: Int = coreMutation { try $0.call("file_transfer", ["ts": Self.nowTS(), "tags": splitTags]) } ?? 0
        publishCoreChange()
        return added
    }
    @discardableResult
    func mergeConflictCopies() -> Int {
        guard let core else { return 0 }
        var added = 0
        do {
            let files: [String] = try core.call("conflicts")
            for file in files { let count: Int = try core.call("merge_conflict", ["file": file]); added += count }
        } catch { lastWriteError = journalErrorMessage(error) }
        publishCoreChange()
        return added
    }

    // MARK: Bulk filing (jnl transfer)

    /// File every inbox draft into the archive. Returns how many were filed.
    /// Only drafts that actually filed are removed: one whose write failed
    /// stays in the inbox instead of being lost with it, and a draft another
    /// process added since our last load (Siri, jnl, a second device) is never
    /// touched.
    @discardableResult
    func fileAllDrafts() -> Int {
        struct Report: Decodable { let filed: Int; let errors: [String] }
        let report: Report? = coreMutation { try $0.call("file_all", ["tags": splitTags]) }
        if let report, !report.errors.isEmpty { lastWriteError = report.errors.joined(separator: "\n") }
        publishCoreChange()
        return report?.filed ?? 0
    }

    // MARK: Random (jnl cmdRandom)

    /// A uniform pick from the cached corpus — no disk walk.
    func randomEntry() -> (date: String, entry: Entry)? {
        let total = archiveEntries.reduce(0) { $0 + $1.entries.count }
        guard total > 0 else { return nil }
        var n = Int.random(in: 0..<total)
        for day in archiveEntries {
            if n < day.entries.count { return (day.date, day.entries[n]) }
            n -= day.entries.count
        }
        return nil
    }

    // MARK: Export (jnl cmdExport)

    /// All filed entries combined into one markdown string — dated days oldest
    /// first, then the split journals (they're filed entries too; leaving them
    /// out made "Export" quietly incomplete).
    func exportMarkdown() -> String {
        guard let core else { return "" }
        do {
            let entries = try core.load().filter { $0.source != "inbox" }.sorted { $0.ts < $1.ts }
            return JournalParser.renderEntries(preamble: "", entries: entries.map(\.entry))
        } catch { lastWriteError = journalErrorMessage(error); return "" }
    }

    // MARK: Cleanup (jnl cmdCleanup)

    struct CleanupResult { var moved = 0; var formatted = 0; var reordered = 0; var deduped = 0; var extracted = 0 }


    /// Move entries stored under the wrong day to the day file their header gives,
    /// standardise punctuation (… and straight quotes), retroactively route entries
    /// matching a configured split tag into their <tag>.md file, reorder each day
    /// by timestamp, and drop exact-duplicate entries. Returns what changed.
    @discardableResult
    func cleanup() -> CleanupResult {
        struct Report: Decodable { let moved: Int; let formatted: Int; let reordered: Int; let deduped: Int; let extracted: Int; let errors: [String] }
        let report: Report? = coreMutation { try $0.call("cleanup", ["tags": splitTags]) }
        publishCoreChange()
        guard let report else { return CleanupResult() }
        if !report.errors.isEmpty { lastWriteError = report.errors.joined(separator: "\n") }
        return CleanupResult(moved: report.moved, formatted: report.formatted, reordered: report.reordered, deduped: report.deduped, extracted: report.extracted)
    }

    struct MergeResult { var journals = 0; var entries = 0 }

    /// Merge "ex-split" journals — top-level `<tag>.md` files whose tag is no
    /// longer in the configured split tags — back into the dated main journal,
    /// filing each entry by its timestamp and removing the emptied split file.
    /// Entries that fail to move are left behind so the file isn't lost.
    @discardableResult
    func mergeExSplitJournals() -> MergeResult {
        struct Report: Decodable { let journals: Int; let entries: Int; let errors: [String] }
        let report: Report? = coreMutation { try $0.call("merge", ["tags": splitTags]) }
        publishCoreChange()
        guard let report else { return MergeResult() }
        if !report.errors.isEmpty { lastWriteError = report.errors.joined(separator: "\n") }
        return MergeResult(journals: report.journals, entries: report.entries)
    }

    // MARK: Stats (jnl cmdStats)

    struct Stats {
        var days = 0, entries = 0, words = 0
        var currentStreak = 0, bestStreak = 0
        var longestDay = "", longestDayWords = 0
        var bytes = 0
        var inboxBytes = 0, archiveBytes = 0
        var mediaBytes = 0
        /// `mediaBytes` broken down by kind; `otherMediaBytes` catches anything
        /// in assets/ that isn't recognisable image, video, or audio.
        var imageBytes = 0, videoBytes = 0, audioBytes = 0, otherMediaBytes = 0
        var inboxDrafts = 0, tags = 0, splitJournals = 0
        var wordsToday = 0
        var hasEntryToday = false
    }

    /// The corpus-derived half of `Stats` — everything that needs a walk over
    /// the journal and assets folders. Computed off-main in `rebuildIndex` and
    /// cached, so `stats()` and the widget snapshot are free.
    struct HeavyStats: Sendable {
        var days = 0, entries = 0, words = 0
        var currentStreak = 0, bestStreak = 0
        var longestDay = "", longestDayWords = 0
        var journalBytes = 0, inboxBytes = 0
        var imageBytes = 0, videoBytes = 0, audioBytes = 0, otherMediaBytes = 0
        /// Words written today (filed + drafts dated today) — drives the word goal.
        var wordsToday = 0
        var hasEntryToday = false
        /// Entries in today's journal day file — the widget's "two entries filed".
        var filedToday = 0
        /// "On this day" — entries from this calendar day in past years.
        var onThisDayCount = 0
        var onThisDayPreview = ""
        /// The body line after the preview, for the widget's second line.
        var onThisDayExcerpt = ""
        var onThisDayYearsAgo = 0
        /// Where the teased entry lives, so the widget can deep-link to it.
        var onThisDayDate = ""
        var onThisDayTS = ""
    }

    /// Streaks and on-disk sizes — the parts of the stats pass that aren't
    /// per-file. Called by `buildIndex` after its single read of the corpus.
    nonisolated static func finishHeavyStats(_ s: inout HeavyStats, base: URL, dates: [Date]) {
        let fm = FileManager.default
        var dates = dates
        dates.sort()
        let cal = Calendar.current
        var run = 0
        for (i, d) in dates.enumerated() {
            if i > 0, let prev = cal.date(byAdding: .day, value: 1, to: dates[i-1]),
               cal.isDate(prev, inSameDayAs: d) { run += 1 } else { run = 1 }
            s.bestStreak = max(s.bestStreak, run)
        }
        // Current streak, counted back from today — or from yesterday when
        // today is still unwritten, so a live streak doesn't read as 0 all
        // morning (in the app and on the widget) just because today's entry
        // isn't in yet. Days after today are dropped first: one future-dated
        // entry (a typo, a note written ahead) used to anchor the walk past
        // today and read the whole streak as 0.
        let today = cal.startOfDay(for: Date())
        // `dates` is sorted, so the future is a suffix: one cut, not a
        // Calendar call per date.
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? .distantFuture
        let upToToday = Array(dates.prefix { $0 < tomorrow })
        var anchor = today
        if let last = upToToday.last, !cal.isDate(last, inSameDayAs: today),
           let yesterday = cal.date(byAdding: .day, value: -1, to: today) {
            anchor = yesterday
        }
        var cur = 0
        for i in stride(from: upToToday.count - 1, through: 0, by: -1) {
            guard let expected = cal.date(byAdding: .day, value: -cur, to: anchor) else { break }
            if cal.isDate(upToToday[i], inSameDayAs: expected) { cur += 1 } else { break }
        }
        s.currentStreak = cur

        // Sizes: markdown under the base (minus scratch files), the inbox,
        // and assets/ split by kind. Stat-only — no file reads.
        if let en = fm.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in en
            where url.pathExtension == "md" && !url.path.contains("/.quire/") && !url.path.contains("/.nook/") && !nonJournalFiles.contains(url.lastPathComponent) {
                s.journalBytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        s.inboxBytes = 0
        if let files: [String] = try? CoreJournal(base: base).call("files") {
            for rel in files where rel == "inbox.md" || rel.hasPrefix("inbox/") {
                s.inboxBytes += (try? base.appendingPathComponent(rel).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        let assetsDir = base.appendingPathComponent("assets", isDirectory: true)
        if let en = fm.enumerator(at: assetsDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in en where !url.hasDirectoryPath {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let ext = url.pathExtension.lowercased()
                switch MediaKind(path: url.lastPathComponent) {
                case .video: s.videoBytes += size
                case .audio: s.audioBytes += size
                case .image:
                    if imageExtensions.contains(ext) { s.imageBytes += size } else { s.otherMediaBytes += size }
                }
            }
        }
    }

    /// Non-journal markdown files that live in the folder but aren't journal data
    /// (jnl's transfer scratch file and export outputs). Excluded from size totals.
    nonisolated private static let nonJournalFiles: Set<String> = ["transfer.md", "export.md", "quire-export.md"]

    /// Cheap: assembles the cached off-main corpus pass with the live counts.
    func stats() -> Stats {
        let heavy = lastHeavyStats
        var s = Stats()
        s.days = heavy.days; s.entries = heavy.entries; s.words = heavy.words
        s.currentStreak = heavy.currentStreak; s.bestStreak = heavy.bestStreak
        s.longestDay = heavy.longestDay; s.longestDayWords = heavy.longestDayWords
        s.bytes = heavy.journalBytes
        s.inboxBytes = heavy.inboxBytes
        s.archiveBytes = max(0, s.bytes - s.inboxBytes)
        s.imageBytes = heavy.imageBytes
        s.videoBytes = heavy.videoBytes
        s.audioBytes = heavy.audioBytes
        s.otherMediaBytes = heavy.otherMediaBytes
        s.mediaBytes = heavy.imageBytes + heavy.videoBytes + heavy.audioBytes + heavy.otherMediaBytes
        s.inboxDrafts = inboxDrafts.count
        s.tags = tagCounts.count
        s.splitJournals = splitJournals.count
        s.wordsToday = heavy.wordsToday
        s.hasEntryToday = heavy.hasEntryToday
        return s
    }

    #if os(macOS)
    /// Reveal the journal folder in Finder (jnl open).
    func revealInFinder() {
        if let baseURL { NSWorkspace.shared.activateFileViewerSelecting([baseURL]) }
    }

    func revealBackupFolder() {
        guard let url = resolveBackupURL() else { return }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    // MARK: Read-modify-write safety

    /// Read a file that is about to be rewritten. "" when it doesn't exist yet;
    /// a throw when it exists but can't be decoded. The old
    /// `(try? String(contentsOf:)) ?? ""` couldn't tell those two apart, so a
    /// single non-UTF-8 byte (a hand edit, a jnl write, an evicted iCloud file,
    /// a transient permission error) read as an empty file — and the atomic
    /// replace that followed threw the original away.
    nonisolated static func readForRewrite(_ url: URL) throws -> String {
        try CoreJournal(base: url.deletingLastPathComponent()).text(url.lastPathComponent)
    }


    /// Note a write that didn't happen, so the caller can skip its cache patch

    /// Locate an entry inside a file's parsed entries for a rewrite. Exact raw

    /// `raw == want` apart from trailing newlines — what `trimRightNewlines`

    // MARK: Embedded headers (one editor's text is always one entry)

    /// How many `[timestamp]` headers a piece of body text carries. The on-disk
    /// format has no escape for a header line, so a body holding its own
    /// headers would parse back as several entries — the composer offers to
    /// import such a paste rather than writing it as one draft.
    ///
    /// One scan over Substrings, and the header regex only for a line that
    /// starts with `[` — this runs on every autosave (`makeEntry`), where a
    /// full `parseEntries` used to build the entries just to count them.
    nonisolated static func embeddedEntryCount(in body: String) -> Int {
        var n = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false)
        where line.first == "[" && JournalParser.isHeaderLine(String(line)) { n += 1 }
        return n
    }

    /// True when this single line would parse as a jnl entry header.
    nonisolated static func isEntryHeader(_ line: String) -> Bool {
        JournalParser.isHeaderLine(line)
    }

    /// Backslash-escape every line that would parse as an entry header, so the
    /// text stays one entry. `skippingFirstLine` spares an entry's own header.
    /// A markdown `\[` is the standard literal-bracket escape and renders as
    /// `[`; indenting instead wouldn't survive the parser's body trim.
    ///
    /// Same single scan as `embeddedEntryCount`: the lines are only copied
    /// into a new string once a header has actually been found, so the
    /// common body costs one pass and no allocation.
    nonisolated static func escapingEmbeddedHeaders(_ text: String, skippingFirstLine: Bool) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var escaped: [Substring]? = nil
        for (i, line) in lines.enumerated() where !(skippingFirstLine && i == 0) {
            guard line.first == "[", JournalParser.isHeaderLine(String(line)) else { continue }
            if escaped == nil { escaped = Array(lines) }
            escaped![i] = Substring("\\" + line)
        }
        guard let escaped else { return text }
        return escaped.joined(separator: "\n")
    }

    // MARK: Atomic write (jnl writeFile)

    /// Write via temp-file + rename so an interrupted write never truncates the
    /// user's only copy of their notes. Storage is coordinated by AppleVault.
    private func writeFile(_ url: URL, _ content: String) throws {
        guard let base = baseURL, let core else { throw JournalError.journalUnavailable }
        let prefix = base.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw JournalError.journalUnavailable }
        try core.write(String(url.standardizedFileURL.path.dropFirst(prefix.count)), content)
        lastLocalWriteAt = Date()
        journalDidChange()
    }

    // MARK: Shared-in drafts (share extension handoff)

    /// Where the share extension leaves what it captured: a `pending.md` of
    /// jnl-format drafts plus an `assets/` folder of media, inside the App
    /// Group container — the extension can't reach a custom journal folder's
    /// security-scoped bookmark, so the app moves everything in from here.
    nonisolated static var pendingShareDir: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: QuireSnapshot.suiteName)?
            .appendingPathComponent("PendingShare", isDirectory: true)
    }

    /// Move anything the share extension captured into the journal: media into
    /// `<base>/assets/` (the pending drafts already link them by that path),
    /// the drafts onto the end of the inbox. Runs on every reload, so shares
    /// land on the next launch or foreground.
    private func drainPendingShares() {
        #if DEBUG
        if isTestStore { return }
        #endif
        guard let dir = Self.pendingShareDir, baseURL != nil else { return }
        // Claim the handoff by renaming it *before* reading. The extension only
        // ever appends to pending.md, so a share captured between our read and
        // our delete used to land in the file we then threw away. `.processing`
        // files left behind by a drain that crashed are picked up here too.
        let pendingFile = dir.appendingPathComponent("pending.md")
        if fm.fileExists(atPath: pendingFile.path) {
            try? fm.moveItem(at: pendingFile,
                             to: dir.appendingPathComponent("\(UUID().uuidString).processing"))
        }
        func captured(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        let claimed = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "processing" }
            .sorted { captured($0) < captured($1) }
        guard !claimed.isEmpty else { return }
        let shared = claimed.flatMap {
            JournalParser.parseEntries((try? String(contentsOf: $0, encoding: .utf8)) ?? "")
        }
        // Media first, so the links resolve the moment the drafts appear.
        let pendingAssets = dir.appendingPathComponent("assets", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: pendingAssets, includingPropertiesForKeys: nil),
           let assetsDir = baseURL?.appendingPathComponent("assets", isDirectory: true) {
            try? fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            for item in items {
                let dest = assetsDir.appendingPathComponent(item.lastPathComponent)
                try? fm.moveItem(at: item, to: dest)
                scheduleCompression(assetRelPath: "assets/\(item.lastPathComponent)")
            }
        }
        if !shared.isEmpty {
            // An unreadable inbox keeps the claimed files for the next reload
            // rather than being replaced by the shares alone.
            guard let core else { return }
            do {
                for (date, entries) in Dictionary(grouping: shared, by: \.date) {
                    let _: Int = try core.call("insert", ["file": "inbox/" + date.replacingOccurrences(of: "-", with: "/") + ".md", "raws": entries.map(\.raw)])
                }
            } catch { lastWriteError = journalErrorMessage(error); return }
        }
        for url in claimed { try? fm.removeItem(at: url) }
    }

    // MARK: Import (external journals → filed entries)

    /// Append filed entries directly to their day files (no split routing),
    /// skipping any whose exact text is already there — so re-running an
    /// import can't duplicate. Returns how many were written.
    @discardableResult
    func appendFiledEntries(_ entries: [Entry]) -> Int {
        var added = 0
        for (date, entries) in Dictionary(grouping: entries, by: \.date) {
            let count: Int = coreMutation { try $0.call("insert", ["file": "journal/" + date.replacingOccurrences(of: "-", with: "/") + ".md", "raws": entries.map(\.raw)]) } ?? 0
            added += count
        }
        if added > 0 { reload() }
        return added
    }

    // MARK: Cross-file helpers (for feature extensions in other files)

    /// Stable per-device id, shared with Data Saver's record files — feature
    /// extensions (transcription records) key their `.quire/` files by it too.
    var deviceRecordID: String {
        let key = "dataSaverDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Every journal content file: the inbox, all day files, all split journals.
    func allContentFileURLs() -> [URL] {
        guard let baseURL, let core, let files: [String] = try? core.call("files") else { return [] }
        return files.map { baseURL.appendingPathComponent($0) }
    }

    func readContentFile(_ url: URL) throws -> String {
        guard let baseURL, let core else { throw JournalError.journalUnavailable }
        let prefix = baseURL.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw JournalError.journalUnavailable }
        return try core.text(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
    }

    /// Atomic rewrite of one journal content file (feature extensions can't
    /// reach the private writeFile).
    @discardableResult
    func rewriteContentFile(_ url: URL, _ content: String) -> Bool {
        do { try writeFile(url, content); return true }
        catch { lastWriteError = journalErrorMessage(error); return false }
    }

    /// Maintenance progress for extensions that batch over media (mediaProgress
    /// is otherwise settable only from this file).
    func setMediaProgress(_ p: (done: Int, total: Int)?) {
        mediaProgress = p
    }

    // MARK: On This Day

    /// Filed entries from this calendar day in previous years, newest year
    /// first. Cheap: the day list is already indexed, so only the handful of
    /// matching day files are read.
    func onThisDay(reference: Date = Date()) -> [(date: String, entries: [Entry])] {
        let iso = Self.ts(from: reference).prefix(10)
        let monthDay = String(iso.suffix(5))
        let thisYear = String(iso.prefix(4))
        return archiveDays
            .filter { $0.date.hasSuffix(monthDay) && $0.year < thisYear }
            .sorted { $0.date > $1.date }
            .map { (date: $0.date, entries: entries(for: $0.date)) }
            .filter { !$0.entries.isEmpty }
    }

    // MARK: Live sync refresh

    /// iCloud: an NSMetadataQuery over the ubiquity container fires when
    /// another device changes a journal file, and the store reloads — no
    /// relaunch needed. Local/custom folders get a directory watcher on the
    /// base and journal folders instead (edits deeper in the tree are still
    /// picked up by the existing reload on foreground).
    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [NSObjectProtocol] = []
    private var dirWatchers: [DispatchSourceFileSystemObject] = []
    private var syncReloadTask: Task<Void, Never>?
    /// When we last wrote a journal file ourselves — the watcher's echo of our
    /// own write is suppressed rather than reloaded.
    private var lastLocalWriteAt = Date.distantPast

    private func startSyncWatcher() {
        stopSyncWatcher()
        if storageMode == .iCloud {
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(format: "%K LIKE '*.md'", NSMetadataItemFSNameKey)
            let center = NotificationCenter.default
            for name in [Notification.Name.NSMetadataQueryDidUpdate, .NSMetadataQueryDidFinishGathering] {
                metadataObservers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleSyncReload() }
                })
            }
            query.start()
            metadataQuery = query
        } else if let base = baseURL {
            for url in [base, base.appendingPathComponent("journal", isDirectory: true)] {
                let fd = open(url.path, O_EVTONLY)
                guard fd >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: .write, queue: .main)
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleSyncReload() }
                }
                source.setCancelHandler { close(fd) }
                source.resume()
                dirWatchers.append(source)
            }
        }
    }

    private func stopSyncWatcher() {
        metadataQuery?.stop()
        metadataQuery = nil
        for o in metadataObservers { NotificationCenter.default.removeObserver(o) }
        metadataObservers = []
        for w in dirWatchers { w.cancel() }
        dirWatchers = []
    }

    /// Debounced: sync updates arrive in bursts, and our own writes echo back
    /// through the watcher — a change landing within 2s of a local write is us.
    private func scheduleSyncReload(after delay: TimeInterval = 1.5) {
        syncReloadTask?.cancel()
        syncReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            // Our own write, echoing straight back through the watcher. Skip
            // it — but not forever: continuous autosave keeps every check
            // inside the echo window, and simply deferring each one (as this
            // did) turned every pause in typing into a full conflict scan and
            // corpus reload. Suppress the echo, and let a check through once
            // the session has gone `syncStarvationCeiling` without one, so a
            // change from another device can't wait out the whole session.
            if now.timeIntervalSince(self.lastLocalWriteAt) < 2,
               now.timeIntervalSince(self.lastSyncCheckAt) < Self.syncStarvationCeiling {
                self.scheduleSyncReload(after: 2)
                return
            }
            self.lastSyncCheckAt = now
            await self.resolveFileConflicts()
            guard !Task.isCancelled else { return }
            self.reload()
        }
    }

    /// How long a writing session may go without the watcher getting a look in.
    private static let syncStarvationCeiling: TimeInterval = 20
    /// When a sync check last actually ran (as opposed to being suppressed as
    /// our own echo).
    private var lastSyncCheckAt = Date.distantPast

    /// iCloud file-version conflicts merge as "keep both": any entry a
    /// conflicting version has that the current file doesn't is appended, then
    /// the versions are marked resolved. Covers the inbox, every day file, and
    /// the split journals — a two-device day used to resolve silently to
    /// whichever version won. With plain text, keeping both is always safe;
    /// Clean Up removes exact duplicates.
    /// Finding the conflicts is a walk of the whole corpus, so it runs off the
    /// main actor; only the merge itself (which rewrites files and touches the
    /// caches) comes back. This used to enumerate every day file and ask
    /// `NSFileVersion` about each one on the main actor — ~200 ms of stall on a
    /// journal of a few thousand entries, every time the watcher fired.
    private func resolveFileConflicts() async {
        guard let base = baseURL else { return }
        let splits = splitJournals.compactMap { baseURL?.appendingPathComponent("split/\($0.name)") }
        let conflicted = await Task.detached(priority: .utility) {
            Self.filesWithConflicts(base: base, splits: splits)
        }.value
        for url in conflicted { resolveConflicts(at: url) }
    }

    /// The subset of journal files carrying unresolved iCloud conflicts.
    ///
    /// `NSFileVersion.unresolvedConflictVersionsOfItem` is expensive per file,
    /// so it is only asked about files the much cheaper resource-value flag has
    /// already singled out. A file that isn't in iCloud can't have one of these
    /// conflicts at all, which makes this free for a local or custom folder.
    private nonisolated static func filesWithConflicts(base: URL, splits: [URL]) -> [URL] {
        let fm = FileManager.default
        guard let files: [String] = try? CoreJournal(base: base).call("files") else { return [] }
        return files.map { base.appendingPathComponent($0) }.filter { url in
            guard fm.isUbiquitousItem(at: url),
                  (try? url.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey]).ubiquitousItemHasUnresolvedConflicts) == true else { return false }
            return !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty
        }
    }

    private func resolveConflicts(at url: URL) {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty,
              let baseURL, let core else { return }
        let prefix = baseURL.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { return }
        let rel = String(url.standardizedFileURL.path.dropFirst(prefix.count))
        for version in versions {
            do {
                let other = try String(contentsOf: version.url, encoding: .utf8)
                let _: Int = try core.call("merge_content", ["file": rel, "content": other])
                version.isResolved = true
            } catch { lastWriteError = journalErrorMessage(error) }
        }
    }

    // MARK: Time helpers

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func nowTS() -> String { tsFormatter.string(from: Date()) }
    static func nowDate() -> String { dateFormatter.string(from: Date()) }
    /// Convert a Date (from the composer's date picker) to a jnl timestamp.
    static func ts(from date: Date) -> String { tsFormatter.string(from: date) }
    /// Parse a jnl timestamp back into a Date (for the composer's date picker).
    static func date(from ts: String) -> Date? { tsFormatter.date(from: ts) }

    enum JournalError: Error, LocalizedError {
        case nothingToFile, badPath, journalUnavailable

        var errorDescription: String? {
            switch self {
            case .nothingToFile: return "There was nothing to file."
            case .badPath:       return "That entry isn't dated, so it has nowhere to go."
            case .journalUnavailable:
                return "Quire can't reach your journal folder. Open Quire to find it again."
            }
        }
    }
}

// MARK: - Security-scoped folder bookmarks (cross-platform)

/// Persists access to a user-chosen folder across launches. Under the sandbox a
/// picked folder is only reachable via a security-scoped bookmark.
enum FolderAccess {
    static func makeBookmark(_ url: URL) -> Data? {
        #if os(macOS)
        return try? url.bookmarkData(options: .withSecurityScope,
                                     includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try? url.bookmarkData(options: [],
                                     includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// Resolve a bookmark. `stale` means the system handed back a usable URL
    /// but wants a fresh bookmark minted from it — ignoring that is how a
    /// renamed folder eventually stops resolving at all.
    static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: options,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// Mint a replacement for a bookmark the system reported stale. Making a
    /// security-scoped bookmark needs access to the folder, so open the scope
    /// around the call.
    static func remint(_ url: URL) -> Data? {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return makeBookmark(url)
    }

    /// The folder's name straight out of the bookmark, without resolving it —
    /// the only thing left to name a folder we can no longer reach.
    static func name(inBookmark data: Data) -> String? {
        URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: data)?.name
    }
}

/// Data Saver image compression. Uses ImageIO (identical on iOS and macOS), and
/// re-encodes in the source's OWN format so the file extension — and therefore
/// the `![](assets/<uuid>.<ext>)` markdown link — never changes.
enum ImageDownsampler {
    /// Raster formats we'll re-encode. GIF is excluded (would flatten animation).
    static let compressible: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"]
    /// Formats stored as JPEG instead, because not every app over the folder can
    /// decode them.
    static let convertible: Set<String> = ["heic", "heif"]

    /// Re-encode as JPEG, orientation baked in. With Data Saver on, at Data
    /// Saver's size and quality; off, at full size and high quality — this is
    /// about being readable everywhere, not about space.
    static func jpeg(_ data: Data, dataSaver: Bool) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let edge: Int
        if dataSaver {
            edge = 2048
        } else {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            edge = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                       props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
            guard edge > 0 else { return nil }
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg,
            [kCGImageDestinationLossyCompressionQuality: dataSaver ? 0.7 : 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Downsample to `maxPixel` on the longest edge and re-encode in the same
    /// format at `quality` (lossy formats only). Returns nil if not a decodable
    /// image or on failure — callers keep the original bytes in that case.
    static func downsample(_ data: Data, maxPixel: Int = 2048, quality: Double = 0.7) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,          // bake in EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// Serialises transcode jobs so only one AVAssetExportSession / writer runs at a
/// time — several concurrent 720p exports would spike memory. Shared by the
/// on-attach background path and the batch action.
actor MediaTranscodeQueue {
    static let shared = MediaTranscodeQueue()
    private var tail: Task<Void, Never> = Task {}

    func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let prior = tail
        let work = Task { () -> T in
            await prior.value            // wait for all earlier jobs
            return await operation()
        }
        tail = Task { _ = await work.value }   // next caller waits for me
        return await work.value
    }
}

/// Data Saver video/audio compression (AVFoundation). Re-encodes in place keeping
/// the original container/extension, so `![](assets/<uuid>.<ext>)` links stay valid.
enum MediaTranscoder {
    static let video: Set<String> = ["mov", "mp4", "m4v"]
    /// Only m4a — AAC output can't validly keep a .wav/.mp3 extension, and m4a is
    /// the only audio Quire records anyway.
    static let audio: Set<String> = ["m4a"]

    static func fileType(forExt ext: String) -> AVFileType? {
        switch ext {
        case "mov": return .mov
        case "mp4": return .mp4
        case "m4v": return .m4v
        case "m4a": return .m4a
        default:    return nil
        }
    }

    /// Transcode `url` to a temp file and, if the result is smaller, atomically swap
    /// it in place. Returns bytes saved, or nil if skipped / no gain / failure.
    static func compressInPlace(url: URL, ext: String) async -> Int? {
        let fm = FileManager.default
        guard let originalSize = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, originalSize > 0
        else { return nil }
        let tmp = url.deletingLastPathComponent().appendingPathComponent("._tmp_\(UUID().uuidString).\(ext)")
        let ok: Bool
        if video.contains(ext) {
            ok = await transcodeVideo(from: url, to: tmp, as: fileType(forExt: ext) ?? .mov)
        } else if audio.contains(ext) {
            ok = await transcodeAudio(from: url, to: tmp)
        } else {
            ok = false
        }
        guard ok, let newSize = try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int, newSize < originalSize else {
            try? fm.removeItem(at: tmp)
            return nil
        }
        // Coordinated, so the swap can't race an iCloud sync of the same file
        // (the coordinator serialises us against any presenter/daemon writer).
        var swapped: Int?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: nil) { dest in
            if (try? fm.replaceItemAt(dest, withItemAt: tmp)) != nil {
                swapped = originalSize - newSize
            }
        }
        if swapped == nil { try? fm.removeItem(at: tmp) }
        return swapped
    }

    /// 720p H.264 re-encode. Uses the completion-handler API (async `export()` is
    /// iOS 18 / macOS 15 only; deployment here is iOS 17 / macOS 14).
    static func transcodeVideo(from src: URL, to dest: URL, as type: AVFileType) async -> Bool {
        let asset = AVURLAsset(url: src)
        // If the preset is incompatible the export simply fails → caller keeps the original.
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720)
        else { return false }
        // Used only within this function and its completion handler (single queue).
        nonisolated(unsafe) let export = session
        export.outputURL = dest
        export.outputFileType = type
        export.shouldOptimizeForNetworkUse = true
        return await withCheckedContinuation { cont in
            export.exportAsynchronously { cont.resume(returning: export.status == .completed) }
        }
    }

    /// Re-encode audio to ~48 kbps mono AAC (.m4a) via reader → writer.
    static func transcodeAudio(from src: URL, to dest: URL) async -> Bool {
        let asset = AVURLAsset(url: src)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let r = try? AVAssetReader(asset: asset),
              let w = try? AVAssetWriter(outputURL: dest, fileType: .m4a) else { return false }
        // These AVFoundation objects are driven only from the writer's own queue below.
        nonisolated(unsafe) let reader = r
        nonisolated(unsafe) let writer = w
        nonisolated(unsafe) let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        guard reader.canAdd(readerOutput) else { return false }
        reader.add(readerOutput)

        nonisolated(unsafe) let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 48000,
        ])
        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "quire.audio.transcode")
        return await withCheckedContinuation { cont in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(buffer)
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            cont.resume(returning: writer.status == .completed && reader.status == .completed)
                        }
                        return
                    }
                }
            }
        }
    }
}
