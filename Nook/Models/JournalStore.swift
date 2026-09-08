//
//  JournalStore.swift
//  Nook
//
//  The app's data layer. Owns the on-disk journal (iCloud ubiquity container
//  when available, local Documents otherwise) and exposes the inbox + archive
//  to SwiftUI. Filing / sorting / atomic writes are ported from ~/Code/jnl/main.go.
//
//  Storage layout (identical to jnl, so the `jnl` CLI can point JNL_DIR here):
//      <base>/inbox.md                     — unsorted drafts
//      <base>/journal/YYYY/MM/DD.md         — filed entries, one file per day
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

/// How often Nook copies the journal folder to the backup location by itself.
enum BackupInterval: String, CaseIterable, Identifiable {
    case off, daily, weekly, onChange
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:      return "Off"
        case .daily:    return "Daily"
        case .weekly:   return "Weekly"
        case .onChange: return "On every change"
        }
    }

    /// Seconds that must pass before another scheduled backup is due — nil for
    /// the settings that aren't time-based (`off`, `onChange`).
    var scheduledGap: TimeInterval? {
        switch self {
        case .daily:  return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
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
    /// The parsed corpus (dated journal files), newest day first — built
    /// off-main with the index. The one copy every list reads from.
    @Published private(set) var archiveEntries: [(date: String, entries: [Entry])] = []
    /// Parsed split-journal entries, by journal name — same lifecycle.
    @Published private(set) var splitEntriesCache: [String: [Entry]] = [:]
    /// Total bytes reclaimed by Data Saver, merged across all devices (sum of
    /// every per-device record in `<base>/.nook/`). Recomputed on reload.
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
    /// Nook stops reading and writing until it's found again or the default is
    /// taken back — falling through to iCloud would quietly start a second
    /// journal, and the next launch would hide everything written into it.
    @Published private(set) var unavailableFolder: String?

    /// The unavailable-folder banner's copy, in one place.
    var storageUnavailableMessage: String? {
        guard let name = unavailableFolder else { return nil }
        return "Nook can't reach “\(name)”. Nothing is being saved until you find the folder again."
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
    /// Tags routed to their own `<base>/<tag>.md` file (jnl JNL_SPLIT_TAGS).
    /// Read live from the "splitTags" preference (space/comma separated).
    var splitTags: [String] {
        let raw = UserDefaults.standard.string(forKey: "splitTags") ?? ""
        return raw.split(whereSeparator: { $0 == " " || $0 == "," })
            .map { let s = String($0); return s.hasPrefix("@") ? s : "@" + s }
    }

    private let fm = FileManager.default

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
    /// Documents/Nook folder. The chosen folder is the journal base directly —
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
            .appendingPathComponent("Nook", isDirectory: true)
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

    /// Point Nook at a user-selected folder (from a file importer). It becomes
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
        let name = "Nook-Backup-\(Self.stampFormatter.string(from: Date()))"
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
        let name: String       // "Nook-Backup-YYYY-MM-dd-HH-mm-ss"
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
                .filter { $0.hasPrefix("Nook-Backup-") }
                .sorted(by: >)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return names.map {
                BackupCopy(name: $0, date: f.date(from: String($0.dropFirst("Nook-Backup-".count))))
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
        let safetyName = "Nook-Backup-\(Self.stampFormatter.string(from: Date()))"
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
        guard fm.fileExists(atPath: backup.appendingPathComponent("inbox.md").path)
                || fm.fileExists(atPath: backup.appendingPathComponent("journal").path) else {
            return (false, "That folder doesn't look like a Nook backup — nothing was changed.")
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
            .filter { $0.hasPrefix("Nook-Backup-") }
            .sorted(by: >)
        for stale in names.dropFirst(keep) {
            try? fm.removeItem(at: backupBase.appendingPathComponent(stale))
        }
    }

    // MARK: Paths
    private var inboxURL: URL? { baseURL?.appendingPathComponent("inbox.md") }
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
        drainPendingShares()
        loadInbox()
        rebuildIndex()   // bumps `revision`
        dataSaved = totalDataSaved()
    }

    /// What the journal looked like at the last reload — a stat-only walk
    /// (count + mtimes + sizes), no file reads.
    private var lastFingerprint = ""

    /// Foreground/activation path: skip the full reload when nothing on disk
    /// changed. Every app-switch used to trigger a complete corpus re-read.
    func reloadIfChanged() {
        guard let base = baseURL else { return }
        let previous = lastFingerprint
        Task.detached(priority: .userInitiated) { [weak self] in
            let fp = Self.contentFingerprint(base: base)
            guard fp != previous else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastFingerprint = fp
                self.reload()
            }
        }
    }

    /// Cheap change detector over inbox.md + every journal/split md file.
    nonisolated static func contentFingerprint(base: URL) -> String {
        let fm = FileManager.default
        var count = 0
        var totalSize = 0
        var maxMtime = 0.0
        func stat(_ url: URL) {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return }
            count += 1
            totalSize += v.fileSize ?? 0
            maxMtime = max(maxMtime, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        stat(base.appendingPathComponent("inbox.md"))
        if let en = fm.enumerator(at: base.appendingPathComponent("journal", isDirectory: true),
                                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let u as URL in en where u.pathExtension == "md" { stat(u) }
        }
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for u in items where u.pathExtension == "md" { stat(u) }
        }
        return "\(count)|\(totalSize)|\(maxMtime)"
    }

    private func loadInbox() {
        guard let inboxURL else { inboxDrafts = []; return }
        Self.ensureDownloaded(inboxURL)
        guard let content = try? String(contentsOf: inboxURL, encoding: .utf8) else {
            inboxDrafts = []
            return
        }
        inboxDrafts = JournalParser.parseEntries(content)
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
    private func scheduleRebuild() {
        rebuildDebounce?.cancel()
        rebuildDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.rebuildIndex()
        }
    }

    /// Patch the published corpus + day index for one date, from entries the
    /// mutation already has in hand — so lists refresh instantly instead of
    /// waiting for the full-corpus rebuild (which follows, debounced).
    private func patchArchiveCache(date: String, entries: [Entry]) {
        var day: ArchiveDay?
        if !entries.isEmpty {
            var d = ArchiveDay(date: date, count: entries.count,
                               preview: entries.first?.preview ?? "")
            d.hasStarred = entries.contains { $0.isStarred }
            for e in entries {
                for path in MediaLinks.paths(in: e.raw) {
                    switch MediaKind(path: path) {
                    case .image: d.hasPhoto = true
                    case .video: d.hasVideo = true
                    case .audio: d.hasAudio = true
                    }
                }
            }
            day = d
        }
        // archiveEntries and archiveDays are newest-date-first.
        if let i = archiveEntries.firstIndex(where: { $0.date == date }) {
            if entries.isEmpty { archiveEntries.remove(at: i) }
            else { archiveEntries[i] = (date: date, entries: entries) }
        } else if !entries.isEmpty {
            let i = archiveEntries.firstIndex(where: { $0.date < date }) ?? archiveEntries.count
            archiveEntries.insert((date: date, entries: entries), at: i)
        }
        if let i = archiveDays.firstIndex(where: { $0.date == date }) {
            if let day { archiveDays[i] = day } else { archiveDays.remove(at: i) }
        } else if let day {
            let i = archiveDays.firstIndex(where: { $0.date < date }) ?? archiveDays.count
            archiveDays.insert(day, at: i)
        }
        revision &+= 1
        scheduleRebuild()
    }

    /// Same, for a split journal.
    private func patchSplitCache(name: String, entries: [Entry]) {
        if entries.isEmpty {
            splitEntriesCache[name] = nil
            splitJournals.removeAll { $0.name == name }
        } else {
            splitEntriesCache[name] = entries
            if let i = splitJournals.firstIndex(where: { $0.name == name }) {
                splitJournals[i] = SplitJournal(name: name, count: entries.count)
            } else {
                splitJournals.append(SplitJournal(name: name, count: entries.count))
                splitJournals.sort { $0.name < $1.name }
            }
        }
        revision &+= 1
        scheduleRebuild()
    }

    /// Rebuild the archive/tags/split-journal index off the main thread and
    /// publish the results, so no view body ever does directory-wide file reads.
    private func rebuildIndex() {
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
            var built = Self.buildIndex(base: base, triggerDownloads: triggerDownloads)
            built.heavy.wordsToday += inboxWordsToday
            built.heavy.hasEntryToday = built.heavy.hasEntryToday || hasDraftToday
            let idx = built
            let heavy = idx.heavy
            let fp = Self.contentFingerprint(base: base)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastFingerprint = fp
                self.archiveDays = idx.days
                var map = Dictionary(uniqueKeysWithValues: idx.tags.map { ($0.tag, $0.count) })
                for t in inboxTags { map[t, default: 0] += 1 }
                self.tagCounts = map.map { (tag: $0.key, count: $0.value) }
                    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
                self.splitJournals = idx.splits
                self.archiveEntries = idx.corpus
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
    private var lastSnapshotSent: NookSnapshot?

    /// Write a NookSnapshot to the shared App Group so the widget can
    /// display up-to-date stats without accessing the journal directly.
    /// Skipped entirely when no number the widget shows has moved.
    private func writeWidgetSnapshot() {
        #if os(iOS) || os(macOS)
        let heavy = lastHeavyStats
        let accentRaw = UserDefaults.standard.string(forKey: "accentColor") ?? "blue"
        var snap = NookSnapshot()
        snap.currentStreak = heavy.currentStreak
        snap.bestStreak    = heavy.bestStreak
        snap.totalDays     = heavy.days
        snap.totalEntries  = heavy.entries
        snap.totalWords    = heavy.words
        snap.inboxDrafts   = inboxDrafts.count
        snap.accentRaw     = accentRaw
        snap.wordsToday    = heavy.wordsToday
        let goalEnabled = UserDefaults.standard.bool(forKey: "wordGoalEnabled")
        let goal = UserDefaults.standard.integer(forKey: "wordGoal")
        snap.wordGoal = goalEnabled ? max(goal, 1) : 0
        if heavy.onThisDayCount > 0 {
            snap.onThisDayPreview  = heavy.onThisDayPreview
            snap.onThisDayYearsAgo = heavy.onThisDayYearsAgo
            snap.onThisDayDate     = heavy.onThisDayDate
            snap.onThisDayTS       = heavy.onThisDayTS
        }
        if let last = lastSnapshotSent,
           last.currentStreak == snap.currentStreak, last.bestStreak == snap.bestStreak,
           last.totalDays == snap.totalDays, last.totalEntries == snap.totalEntries,
           last.totalWords == snap.totalWords, last.inboxDrafts == snap.inboxDrafts,
           last.accentRaw == snap.accentRaw, last.wordsToday == snap.wordsToday,
           last.wordGoal == snap.wordGoal, last.onThisDayPreview == snap.onThisDayPreview {
            return
        }
        snap.updatedAt = Date()
        lastSnapshotSent = snap
        snap.save()
        // Tell WidgetKit to reload its timelines.
        WidgetCenter.shared.reloadAllTimelines()
        #endif
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

    nonisolated private static let reservedFiles: Set<String> = ["inbox.md", "transfer.md", "export.md", "nook-export.md"]

    nonisolated static func buildIndex(base: URL, triggerDownloads: Bool = true) -> BuiltIndex {
        let fm = FileManager.default
        var idx = BuiltIndex()

        let ymd = DateFormatter()
        ymd.dateFormat = "yyyy-MM-dd"
        ymd.locale = Locale(identifier: "en_US_POSIX")
        let todayISO = ymd.string(from: Date())
        let monthDay = String(todayISO.suffix(5))
        let currentYear = Int(todayISO.prefix(4)) ?? 0
        var latestOnThisDayYear = 0
        var statDates: [Date] = []

        // Date journals under journal/.
        var urls: [URL] = []
        let journalDir = base.appendingPathComponent("journal", isDirectory: true)
        if let en = fm.enumerator(at: journalDir, includingPropertiesForKeys: nil) {
            for case let u as URL in en {
                if u.pathExtension == "md" { urls.append(u); if triggerDownloads { ensureDownloaded(u) } }
                // A not-yet-downloaded iCloud file shows up as a
                // `.<name>.md.icloud` placeholder — invisible to the "md"
                // filter, so a fresh device silently lost those days. Ask for
                // the download; the next reload reads the real file.
                else if u.pathExtension == "icloud" { try? fm.startDownloadingUbiquitousItem(at: u) }
            }
        }
        urls.sort { staticFileToDate($0) > staticFileToDate($1) }
        var tagMap: [String: Int] = [:]
        for u in urls {
            let content = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            let entries = JournalParser.parseEntries(content)
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
                idx.heavy.wordsToday += entries.reduce(0) { $0 + $1.wordCount }
            } else if day.date.hasSuffix(monthDay), let y = Int(day.date.prefix(4)), y < currentYear {
                // Same calendar day, an earlier year — the "On this day" pool.
                idx.heavy.onThisDayCount += entries.count
                if y > latestOnThisDayYear, let first = entries.first {
                    latestOnThisDayYear = y
                    idx.heavy.onThisDayPreview = first.preview
                    idx.heavy.onThisDayYearsAgo = currentYear - y
                    idx.heavy.onThisDayDate = day.date
                    idx.heavy.onThisDayTS = first.ts
                }
            }
            if let d = ymd.date(from: day.date) { statDates.append(d) }
        }
        finishHeavyStats(&idx.heavy, base: base, dates: statDates)

        // Split-tag journals (top-level <base>/<name>.md).
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for u in items where u.pathExtension == "icloud" {
                try? fm.startDownloadingUbiquitousItem(at: u)
            }
            for u in items where u.pathExtension == "md" && !reservedFiles.contains(u.lastPathComponent) {
                let entries = JournalParser.parseEntries((try? String(contentsOf: u, encoding: .utf8)) ?? "")
                if !entries.isEmpty {
                    let name = u.deletingPathExtension().lastPathComponent
                    idx.splits.append(SplitJournal(name: name, count: entries.count))
                    idx.splitEntries[name] = entries
                }
            }
            idx.splits.sort { $0.name < $1.name }
        }

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

    /// All journal day-file URLs (recursive walk of journal/).
    private func allJournalFiles() -> [URL] {
        guard let dir = journalDirURL,
              let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in en where url.pathExtension == "md" {
            files.append(url)
        }
        return files
    }

    /// journal/2026/05/10.md → "2026-05-10".
    private func fileToDate(_ url: URL) -> String {
        let day = url.deletingPathExtension().lastPathComponent
        let month = url.deletingLastPathComponent().lastPathComponent
        let year = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return "\(year)-\(month)-\(day)"
    }

    /// All filed entries grouped by day, newest day first (each day
    /// chronological). An alias for the published cache — no disk walk.
    func allEntriesByDay() -> [(date: String, entries: [Entry])] {
        archiveEntries
    }

    /// Entries filed on a given day, chronological.
    func entries(for date: String) -> [Entry] {
        guard let url = journalFileURL(for: date),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return JournalParser.parseEntries(content)
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

    private func readString(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
        let rules: [(NSRegularExpression, String)] = merges.compactMap { m in
            let oldName = m.from.hasPrefix("@") ? String(m.from.dropFirst()) : m.from
            let newTok = m.to.hasPrefix("@") ? m.to : "@" + m.to
            guard let re = try? NSRegularExpression(
                pattern: "@" + NSRegularExpression.escapedPattern(for: oldName) + "(?![A-Za-z0-9_-])"
            ) else { return nil }
            return (re, NSRegularExpression.escapedTemplate(for: newTok))
        }
        guard !rules.isEmpty else { return }
        func fix(_ url: URL?) {
            // An unreadable file is skipped, never rewritten from "".
            guard let url, var s = readToRewrite(url) else { return }
            let orig = s
            for (re, tpl) in rules {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tpl)
            }
            if s != orig { try? writeFile(url, s) }
        }
        fix(inboxURL)
        for url in allJournalFiles() { fix(url) }
        for sj in splitJournals { fix(splitJournalURL(sj.name)) }
        reload()
    }

    /// Rename all occurrences of one @tag to another across inbox, journal, and
    /// split-journal files. Whole-token match, so @tag doesn't touch @tags.
    @discardableResult
    func renameTag(from old: String, to new: String) -> Int {
        let oldName = old.hasPrefix("@") ? String(old.dropFirst()) : old
        let newTok = new.hasPrefix("@") ? new : "@" + new
        guard let regex = try? NSRegularExpression(
            pattern: "@" + NSRegularExpression.escapedPattern(for: oldName) + "(?![A-Za-z0-9_-])"
        ) else { return 0 }
        let template = NSRegularExpression.escapedTemplate(for: newTok)

        var changed = 0
        func fix(_ url: URL?) {
            guard let url, let s = readToRewrite(url) else { return }
            let r = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
            if r != s { try? writeFile(url, r); changed += 1 }
        }
        fix(inboxURL)
        for url in allJournalFiles() { fix(url) }
        for sj in splitJournals { fix(splitJournalURL(sj.name)) }
        reload()
        return changed
    }

    // MARK: Split journals (JNL_SPLIT_TAGS files: <base>/<tag>.md)

    private func splitJournalURL(_ name: String) -> URL? {
        baseURL?.appendingPathComponent("\(name).md")
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
        guard let url = splitJournalURL(name), let content = readToRewrite(url) else { return false }
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        guard let idx = Self.index(of: original, in: entries) else { return false }
        entries.replaceSubrange(idx...idx, with: JournalParser.parseEntries(newText))
        guard (try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))) != nil else {
            reportWriteFailure(url)
            return false
        }
        if reindex { patchSplitCache(name: name, entries: entries) }
        return true
    }

    @discardableResult
    func deleteJournalEntry(name: String, entry: Entry) -> Bool {
        guard let url = splitJournalURL(name), let content = readToRewrite(url) else { return false }
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        // Single, raw-first removal — removeAll by ts deleted both twins of a
        // same-second pair.
        guard let idx = Self.index(of: entry, in: entries) else { return false }
        entries.remove(at: idx)
        guard (try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))) != nil else {
            reportWriteFailure(url)
            return false
        }
        patchSplitCache(name: name, entries: entries)
        return true
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
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = JournalParser.trimRightNewlines(escapingEmbeddedHeaders(body, skippingFirstLine: false))
        let raw: String
        if !t.isEmpty && !b.isEmpty { raw = "[\(timestamp)] \(t)\n\(b)" }
        else if !t.isEmpty         { raw = "[\(timestamp)] \(t)" }
        else                       { raw = "[\(timestamp)]\n\(b)" }
        return Entry(date: String(timestamp.prefix(10)), ts: timestamp, suffix: t,
                     body: b.trimmingCharacters(in: .whitespacesAndNewlines), raw: raw)
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
        guard let inboxURL else { return nil }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = JournalParser.trimRightNewlines(body).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty && b.isEmpty {
            if let previous { removeDraft(timestamp: previous) }
            return nil
        }
        guard let content = readToRewrite(inboxURL) else { return previous }
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        var ts = timestamp
        if previous == timestamp, let idx = drafts.firstIndex(where: { $0.ts == timestamp }) {
            drafts[idx] = Self.makeEntry(timestamp: ts, title: title, body: body)
        } else {
            if let previous, let idx = drafts.firstIndex(where: { $0.ts == previous }) {
                drafts.remove(at: idx)
            }
            var attempts = 0
            while attempts < 3600, drafts.contains(where: { $0.ts == ts }) {
                ts = Self.timestamp(after: ts)
                attempts += 1
            }
            drafts.append(Self.makeEntry(timestamp: ts, title: title, body: body))
        }
        guard (try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))) != nil else {
            reportWriteFailure(inboxURL)
            return previous
        }
        if reindex { loadInbox(); revision &+= 1; scheduleRebuild() }
        return ts
    }

    /// The jnl timestamp one second after `ts` (the input itself on parse failure —
    /// callers bound their retry loops, so this can never spin).
    private static func timestamp(after ts: String) -> String {
        guard let d = tsFormatter.date(from: ts) else { return ts }
        return tsFormatter.string(from: d.addingTimeInterval(1))
    }

    func removeDraft(timestamp: String) {
        guard let inboxURL, let content = readToRewrite(inboxURL) else { return }
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        // One draft only — with two entries sharing a second, removeAll(ts:)
        // deleted both.
        guard let idx = drafts.firstIndex(where: { $0.ts == timestamp }) else { return }
        drafts.remove(at: idx)
        guard (try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))) != nil else {
            reportWriteFailure(inboxURL)
            return
        }
        loadInbox()
        revision &+= 1
        scheduleRebuild()
    }

    /// Remove every inbox draft whose text matches one of `entries` (one draft
    /// per match). The composer's Import uses it to clear everything the working
    /// text already put in the inbox before splitting it up — an inbox left
    /// polluted by an earlier build's autosave would otherwise be imported on
    /// top of. Returns how many were removed.
    @discardableResult
    func removeDrafts(matching entries: [Entry]) -> Int {
        guard !entries.isEmpty, let inboxURL, let content = readToRewrite(inboxURL) else { return 0 }
        var wanted: [String: Int] = [:]
        for e in entries { wanted[JournalParser.trimRightNewlines(e.raw), default: 0] += 1 }
        var kept: [Entry] = []
        var removed = 0
        for d in JournalParser.parseEntries(content) {
            let key = JournalParser.trimRightNewlines(d.raw)
            if let n = wanted[key], n > 0 { wanted[key] = n - 1; removed += 1 }
            else { kept.append(d) }
        }
        guard removed > 0 else { return 0 }
        let preamble = JournalParser.leadingPreamble(content)
        guard (try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: kept))) != nil else {
            reportWriteFailure(inboxURL)
            return 0
        }
        loadInbox()
        revision &+= 1
        scheduleRebuild()
        return removed
    }

    /// Import pasted text as separate inbox drafts (jnl `transfer` parsing): if it
    /// contains `[timestamp]` headers each becomes its own draft; otherwise each
    /// blank-line-separated paragraph becomes a draft stamped with the current time.
    /// Returns how many drafts were added.
    @discardableResult
    func importDrafts(from text: String) -> Int {
        guard let inboxURL else { return 0 }
        let imported = parseImport(text)
        guard !imported.isEmpty, let content = readToRewrite(inboxURL) else { return 0 }
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        drafts.append(contentsOf: imported)
        guard (try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))) != nil else {
            reportWriteFailure(inboxURL)
            return 0
        }
        loadInbox()
        revision &+= 1
        scheduleRebuild()
        return imported.count
    }

    // MARK: Media assets (Obsidian-style: <base>/assets/<file>, markdown links)

    private var assetsDirURL: URL? { baseURL?.appendingPathComponent("assets", isDirectory: true) }

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
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys
        ) else { return [] }
        return items
            .filter { !$0.hasDirectoryPath }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return AssetItem(url: url,
                                 modified: values?.contentModificationDate ?? .distantPast,
                                 entryDate: entryDates[url.lastPathComponent],
                                 size: values?.fileSize ?? 0)
            }
            .sorted { $0.name < $1.name }
    }

    /// asset file name → timestamp of the earliest entry that links it, built in
    /// one pass over the inbox, the day files and the split journals. One scan
    /// for the whole gallery: `usages(ofAsset:)` per file would re-read the
    /// entire journal once per thumbnail.
    nonisolated static func assetEntryDates(base: URL) -> [String: Date] {
        let fm = FileManager.default
        var files: [URL] = [base.appendingPathComponent("inbox.md")]
        let journalDir = base.appendingPathComponent("journal", isDirectory: true)
        if let en = fm.enumerator(at: journalDir, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.pathExtension == "md" { files.append(u) }
        }
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for u in items where u.pathExtension == "md" && !reservedFiles.contains(u.lastPathComponent) {
                files.append(u)
            }
        }

        // A local formatter: `tsFormatter` is main-actor isolated and this runs
        // off the main thread.
        let stamps = DateFormatter()
        stamps.dateFormat = "yyyy-MM-dd HH:mm:ss"
        stamps.locale = Locale(identifier: "en_US_POSIX")

        var map: [String: Date] = [:]
        for url in files {
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  content.contains("assets/") else { continue }
            for entry in JournalParser.parseEntries(content) {
                let paths = MediaLinks.paths(in: entry.raw)
                guard !paths.isEmpty, let date = stamps.date(from: entry.ts) else { continue }
                for path in paths {
                    let name = (path as NSString).lastPathComponent
                    if let existing = map[name], existing <= date { continue }
                    map[name] = date
                }
            }
        }
        return map
    }

    func deleteAsset(_ url: URL) { try? fm.removeItem(at: url) }

    nonisolated private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp",
    ]

    /// Asset files that no entry references any more (safe to delete).
    func orphanAssets() -> [URL] {
        let all = allAssets().map(\.url)
        guard !all.isEmpty else { return [] }
        var texts: [String] = []
        if let inboxURL { texts.append(readString(inboxURL)) }
        for url in allJournalFiles() { texts.append(readString(url)) }
        for sj in splitJournals { if let u = splitJournalURL(sj.name) { texts.append(readString(u)) } }
        let corpus = texts.joined(separator: "\n")
        return all.filter { !corpus.contains("assets/\($0.lastPathComponent)") }
    }

    @discardableResult
    func deleteOrphanAssets() -> Int {
        let orphans = orphanAssets()
        for url in orphans { deleteAsset(url) }
        if !orphans.isEmpty { scheduleRebuild() }
        return orphans.count
    }

    /// Entries that reference an asset by file name (for "go to file").
    func usages(ofAsset fileName: String) -> [(entry: Entry, source: EntrySource)] {
        let needle = "assets/\(fileName)"
        var result: [(Entry, EntrySource)] = []
        for e in inboxDrafts where e.raw.contains(needle) { result.append((e, .inbox)) }
        for day in archiveEntries {
            for e in day.entries where e.raw.contains(needle) {
                result.append((e, .archive(date: day.date)))
            }
        }
        for (name, entries) in splitEntriesCache {
            for e in entries where e.raw.contains(needle) {
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
        case .journal(let n):   url = splitJournalURL(n)
        }
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    #endif

    /// Copy an existing file (e.g. a recorded video) into assets/ and return the
    /// relative path. Better than loading large media into memory.
    func importAsset(from url: URL) -> String? {
        guard let dir = assetsDirURL else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            try fm.copyItem(at: url, to: dest)
            let rel = "assets/\(dest.lastPathComponent)"
            scheduleCompression(assetRelPath: rel)   // video/audio, in the background
            return rel
        } catch { return nil }
    }

    /// Save image data into the journal's assets folder and return the relative
    /// markdown-friendly path ("assets/<uuid>.<ext>"), or nil on failure. When
    /// Data Saver is on, raster images are downsampled/re-compressed first (format
    /// and extension preserved, so the markdown link stays valid).
    func saveAsset(_ data: Data, ext: String) -> String? {
        guard let dir = assetsDirURL else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let lower = ext.lowercased()
        let name = "\(id).\(lower)"
        var out = data
        if UserDefaults.standard.bool(forKey: "dataSaver"),
           ImageDownsampler.compressible.contains(lower),
           let shrunk = ImageDownsampler.downsample(data), shrunk.count < data.count {
            out = shrunk
        }
        do {
            try out.write(to: dir.appendingPathComponent(name), options: .atomic)
            if out.count < data.count { recordCompression(assetID: id, saved: data.count - out.count) }
            let rel = "assets/\(name)"
            // Images are handled synchronously above; video/audio compress in the background.
            if !ImageDownsampler.compressible.contains(lower) { scheduleCompression(assetRelPath: rel) }
            return rel
        } catch {
            return nil
        }
    }

    // MARK: Data Saver (image compression + merged, per-device savings tally)

    /// One device's compression record. Each device writes ONLY its own file, so
    /// syncing several devices' files into `<base>/.nook/` never conflicts; the
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
    private var dataSaverDirURL: URL? { baseURL?.appendingPathComponent(".nook", isDirectory: true) }
    private var myDataSaverFileURL: URL? {
        dataSaverDirURL?.appendingPathComponent("datasaver-\(dataSaverDeviceID).json")
    }

    private func loadMyRecord() -> DataSaverRecord {
        guard let url = myDataSaverFileURL, let data = try? Data(contentsOf: url),
              let rec = try? JSONDecoder().decode(DataSaverRecord.self, from: data) else { return DataSaverRecord() }
        return rec
    }
    private func saveMyRecord(_ rec: DataSaverRecord) {
        guard let dir = dataSaverDirURL, let url = myDataSaverFileURL else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(rec) { try? data.write(to: url, options: .atomic) }
    }

    /// Every device record file in `<base>/.nook/`.
    private func allDataSaverRecords() -> [DataSaverRecord] {
        guard let dir = dataSaverDirURL,
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.lastPathComponent.hasPrefix("datasaver-") && $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(DataSaverRecord.self, from: $0) }
    }

    /// Bytes saved across ALL devices (merged sum — the number shown in Settings).
    func totalDataSaved() -> Int { allDataSaverRecords().reduce(0) { $0 + $1.savedBytes } }

    /// Asset uuids already compressed on ANY device, so batch runs never repeat one.
    private func allCompressedAssetIDs() -> Set<String> {
        Set(allDataSaverRecords().flatMap(\.assets))
    }

    private func recordCompression(assetID: String, saved: Int) {
        var rec = loadMyRecord()
        rec.savedBytes += max(0, saved)
        if !rec.assets.contains(assetID) { rec.assets.append(assetID) }
        saveMyRecord(rec)
        dataSaved = totalDataSaved()
    }

    /// Mark an asset as handled (no bytes gained) so batch runs skip it next time.
    private func markHandled(assetID: String) {
        var rec = loadMyRecord()
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
            let bgTask = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "nook.compress") }
            defer { if bgTask != .invalid { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTask) } } }
            #endif
            let saved = await MediaTranscodeQueue.shared.run { await MediaTranscoder.compressInPlace(url: url, ext: ext) }
            await MainActor.run {
                if let saved, saved > 0 { self.recordCompression(assetID: id, saved: saved) }
                else { self.markHandled(assetID: id) }
            }
        }
    }

    struct MediaCompressionResult { var images = 0; var videos = 0; var audios = 0; var bytesSaved = 0 }

    /// Compress existing media (images, video, audio) that no device has processed
    /// yet, in place (same filename/format, so markdown links are untouched). Images
    /// re-encode synchronously; video/audio transcode via the serial queue. Skips
    /// anything already handled elsewhere so nothing is compressed — or counted —
    /// twice. Async because video/audio export is long-running.
    @discardableResult
    func compressExistingMedia() async -> MediaCompressionResult {
        guard let dir = assetsDirURL,
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return MediaCompressionResult() }
        let already = allCompressedAssetIDs()
        let candidates = items.filter { url in
            guard !url.hasDirectoryPath else { return false }
            let ext = url.pathExtension.lowercased()
            let known = ImageDownsampler.compressible.contains(ext)
                || MediaTranscoder.video.contains(ext) || MediaTranscoder.audio.contains(ext)
            return known && !already.contains(url.deletingPathExtension().lastPathComponent)
        }
        var res = MediaCompressionResult()
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
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(t.isEmpty && b.isEmpty) else { return false }

        let resolved = resolveBase(bookmark: UserDefaults.standard.data(forKey: bookmarkKey),
                                   containerID: nil)
        // Never write around an unreachable custom folder: the draft would go
        // into a journal the user isn't looking at and can't get back.
        guard let base = resolved.url else { throw JournalError.journalUnavailable }
        let started = resolved.scoped && base.startAccessingSecurityScopedResource()
        defer { if started { base.stopAccessingSecurityScopedResource() } }

        let inbox = base.appendingPathComponent("inbox.md")
        let entry = makeEntry(timestamp: nowTS(), title: t, body: b)
        var out = JournalParser.trimRightNewlines(entry.raw) + "\n"
        // Throws rather than appending to "" — an unreadable inbox must not be
        // replaced by this one draft.
        let existing = try readForRewrite(inbox)
        if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out = JournalParser.trimRightNewlines(existing) + "\n\n" + out
        }
        try atomicWrite(inbox, out)
        return true
    }

    /// Number of drafts currently in the inbox (headless — for App Intents).
    static func inboxDraftCount() -> Int {
        let resolved = resolveBase(bookmark: UserDefaults.standard.data(forKey: bookmarkKey),
                                   containerID: nil)
        // An unreachable folder has no answer — better none than the fallback's.
        guard let base = resolved.url else { return 0 }
        let started = resolved.scoped && base.startAccessingSecurityScopedResource()
        defer { if started { base.stopAccessingSecurityScopedResource() } }
        let inbox = base.appendingPathComponent("inbox.md")
        let content = (try? String(contentsOf: inbox, encoding: .utf8)) ?? ""
        return JournalParser.parseEntries(content).count
    }

    /// Atomic write usable off the main actor (temp-file + rename).
    nonisolated static func atomicWrite(_ url: URL, _ content: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".nook-\(UUID().uuidString).tmp")
        try Data(content.utf8).write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    /// Remove leftover `.nook-*.tmp` files from writes that never completed.
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
        where url.lastPathComponent.hasPrefix(".nook-") && url.pathExtension == "tmp" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    private func parseImport(_ text: String) -> [Entry] {
        let parsed = JournalParser.parseEntries(text)
        if !parsed.isEmpty { return parsed }
        // No [timestamp] headers → there's nothing to split; treat the whole
        // thing (paragraphs and all) as a single draft.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [Self.makeEntry(timestamp: Self.nowTS(), title: "", body: trimmed)]
    }

    // MARK: Review actions (jnl cmdReview)

    /// File a draft into its day's journal file (or a split-tag file), then
    /// remove it from the inbox. Returns the label it was filed under.
    @discardableResult
    func fileDraft(_ entry: Entry) -> String? {
        guard let label = try? fileEntry(entry) else { return nil }
        removeFromInbox(entry)
        loadInbox()
        patchDestination(label: label)
        return label
    }

    /// After filing, refresh just the one file it landed in — the label is a
    /// date ("2026-08-20") or a split tag ("@work").
    private func patchDestination(label: String) {
        if label.hasPrefix("@") {
            let name = String(label.dropFirst())
            if let url = splitJournalURL(name) {
                patchSplitCache(name: name, entries: JournalParser.parseEntries(readString(url)))
            }
        } else if let url = journalFileURL(for: label) {
            patchArchiveCache(date: label, entries: JournalParser.parseEntries(readString(url)))
        } else {
            revision &+= 1
            scheduleRebuild()
        }
    }

    func deleteDraft(_ entry: Entry) {
        removeFromInbox(entry)
        loadInbox()
        revision &+= 1
        scheduleRebuild()
    }

    /// Replace a draft's text (from the editor) and persist the inbox. Returns
    /// false when the draft couldn't be found or the write failed.
    @discardableResult
    func updateDraft(_ entry: Entry, newText: String, reindex: Bool = true) -> Bool {
        guard let inboxURL, let content = readToRewrite(inboxURL) else { return false }
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        guard let idx = Self.index(of: entry, in: drafts) else { return false }
        // One draft in, one draft out: text carrying its own headers is escaped
        // rather than split, so an autosave can't multiply a pasted entry.
        let parsed = JournalParser.parseEntries(Self.escapingEmbeddedHeaders(newText, skippingFirstLine: true))
        drafts.replaceSubrange(idx...idx, with: parsed)
        guard (try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))) != nil else {
            reportWriteFailure(inboxURL)
            return false
        }
        if reindex { loadInbox(); revision &+= 1; scheduleRebuild() }
        return true
    }

    /// Sort the inbox into date order in place (jnl cmdSort).
    func sortInbox() {
        guard let inboxURL, let content = readToRewrite(inboxURL) else { return }
        let preamble = JournalParser.leadingPreamble(content)
        let entries = JournalParser.parseEntries(content)
        guard entries.count >= 2 else { return }
        let sorted = JournalParser.sortedByTimestamp(entries)
        guard (try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: sorted))) != nil else {
            reportWriteFailure(inboxURL)
            return
        }
        loadInbox()
        revision &+= 1
        scheduleRebuild()
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
        guard let url = journalFileURL(for: date), let content = readToRewrite(url) else { return nil }
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        guard let idx = Self.index(of: original, in: entries) else { return nil }
        let parsed = JournalParser.parseEntries(Self.escapingEmbeddedHeaders(newText, skippingFirstLine: true))

        // Moved to another day: take it out of this file, then file it into the
        // new one (no split routing — an archive edit stays in the archive).
        if parsed.count == 1, let moved = parsed.first, !moved.date.isEmpty, moved.date != date {
            // Write the new day first: if the second write then fails, the entry
            // exists twice (visible, fixable) instead of nowhere. An entry with
            // nothing in it throws here and never leaves its file.
            guard let label = try? fileEntry(moved, routeSplit: false) else {
                reportWriteFailure(url)
                return nil
            }
            entries.remove(at: idx)
            if (try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))) != nil {
                patchArchiveCache(date: date, entries: entries)
            } else {
                reportWriteFailure(url)
            }
            patchDestination(label: label)
            return .archive(date: moved.date)
        }

        entries.replaceSubrange(idx...idx, with: parsed)
        guard (try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))) != nil else {
            reportWriteFailure(url)
            return nil
        }
        if reindex { patchArchiveCache(date: date, entries: entries) }
        return .archive(date: date)
    }

    /// Delete a filed entry from its day file (removes the file if now empty).
    @discardableResult
    func deleteFiledEntry(date: String, entry: Entry) -> Bool {
        guard let url = journalFileURL(for: date), let content = readToRewrite(url) else { return false }
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        // Single, raw-first removal — removeAll by ts deleted both twins of a
        // same-second pair.
        guard let idx = Self.index(of: entry, in: entries) else { return false }
        entries.remove(at: idx)
        guard (try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))) != nil else {
            reportWriteFailure(url)
            return false
        }
        patchArchiveCache(date: date, entries: entries)
        return true
    }

    // MARK: Filing internals (jnl fileDraft / splitTagTarget)

    /// Where an entry files to (split-tag file or day file) and the label the
    /// UI reports for it.
    private func destination(for e: Entry, routeSplit: Bool = true) -> (url: URL, label: String)? {
        if routeSplit, let (tag, url) = splitTagTarget(e.raw) { return (url, tag) }
        let date = e.date.isEmpty ? Self.nowDate() : e.date
        guard let url = journalFileURL(for: date) else { return nil }
        return (url, date)
    }

    /// Append several entries to one file in a single read + write.
    private func appendEntries(_ entries: [Entry], to dest: URL) -> Bool {
        guard !entries.isEmpty else { return false }
        // An unreadable destination aborts the append — appending to "" would
        // replace the day's entries with just these.
        guard let existing = readToRewrite(dest) else { return false }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        var out = ""
        if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out = JournalParser.trimRightNewlines(existing) + "\n"
        }
        for e in entries {
            if !out.isEmpty { out += "\n" }
            if !e.suffix.isEmpty && !e.body.isEmpty {
                out += "[\(e.ts)] \(e.suffix)\n\(e.body)\n"
            } else if !e.suffix.isEmpty {
                out += "[\(e.ts)] \(e.suffix)\n"
            } else {
                out += "[\(e.ts)]\n\(e.body)\n"
            }
        }
        return (try? writeFile(dest, out)) != nil
    }

    /// Append one entry to its destination file. Throws on empty entry / IO error.
    /// `routeSplit: false` forces the dated journal, ignoring split-tag routing
    /// (used when merging ex-split journals back in).
    private func fileEntry(_ e: Entry, routeSplit: Bool = true) throws -> String {
        if e.body.isEmpty && e.suffix.isEmpty {
            throw JournalError.nothingToFile
        }
        guard let (dest, label) = destination(for: e, routeSplit: routeSplit) else {
            throw JournalError.badPath
        }
        // Throws rather than appending to "": an unreadable day file must not be
        // replaced by the single entry being filed into it.
        let existing = try Self.readForRewrite(dest)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        var out = ""
        if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out = existing
            if !out.hasSuffix("\n\n") {
                out += out.hasSuffix("\n") ? "\n" : "\n\n"
            }
        }
        if !e.suffix.isEmpty && !e.body.isEmpty {
            out += "[\(e.ts)] \(e.suffix)\n\(e.body)\n"
        } else if !e.suffix.isEmpty {
            out += "[\(e.ts)] \(e.suffix)\n"
        } else {
            out += "[\(e.ts)]\n\(e.body)\n"
        }
        try writeFile(dest, out)
        return label
    }

    /// If the entry's text contains a configured split tag, return (tag, file).
    private func splitTagTarget(_ raw: String) -> (tag: String, url: URL)? {
        guard let base = baseURL, !splitTags.isEmpty else { return nil }
        let present = Set(JournalParser.splitTags(raw))
        for t in splitTags {
            let tag = t.hasPrefix("@") ? t : "@" + t
            if present.contains(tag) {
                let name = String(tag.dropFirst())
                return (tag, base.appendingPathComponent("\(name).md"))
            }
        }
        return nil
    }

    private func removeFromInbox(_ entry: Entry) {
        guard let inboxURL, let content = readToRewrite(inboxURL) else { return }
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        // Raw text first, timestamp second: raw is the sharper identity when
        // two entries share a second, so the removal can't land on the wrong twin.
        if let idx = Self.index(of: entry, in: drafts) {
            drafts.remove(at: idx)
        }
        if (try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))) == nil {
            reportWriteFailure(inboxURL)
        }
    }

    // MARK: Bulk filing (jnl transfer)

    /// File every inbox draft into the archive. Returns how many were filed.
    /// Only drafts that actually filed are removed: one whose write failed
    /// stays in the inbox instead of being lost with it, and a draft another
    /// process added since our last load (Siri, jnl, a second device) is never
    /// touched.
    @discardableResult
    func fileAllDrafts() -> Int {
        var filedRaws: [String: Int] = [:]   // raw text → copies filed
        var filed = 0
        // Group by destination first, so ten drafts from one day rewrite that
        // day's file once, not ten times.
        var order: [URL] = []
        var byDest: [URL: [Entry]] = [:]
        for draft in inboxDrafts {
            guard !(draft.body.isEmpty && draft.suffix.isEmpty),
                  let dest = destination(for: draft)?.url else { continue }
            if byDest[dest] == nil { order.append(dest) }
            byDest[dest, default: []].append(draft)
        }
        for dest in order {
            let group = byDest[dest] ?? []
            guard appendEntries(group, to: dest) else { continue }
            filed += group.count
            for draft in group { filedRaws[draft.raw, default: 0] += 1 }
        }
        if filed > 0, let inboxURL, let content = readToRewrite(inboxURL) {
            let preamble = JournalParser.leadingPreamble(content)
            var remaining: [Entry] = []
            for e in JournalParser.parseEntries(content) {
                if let n = filedRaws[e.raw], n > 0 {
                    filedRaws[e.raw] = n - 1     // counted, so an exact duplicate
                } else {                          // only vanishes once per filing
                    remaining.append(e)
                }
            }
            if (try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: remaining))) == nil {
                reportWriteFailure(inboxURL)
            }
        }
        reload()
        return filed
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
        let files = allJournalFiles().sorted { fileToDate($0) < fileToDate($1) }
        var parts = files.map { JournalParser.trimRightNewlines(readString($0)) }
            .filter { !$0.isEmpty }
        for sj in splitJournals.sorted(by: { $0.name < $1.name }) {
            guard let url = splitJournalURL(sj.name) else { continue }
            let text = JournalParser.trimRightNewlines(readString(url))
            if !text.isEmpty { parts.append(text) }
        }
        return parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n"
    }

    // MARK: Cleanup (jnl cmdCleanup)

    struct CleanupResult { var formatted = 0; var reordered = 0; var deduped = 0; var extracted = 0 }

    /// Remove exact-duplicate entries (identical raw text), keeping the first.
    private func dedupe(_ entries: [Entry]) -> [Entry] {
        var seen = Set<String>(), out: [Entry] = []
        for e in entries where seen.insert(e.raw).inserted { out.append(e) }
        return out
    }

    /// Standardise punctuation (… and straight quotes), retroactively route entries
    /// matching a configured split tag into their <tag>.md file, reorder each day
    /// by timestamp, and drop exact-duplicate entries. Returns what changed.
    @discardableResult
    func cleanup() -> CleanupResult {
        var res = CleanupResult()
        for url in allJournalFiles() {
            // Skip anything unreadable: rebuilding it from "" would delete it.
            guard let orig = readToRewrite(url) else { continue }
            let fixed = JournalParser.normalizePunctuation(orig)
            if fixed != orig { res.formatted += 1 }

            let preamble = JournalParser.leadingPreamble(fixed)
            let entries = JournalParser.parseEntries(fixed)

            // Retroactive split-tag extraction (jnl cmdCleanup): move any entry
            // now matching a configured split tag out into its <tag>.md file.
            var kept: [Entry] = []
            for e in entries {
                if splitTagTarget(e.raw) != nil, (try? fileEntry(e)) != nil {
                    res.extracted += 1
                } else {
                    kept.append(e)
                }
            }

            let sorted = JournalParser.sortedByTimestamp(kept)
            if kept.map(\.ts) != sorted.map(\.ts) { res.reordered += 1 }
            let deduped = dedupe(sorted)
            res.deduped += (sorted.count - deduped.count)
            let rebuilt = JournalParser.renderEntries(preamble: preamble, entries: deduped)
            if rebuilt != orig { try? writeFile(url, rebuilt) }
        }
        // Inbox: reorder by timestamp and drop exact duplicates too.
        if let inboxURL, let content = readToRewrite(inboxURL) {
            let preamble = JournalParser.leadingPreamble(content)
            let entries = JournalParser.parseEntries(content)
            let sorted = JournalParser.sortedByTimestamp(entries)
            if entries.map(\.ts) != sorted.map(\.ts) { res.reordered += 1 }
            let deduped = dedupe(sorted)
            res.deduped += (sorted.count - deduped.count)
            let rebuilt = JournalParser.renderEntries(preamble: preamble, entries: deduped)
            if rebuilt != content {
                try? writeFile(inboxURL, rebuilt)
            }
        }
        reload()
        return res
    }

    struct MergeResult { var journals = 0; var entries = 0 }

    /// Merge "ex-split" journals — top-level `<tag>.md` files whose tag is no
    /// longer in the configured split tags — back into the dated main journal,
    /// filing each entry by its timestamp and removing the emptied split file.
    /// Entries that fail to move are left behind so the file isn't lost.
    @discardableResult
    func mergeExSplitJournals() -> MergeResult {
        var res = MergeResult()
        let configured = Set(splitTags.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 })
        for sj in splitJournals where !configured.contains(sj.name) {
            guard let url = splitJournalURL(sj.name), let content = readToRewrite(url) else { continue }
            let entries = JournalParser.parseEntries(content)
            guard !entries.isEmpty else { continue }
            var remaining: [Entry] = []
            for e in entries {
                if (try? fileEntry(e, routeSplit: false)) != nil { res.entries += 1 }
                else { remaining.append(e) }
            }
            if remaining.isEmpty {
                try? fm.removeItem(at: url)
                res.journals += 1
            } else {
                let preamble = JournalParser.leadingPreamble(content)
                try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: remaining))
                if res.entries > 0 { res.journals += 1 }
            }
        }
        reload()
        return res
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
        /// "On this day" — entries from this calendar day in past years.
        var onThisDayCount = 0
        var onThisDayPreview = ""
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
            where url.pathExtension == "md" && !nonJournalFiles.contains(url.lastPathComponent) {
                s.journalBytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        s.inboxBytes = (try? base.appendingPathComponent("inbox.md")
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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
    nonisolated private static let nonJournalFiles: Set<String> = ["transfer.md", "export.md", "nook-export.md"]

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
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `readForRewrite` with the failure surfaced: nil means "don't write",
    /// never "the file was empty".
    private func readToRewrite(_ url: URL) -> String? {
        do { return try Self.readForRewrite(url) }
        catch {
            lastWriteError = "Couldn't read \(url.lastPathComponent) — it was left untouched."
            return nil
        }
    }

    /// Note a write that didn't happen, so the caller can skip its cache patch
    /// rather than showing an edit that isn't on disk.
    private func reportWriteFailure(_ url: URL) {
        lastWriteError = "Couldn't save \(url.lastPathComponent) — your last change wasn't written."
    }

    /// Locate an entry inside a file's parsed entries for a rewrite. Exact raw
    /// text first; the timestamp only when that second is unambiguous — with
    /// two entries sharing a second the old fallback silently landed on the
    /// first twin, so editing the second overwrote the first.
    nonisolated static func index(of entry: Entry, in entries: [Entry]) -> Int? {
        // Trimmed raw: the last entry in a file parses back carrying the file's
        // own trailing newline, so a bare == misses it. The candidates are
        // compared in place rather than each trimmed into a copy — a mismatch
        // rejects at the header, and only the true match walks its tail.
        let want = JournalParser.trimRightNewlines(entry.raw)
        if let i = entries.firstIndex(where: { rawMatches($0.raw, want) }) { return i }
        let sameTS = entries.indices.filter { entries[$0].ts == entry.ts }
        return sameTS.count == 1 ? sameTS[0] : nil
    }

    /// `raw == want` apart from trailing newlines — what `trimRightNewlines`
    /// would strip — without allocating the trimmed string.
    private nonisolated static func rawMatches(_ raw: String, _ want: String) -> Bool {
        guard raw.hasPrefix(want) else { return false }
        return raw.utf8.dropFirst(want.utf8.count).allSatisfy { $0 == UInt8(ascii: "\n") }
    }

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
    /// user's only copy of their notes. An empty string removes the file.
    private func writeFile(_ url: URL, _ content: String) throws {
        lastLocalWriteAt = Date()   // so the sync watcher ignores our own echo
        defer { journalDidChange() }
        if content.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".nook-\(UUID().uuidString).tmp")
        try content.data(using: .utf8)!.write(to: tmp, options: .atomic)
        // replaceItemAt is a true atomic swap; the old remove-then-move left a
        // window where a crash meant the journal file existed only as a hidden
        // temp file.
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    // MARK: Shared-in drafts (share extension handoff)

    /// Where the share extension leaves what it captured: a `pending.md` of
    /// jnl-format drafts plus an `assets/` folder of media, inside the App
    /// Group container — the extension can't reach a custom journal folder's
    /// security-scoped bookmark, so the app moves everything in from here.
    nonisolated static var pendingShareDir: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NookSnapshot.suiteName)?
            .appendingPathComponent("PendingShare", isDirectory: true)
    }

    /// Move anything the share extension captured into the journal: media into
    /// `<base>/assets/` (the pending drafts already link them by that path),
    /// the drafts onto the end of the inbox. Runs on every reload, so shares
    /// land on the next launch or foreground.
    private func drainPendingShares() {
        guard let dir = Self.pendingShareDir, let inboxURL, baseURL != nil else { return }
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
            guard let existing = readToRewrite(inboxURL) else { return }
            let preamble = JournalParser.leadingPreamble(existing)
            var drafts = JournalParser.parseEntries(existing)
            for e in shared where !drafts.contains(where: { $0.raw == e.raw }) { drafts.append(e) }
            do {
                try writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))
            } catch {
                // Keep the claims so the capture isn't lost — the next reload
                // retries (the media moves above are idempotent, and the
                // dedupe-by-raw guard means a partial success can't double up).
                return
            }
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
        var cache: [String: String] = [:]   // date → file content
        for e in JournalParser.sortedByTimestamp(entries) {
            guard let url = journalFileURL(for: e.date) else { continue }
            let content = cache[e.date] ?? readString(url)
            if content.contains(e.raw) { cache[e.date] = content; continue }
            if (try? fileEntry(e, routeSplit: false)) != nil {
                added += 1
                cache[e.date] = readString(url)
            }
        }
        if added > 0 { reload() }
        return added
    }

    // MARK: Cross-file helpers (for feature extensions in other files)

    /// Stable per-device id, shared with Data Saver's record files — feature
    /// extensions (transcription records) key their `.nook/` files by it too.
    var deviceRecordID: String {
        let key = "dataSaverDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Every journal content file: the inbox, all day files, all split journals.
    func allContentFileURLs() -> [URL] {
        var files: [URL] = []
        if let inboxURL { files.append(inboxURL) }
        files.append(contentsOf: allJournalFiles())
        for sj in splitJournals { if let u = splitJournalURL(sj.name) { files.append(u) } }
        return files
    }

    /// Atomic rewrite of one journal content file (feature extensions can't
    /// reach the private writeFile).
    func rewriteContentFile(_ url: URL, _ content: String) {
        try? writeFile(url, content)
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
            // Looks like our own echo — wait out the rest of the window and
            // look again rather than dropping the update. With continuous
            // autosave this used to discard every remote change (and never run
            // conflict resolution) for as long as a writing session lasted.
            let sinceLocalWrite = Date().timeIntervalSince(self.lastLocalWriteAt)
            if sinceLocalWrite < 2 {
                self.scheduleSyncReload(after: 2 - sinceLocalWrite)
                return
            }
            self.resolveFileConflicts()
            self.reload()
        }
    }

    /// iCloud file-version conflicts merge as "keep both": any entry a
    /// conflicting version has that the current file doesn't is appended, then
    /// the versions are marked resolved. Covers the inbox, every day file, and
    /// the split journals — a two-device day used to resolve silently to
    /// whichever version won. With plain text, keeping both is always safe;
    /// Clean Up removes exact duplicates.
    private func resolveFileConflicts() {
        var urls: [URL] = []
        if let inboxURL { urls.append(inboxURL) }
        urls.append(contentsOf: allJournalFiles())
        for sj in splitJournals { if let u = splitJournalURL(sj.name) { urls.append(u) } }
        for url in urls { resolveConflicts(at: url) }
    }

    private func resolveConflicts(at url: URL) {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !versions.isEmpty else { return }
        let current = readString(url)
        let preamble = JournalParser.leadingPreamble(current)
        var entries = JournalParser.parseEntries(current)
        var changed = false
        for version in versions {
            let other = (try? String(contentsOf: version.url, encoding: .utf8)) ?? ""
            for e in JournalParser.parseEntries(other) where !entries.contains(where: { $0.raw == e.raw }) {
                entries.append(e)
                changed = true
            }
            version.isResolved = true
        }
        if changed {
            try? writeFile(url, JournalParser.renderEntries(preamble: preamble,
                                                            entries: JournalParser.sortedByTimestamp(entries)))
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
                return "Nook can't reach your journal folder. Open Nook to find it again."
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
    /// the only audio Nook records anyway.
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

        let queue = DispatchQueue(label: "nook.audio.transcode")
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
