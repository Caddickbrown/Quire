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
    /// What Today showed when the journal was last read, published at launch so
    /// the page can draw before the journal has been read again. Always for the
    /// current day (a saved one for an earlier day is emptied first), and only
    /// worth reading while `indexed` is false: it is cleared when the index lands.
    @Published private(set) var todaySnapshot: TodaySnapshot?
    /// True while a jnl or Nook journal's single files are being folded into
    /// day files as the folder is opened. The journal is read when it finishes.
    @Published private(set) var foldingLegacy = false
    /// Non-nil while `commitImportAsync` files an import.
    @Published private(set) var importProgress: (done: Int, total: Int)?
    /// Why the last backup failed, scheduled ones included. Nil after a good one.
    @Published private(set) var lastBackupError: String?
    /// Set when the folder was opened with a `.quire-restore-old-…` folder in
    /// it: a restore was interrupted and what it moved aside is still there.
    @Published private(set) var interruptedRestore: String?

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
        let rel = try core.sidecar(write: true) + "/" + name
        try core.write(rel, String(decoding: data, as: UTF8.self))
        noteOwnWrite(rel)
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
        guard let result = coreMutation(patched: true, { try $0.update(original, text: text) }) else { return nil }
        guard var entry = JournalParser.parseEntries(result.raw).first else {
            unpatchedSeq &+= 1
            scheduleRebuild()
            return nil
        }
        entry.file = result.file
        entry.fileIndex = result.index
        let destination: EntrySource
        switch source {
        case .archive: destination = .archive(date: entry.date)
        default: destination = source
        }
        noteOwnWrite(original.file)
        noteOwnWrite(result.file)
        // The lists hold this entry too: give them the write's own reference
        // now, or a star, delete or retime before the rebuild presents the old
        // text and is refused as "changed on disk".
        recordPatch(replacing: original, with: entry, source: source, destination: destination)
        entryTouched(original)
        publishAutosave()
        return (entry, destination)
    }

    /// Always inserts a distinct draft, including for explicit conflict recovery.
    /// Returns nil on failure instead of returning a previous timestamp as success.
    func createEditorDraft(timestamp: String, title: String, body: String) -> Entry? {
        let result: CoreWritten? = coreMutation(patched: true) { core in
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
        noteOwnWrite(result.file)
        // A new draft touches nothing the archive caches hold; the inbox alone
        // is read again (no migration, no walk of the journal).
        loadInbox()
        publishAutosave()
        return entry
    }

    /// `patched` is a promise that the caller puts the write's effect into the
    /// caches itself (`recordPatch`, or a re-read of the inbox for a draft).
    private func coreMutation<T>(patched: Bool = false, _ action: (CoreJournal) throws -> T) -> T? {
        guard let core else { lastWriteError = "The journal folder is unavailable."; return nil }
        do {
            let result = try action(core)
            // Only when there was one: setting a published value, even to nil
            // again, redraws every screen that watches the store, and this runs
            // on every autosave.
            if lastWriteError != nil { lastWriteError = nil }
            lastLocalWriteAt = Date()
            // Unless the caller patches it in, the caches no longer say what
            // the disk does until a rebuild started after this write lands.
            mutationSeq &+= 1
            if !patched { unpatchedSeq &+= 1 }
            journalDidChange()
            return result
        } catch { lastWriteError = journalErrorMessage(error); return nil }
    }
    private func publishCoreChange(reindex: Bool = true) {
        if reindex { loadInbox(); rebuildIndex() }
    }

    /// After an autosave. The words are already on disk and the lists already
    /// hold the write's own entry (`recordPatch`); what waits is the rebuild,
    /// which re-reads every file in the journal and redraws every screen. Run
    /// on each pause in typing, it made the phone lag (Dan, 9 Nov), so it is
    /// held while an editor is open: `settlePendingRebuild` (the composer calls
    /// it as it closes) or `endEditing` runs it. An editor that does neither
    /// gets it once the autosaves have stopped for `editorIdleRebuild`.
    private func publishAutosave() {
        scheduleRebuild(after: Self.editorIdleRebuild)
    }
    private static let editorIdleRebuild: UInt64 = 30_000_000_000

    // MARK: Cache patches (an edit's own entry, ahead of the rebuild)

    /// Counts every successful core write; `unpatchedSeq` counts those whose
    /// effect is not in the caches. A rebuild remembers both when it starts.
    private var mutationSeq = 0
    private var unpatchedSeq = 0
    /// `unpatchedSeq` as it was when the build now published began.
    private var freshAsOf = -1
    /// Whether `archiveEntries` and `splitEntriesCache` say what the disk does:
    /// the index has been published and nothing unpatched was written since the
    /// build it came from began. `entries(for:)` reads the caches only then.
    private var cacheFresh: Bool { indexed && unpatchedSeq == freshAsOf }

    private struct CachePatch {
        let seq: Int
        let original: Entry
        let updated: Entry
        let source: EntrySource
        let destination: EntrySource
    }
    /// Patches a build still in flight may not have seen: its publication
    /// would put the older text back, so they are applied again on top of it.
    /// Kept only while a build is running, and dropped when the next starts.
    private var cachePatches: [CachePatch] = []
    private var buildInFlight = false

    /// The write that just succeeded replaced `original` with `updated`: put
    /// that into whichever list holds it and tell the views.
    private func recordPatch(replacing original: Entry, with updated: Entry, source: EntrySource, destination: EntrySource) {
        let patch = CachePatch(seq: mutationSeq, original: original, updated: updated, source: source, destination: destination)
        if buildInFlight { cachePatches.append(patch) }
        if applyPatch(patch) {
            revision &+= 1
        } else if source == .inbox {
            // A draft the list didn't have: the inbox is cheap to read again,
            // and the archive caches were never involved.
            loadInbox()
        } else if indexed {
            // The lists were behind already: readers go to the core until a
            // rebuild. (Before the first index there is nothing to patch; it
            // applies the patches still waiting when it lands.)
            unpatchedSeq &+= 1
        }
    }

    private func holds(_ entry: Entry, in source: EntrySource) -> Bool {
        switch source {
        case .inbox: return Self.position(of: entry, in: inboxDrafts) != nil
        case .archive(let date):
            return archiveEntries.first { $0.date == date }.map { Self.position(of: entry, in: $0.entries) != nil } ?? false
        case .journal(let name):
            return splitEntriesCache[name].map { Self.position(of: entry, in: $0) != nil } ?? false
        }
    }

    /// Where `entry` is in a list. By raw text, as the core finds one, apart
    /// from trailing newlines: an entry read from a file carries the blank
    /// line after it, one parsed from a write's result doesn't.
    private static func position(of entry: Entry, in list: [Entry]) -> Int? {
        let raw = JournalParser.trimRightNewlines(entry.raw)
        func same(_ other: Entry) -> Bool { JournalParser.trimRightNewlines(other.raw) == raw }
        return list.firstIndex { $0.file == entry.file && $0.fileIndex == entry.fileIndex && same($0) }
            ?? list.firstIndex { $0.file == entry.file && same($0) }
            ?? list.firstIndex(where: same)
    }

    /// `list` with `entry` put where its file and index say, and the entries of
    /// that file numbered again in order (a list holds a file's entries in file
    /// order). An index that is slightly out is harmless: the core finds an
    /// entry by its raw text when the index has moved.
    private static func inserting(_ entry: Entry, into list: [Entry]) -> [Entry] {
        var list = list
        let at = list.firstIndex { other in
            guard let a = other.file, let b = entry.file else { return false }
            if a != b { return a > b }
            return (other.fileIndex ?? 0) >= (entry.fileIndex ?? 0)
        } ?? list.count
        list.insert(entry, at: at)
        return renumbered(list, file: entry.file)
    }

    private static func renumbered(_ list: [Entry], file: String?) -> [Entry] {
        guard let file else { return JournalParser.withOccurrences(list) }
        var n = 0
        return JournalParser.withOccurrences(list.map { e in
            guard e.file == file else { return e }
            var e = e
            e.fileIndex = n
            n += 1
            return e
        })
    }

    private func applyPatch(_ patch: CachePatch) -> Bool {
        let original = patch.original, updated = patch.updated
        switch patch.source {
        case .inbox:
            guard let i = Self.position(of: original, in: inboxDrafts) else { return false }
            if updated.file == original.file, updated.fileIndex == inboxDrafts[i].fileIndex {
                var list = inboxDrafts
                list[i] = updated
                inboxDrafts = JournalParser.withOccurrences(list)
            } else {
                // Retimed into another day file: read the inbox (only) again.
                loadInbox()
            }
            return true
        case .archive:
            var days = archiveEntries
            guard let d = days.firstIndex(where: { $0.date == original.date }),
                  let i = Self.position(of: original, in: days[d].entries) else { return false }
            days[d].entries.remove(at: i)
            days[d].entries = Self.renumbered(days[d].entries, file: original.file)
            if days[d].entries.isEmpty { days.remove(at: d) }
            if let t = days.firstIndex(where: { $0.date == updated.date }) {
                days[t].entries = Self.inserting(updated, into: days[t].entries)
            } else {
                let at = days.firstIndex { $0.date < updated.date } ?? days.count
                days.insert((date: updated.date, entries: JournalParser.withOccurrences([updated])), at: at)
            }
            archiveEntries = days
            // The day summaries the Journal lists.
            var summaries = archiveDays.filter { $0.date != original.date && $0.date != updated.date }
            for date in Set([original.date, updated.date]) {
                if let day = days.first(where: { $0.date == date }) {
                    summaries.append(Self.summary(date: date, entries: day.entries))
                }
            }
            archiveDays = summaries.sorted { $0.date > $1.date }
            return true
        case .journal(let name):
            guard var list = splitEntriesCache[name],
                  let i = Self.position(of: original, in: list) else { return false }
            list.remove(at: i)
            list = Self.renumbered(list, file: original.file)
            splitEntriesCache[name] = Self.inserting(updated, into: list)
            return true
        }
    }

    /// One day's line in the Journal list, from its entries.
    nonisolated static func summary(date: String, entries: [Entry]) -> ArchiveDay {
        var day = ArchiveDay(date: date, count: entries.count, preview: entries.first?.preview ?? "")
        day.hasStarred = entries.contains { $0.isStarred }
        for entry in entries {
            for path in mediaPaths(in: entry.raw) {
                switch MediaKind(path: path) {
                case .image: day.hasPhoto = true
                case .video: day.hasVideo = true
                case .audio: day.hasAudio = true
                }
            }
        }
        return day
    }

    /// An entry was edited or deleted: a weekly note that teases it must not
    /// arrive with the old title.
    private func entryTouched(_ entry: Entry) {
        ResurfacingScheduler.cancelIfTeasing(ts: entry.ts)
    }

    // MARK: Editing sessions

    private var editingDepth = 0
    /// An editor is open: the rebuild its autosaves put off is held until
    /// `endEditing`. Optional (the composer's `settlePendingRebuild` on close
    /// does the same job), but with it nothing lands mid-typing however long
    /// the pause.
    func beginEditing() { editingDepth += 1 }
    func endEditing() {
        editingDepth = max(0, editingDepth - 1)
        if editingDepth == 0 { settlePendingRebuild() }
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
        // Before the folder is even found: what Today showed last time, so the
        // page has something to draw while the journal is read.
        todaySnapshot = Self.loadTodaySnapshot()?.rolled(to: Self.nowDate())
        observeDayAndLock()
        resolveBaseAndReload()
    }

    private var lifetimeObservers: [NSObjectProtocol] = []
    /// Midnight (or a change of time zone) makes "today" another day with no
    /// file changing, and the app lock decides what the widget may say.
    private func observeDayAndLock() {
        let center = NotificationCenter.default
        lifetimeObservers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.rebuildIfDayChanged() }
        })
        lifetimeObservers.append(center.addObserver(forName: .quireAppLockChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appLockChanged() }
        })
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
        // Nothing of the folder before is known about this one.
        if indexed { indexed = false }
        freshAsOf = -1; cachePatches = []; buildInFlight = false; indexDay = ""
        lastSignatures = [:]; ownWrites = [:]; legacyDeclined = nil
        interruptedRestore = nil
        if let snap = todaySnapshot, snap.base != resolved.url?.path { todaySnapshot = nil }
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
        openFolder(url)
    }

    /// The first read of a folder just opened. A journal jnl or Nook wrote has
    /// its `inbox.md` and `<tag>.md` folded into day files first, one
    /// coordinated write per day: that happens here, off the main actor (on the
    /// main actor a large one risked the launch watchdog), and the journal is
    /// read when it is done. What an interrupted restore left is dealt with on
    /// the way.
    private func openFolder(_ base: URL) {
        reloadStartedAt = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            let leftover = Self.sweepRestoreLeftovers(base: base)
            var migrateError: String?
            if Self.legacySignature(base: base) != nil {
                await MainActor.run { [weak self] in
                    guard let self, self.baseURL == base else { return }
                    self.foldingLegacy = true
                }
                do { try CoreJournal(base: base).migrate() }
                catch { migrateError = journalErrorMessage(error) }
            }
            let failure = migrateError
            let declined = Self.legacySignature(base: base) ?? ""
            await MainActor.run { [weak self] in
                guard let self, self.baseURL == base else { return }
                if self.foldingLegacy { self.foldingLegacy = false }
                self.legacyDeclined = declined
                self.interruptedRestore = leftover
                if let message = failure ?? leftover { self.lastWriteError = message }
                self.reload()
            }
        }
    }

    /// What is left in the folder root for `migrate` to fold: `inbox.md` and
    /// any other markdown file there (a legacy split journal, or a note that
    /// isn't one and will be left alone). Names, sizes and dates only, so it
    /// costs one directory listing. Nil when there is nothing.
    nonisolated static func legacySignature(base: URL) -> String? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: keys) else { return nil }
        var parts: [String] = []
        for url in items where url.pathExtension == "md" && !nonJournalFiles.contains(url.lastPathComponent) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize, size > 0 else { continue }
            parts.append("\(url.lastPathComponent):\(size):\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        return parts.isEmpty ? nil : parts.sorted().joined(separator: "|")
    }

    /// The legacy files `migrate` was last run over (and left, when it left
    /// any). While the root still looks like this there is nothing new to fold.
    private var legacyDeclined: String?

    /// Fold legacy files into day files when there are some that haven't been
    /// looked at. One directory listing when there is nothing to do, which is
    /// nearly always: the fold itself lists the inbox, journal and split trees
    /// in full, and used to run on every autosave.
    private func migrateLegacyIfPresent() {
        guard let base = baseURL, let core else { return }
        guard let found = Self.legacySignature(base: base), found != legacyDeclined else { return }
        do { try core.migrate() } catch { lastWriteError = journalErrorMessage(error) }
        legacyDeclined = Self.legacySignature(base: base) ?? ""
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
        clearTodaySnapshot()
        resolveBaseAndReload()
    }

    /// Forget the custom folder and fall back to iCloud / local.
    func useDefaultFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        clearTodaySnapshot()
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

    private nonisolated static let stampFormatter: DateFormatter = {
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
        // One that just failed isn't tried again on the next keystroke.
        guard backupBackoffRemaining <= 0, !backupRunning else { return }
        Task { await performBackup(scheduled: true) }
    }

    // A failed backup is retried, but not at once: five minutes after the
    // first failure, doubling to six hours. The trigger is a write, so without
    // this a backup that can't finish started again on every autosave.
    private static let backupAttemptKey = "lastBackupAttemptAt"
    private static let backupFailuresKey = "backupFailureCount"
    nonisolated static func backupBackoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(300 * pow(2, Double(min(failures, 12) - 1)), 6 * 60 * 60)
    }
    private var backupBackoffRemaining: TimeInterval {
        let defaults = UserDefaults.standard
        let failures = defaults.integer(forKey: Self.backupFailuresKey)
        let last = defaults.double(forKey: Self.backupAttemptKey)
        guard failures > 0, last > 0 else { return 0 }
        return Self.backupBackoff(failures: failures) - Date().timeIntervalSince(Date(timeIntervalSince1970: last))
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
            // else was coming to reschedule it. The same for a backoff after a
            // failure.
            var wait = self.backupBackoffRemaining
            if let last = self.lastBackupAt {
                wait = max(wait, Self.changeBackupFloor - Date().timeIntervalSince(last))
            }
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            await self.performBackup(scheduled: true)
        }
    }

    /// Copy the whole journal folder into a timestamped subfolder of the backup
    /// location, then prune to the newest `backupKeepCount` copies. The copy runs
    /// off the main actor so a big assets folder never blocks writing.
    @discardableResult
    func runBackup() async -> (ok: Bool, message: String) {
        await performBackup(scheduled: false)
    }

    /// `scheduled` is a backup nobody asked for just now: its failure has no
    /// sheet to show in, so it is said through `lastWriteError` as well as
    /// `lastBackupError`.
    @discardableResult
    private func performBackup(scheduled: Bool) async -> (ok: Bool, message: String) {
        guard !backupRunning else { return (false, "A backup is already running.") }
        guard let base = baseURL else { return (false, "No journal folder to back up.") }
        guard let backupBase = resolveBackupURL() else {
            return (false, "Choose a backup folder first.")
        }
        if let clash = Self.nestingProblem(base: base, backupBase: backupBase) { return (false, clash) }
        backupRunning = true
        defer { backupRunning = false }
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: Self.backupAttemptKey)
        let name = Self.backupPrefix + Self.stampFormatter.string(from: Date())
        let keep = backupKeepCount
        let result = await Task.detached(priority: .utility) {
            Self.copyTree(from: base, into: backupBase, named: name, keep: keep)
        }.value
        if result.ok {
            let now = Date()
            lastBackupAt = now
            defaults.set(now.timeIntervalSince1970, forKey: lastBackupKey)
            defaults.set(0, forKey: Self.backupFailuresKey)
            if lastBackupError != nil { lastBackupError = nil }
        } else {
            defaults.set(defaults.integer(forKey: Self.backupFailuresKey) + 1, forKey: Self.backupFailuresKey)
            lastBackupError = result.message
            if scheduled { lastWriteError = result.message }
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

    /// Scheduled and manual backups. Retention prunes these and nothing else.
    nonisolated static let backupPrefix = "Quire-Backup-"
    /// The copy a restore takes of what it is about to replace. Listed with the
    /// backups, never pruned with them.
    nonisolated static let safetyPrefix = "Quire before-restore "

    /// The copy + prune itself, off-main. Security-scoped access is held around
    /// both so a sandboxed user-picked backup folder stays writable.
    ///
    /// The copy is made under a `.partial` name and renamed once it checks out,
    /// so one that was interrupted is never listed, never takes a retention
    /// slot and can't be restored from. It is checked against the sizes noted
    /// as each file was copied, not against the journal afterwards: the journal
    /// is being written to (a write is what starts most backups), and comparing
    /// with it failed every backup taken while typing. `beforeFile` runs before
    /// each file is copied, so a test can change the journal mid-copy.
    nonisolated static func copyTree(
        from base: URL, into backupBase: URL, named name: String, keep: Int,
        beforeFile: (String) -> Void = { _ in }
    ) -> (ok: Bool, message: String) {
        let fm = FileManager.default
        let scoped = backupBase.startAccessingSecurityScopedResource()
        defer { if scoped { backupBase.stopAccessingSecurityScopedResource() } }
        sweepPartials(in: backupBase)
        let previous = backupNames(in: backupBase).first
        let target = backupBase.appendingPathComponent(name)
        let partial = backupBase.appendingPathComponent(".\(name).partial")
        let copied: (files: Int, bytes: Int64)
        do {
            guard !fm.fileExists(atPath: target.path) else { throw CopyFailure("A backup called \(name) is already there.") }
            try? fm.removeItem(at: partial)
            let manifest = try copyRecording(from: base, to: partial, beforeFile: beforeFile)
            try verify(partial, against: manifest)
            try fm.moveItem(at: partial, to: target)
            copied = (manifest.count, manifest.values.reduce(0, +))
        } catch {
            try? fm.removeItem(at: partial)
            return (false, "Backup failed: \(error.localizedDescription)")
        }
        guard keep > 0 else { return (true, "Backed up to \(name).") }
        // A journal that has suddenly shrunk is more likely damage than an
        // edit. The older backups may be the only good ones, so they all stay.
        if let previous, let before = try? treeStats(backupBase.appendingPathComponent(previous)),
           shrankDrastically(from: before, to: copied) {
            return (true, "Backed up to \(name). It is much smaller than the last backup, so no older backup was removed.")
        }
        prune(in: backupBase, keep: keep)
        return (true, "Backed up to \(name).")
    }

    /// Less than half the files, or half the bytes, of the backup before.
    nonisolated static func shrankDrastically(from before: (files: Int, bytes: Int64), to after: (files: Int, bytes: Int64)) -> Bool {
        (before.files >= 4 && after.files * 2 < before.files) || (before.bytes >= 4096 && after.bytes * 2 < before.bytes)
    }

    private struct CopyFailure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Names a backup doesn't carry: writes in flight, and what a restore left.
    private nonisolated static func isTransient(_ name: String) -> Bool {
        (name.hasPrefix(".quire-") && name.hasSuffix(".tmp")) || name.hasPrefix("._tmp_") || name.hasPrefix(".quire-restore-")
    }

    /// Copy `base` to `dest` file by file, returning each copied file's path
    /// (relative) and the size its copy had. A file that goes while the copy
    /// runs (a day file emptied, a temporary file) is not an error; an iCloud
    /// placeholder is, after asking for the download, because a copy of one
    /// holds none of the file's contents.
    private nonisolated static func copyRecording(
        from base: URL, to dest: URL, beforeFile: (String) -> Void
    ) throws -> [String: Int64] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var failure: Error?
        // A folder that has gone (a drive removed) must fail the backup, not
        // be copied as an empty journal.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let walk = fm.enumerator(at: base, includingPropertiesForKeys: keys, options: [],
                                       errorHandler: { _, error in failure = error; return false })
        else { throw CopyFailure("Couldn't read \(base.lastPathComponent).") }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let roots = [base.path, base.resolvingSymlinksInPath().path, "/private" + base.path]
        var manifest: [String: Int64] = [:]
        for case let item as URL in walk {
            let name = item.lastPathComponent
            guard let root = roots.first(where: { item.path.hasPrefix($0 + "/") }) else {
                throw CopyFailure("Couldn't place \(name) in the journal folder.")
            }
            let rel = String(item.path.dropFirst(root.count + 1))
            let v = try item.resourceValues(forKeys: Set(keys))
            if isTransient(name) {
                if v.isDirectory == true { walk.skipDescendants() }
                continue
            }
            if item.pathExtension == "icloud", name.hasPrefix(".") {
                try? fm.startDownloadingUbiquitousItem(at: item)
                throw CopyFailure("Some files are still downloading from iCloud. Try again shortly.")
            }
            let to = dest.appendingPathComponent(rel)
            if v.isSymbolicLink == true {
                // The link itself, never what it points at.
                try? fm.copyItem(at: item, to: to)
                walk.skipDescendants()
            } else if v.isDirectory == true {
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
            } else if v.isRegularFile == true {
                beforeFile(rel)
                do { try fm.copyItem(at: item, to: to) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    if fm.fileExists(atPath: item.path) { throw error }
                    continue
                }
                manifest[rel] = (try fm.attributesOfItem(atPath: to.path)[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        if let failure { throw failure }
        return manifest
    }

    /// The copy holds exactly the files that were copied, at the sizes they had.
    private nonisolated static func verify(_ copy: URL, against manifest: [String: Int64]) throws {
        let fm = FileManager.default
        var seen = 0
        for (rel, size) in manifest {
            let attributes = try? fm.attributesOfItem(atPath: copy.appendingPathComponent(rel).path)
            guard let found = (attributes?[.size] as? NSNumber)?.int64Value, found == size else {
                throw CopyFailure("The copy doesn't match: \(rel) is not as it was copied.")
            }
            seen += 1
        }
        let stats = try treeStats(copy)
        guard stats.files == seen else {
            throw CopyFailure("The copy doesn't match: \(stats.files) files, expected \(seen).")
        }
    }

    /// A `.partial` folder nobody is still writing: an interrupted backup.
    private nonisolated static func sweepPartials(in backupBase: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in (try? fm.contentsOfDirectory(at: backupBase, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "partial" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    /// The finished backups in a folder, newest first. Partials (dot-named) and
    /// restore safety copies are not among them.
    private nonisolated static func backupNames(in backupBase: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: backupBase, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix(backupPrefix) }
            .sorted(by: >)
    }

    /// Files and bytes in a tree. Throws on an iCloud placeholder, after asking
    /// for the download: a copy of one holds none of the file's contents.
    private nonisolated static func treeStats(_ root: URL) throws -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var files = 0
        var bytes: Int64 = 0
        var failure: Error?
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                       errorHandler: { _, error in failure = error; return false })
        else { throw CopyFailure("Couldn't read \(root.lastPathComponent).") }
        for case let item as URL in walk {
            if item.pathExtension == "icloud" {
                try? fm.startDownloadingUbiquitousItem(at: item)
                throw CopyFailure("Some files are still downloading from iCloud. Try again shortly.")
            }
            let v = try item.resourceValues(forKeys: Set(keys))
            if v.isRegularFile == true, v.isSymbolicLink != true {
                files += 1
                bytes += Int64(v.fileSize ?? 0)
            }
        }
        if let failure { throw failure }
        return (files, bytes)
    }

    /// Two trees that are not being written to (a backup and its staged copy).
    private nonisolated static func verifyCopy(of original: URL, at copy: URL) throws {
        let a = try treeStats(original), b = try treeStats(copy)
        guard a == b else {
            throw CopyFailure("The copy doesn't match: \(b.files) files and \(b.bytes) bytes, expected \(a.files) and \(a.bytes).")
        }
    }

    // MARK: Restore

    struct BackupCopy: Identifiable, Sendable {
        let name: String       // "Quire-Backup-YYYY-MM-dd-HH-mm-ss", or a restore's safety copy
        let date: Date?
        var id: String { name }
        /// What a restore kept of the journal it replaced.
        var isSafetyCopy: Bool { name.hasPrefix(JournalStore.safetyPrefix) }
    }

    /// The timestamped copies in the backup folder, newest first: backups, and
    /// the safety copies restores have taken. Unfinished copies are not listed.
    func listBackups() async -> [BackupCopy] {
        guard let backupBase = resolveBackupURL() else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let scoped = backupBase.startAccessingSecurityScopedResource()
            defer { if scoped { backupBase.stopAccessingSecurityScopedResource() } }
            return Self.backupCopies(in: backupBase)
        }.value
    }

    nonisolated static func backupCopies(in backupBase: URL) -> [BackupCopy] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return ((try? FileManager.default.contentsOfDirectory(at: backupBase, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
            .compactMap { name -> BackupCopy? in
                for prefix in [backupPrefix, safetyPrefix] where name.hasPrefix(prefix) {
                    return BackupCopy(name: name, date: f.date(from: String(name.dropFirst(prefix.count))))
                }
                return nil
            }
            .sorted { ($0.date ?? .distantPast, $0.name) > ($1.date ?? .distantPast, $1.name) }
    }

    /// Replace the journal with a backup copy. A safety copy of the current
    /// folder is taken first (never pruned), so a restore is itself restorable.
    /// Runs off-main; reloads on success.
    func restoreBackup(named name: String) async -> (ok: Bool, message: String) {
        guard !backupRunning else { return (false, "A backup is already running.") }
        guard let base = baseURL else { return (false, "No journal folder to restore into.") }
        guard let backupBase = resolveBackupURL() else { return (false, "Choose a backup folder first.") }
        if let clash = Self.nestingProblem(base: base, backupBase: backupBase) { return (false, clash) }
        backupRunning = true
        defer { backupRunning = false }
        let result = await Task.detached(priority: .userInitiated) {
            Self.restore(base: base, backupBase: backupBase, named: name)
        }.value
        if result.0 {
            let now = Date()
            lastBackupAt = now   // the safety copy counts
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastBackupKey)
            reload()
        }
        return (ok: result.0, message: result.1)
    }

    /// The safety copy, then the swap, with one security scope on the backup
    /// folder itself held across both: a scope asked for on a URL made from it
    /// (the backup's own folder) isn't one the sandbox knows.
    nonisolated static func restore(base: URL, backupBase: URL, named name: String, now: Date = Date()) -> (Bool, String) {
        let scoped = backupBase.startAccessingSecurityScopedResource()
        defer { if scoped { backupBase.stopAccessingSecurityScopedResource() } }
        let safetyName = safetyPrefix + stampFormatter.string(from: now)
        // keep: 0, so taking it prunes nothing: least of all the backup that's
        // about to be restored.
        let safety = copyTree(from: base, into: backupBase, named: safetyName, keep: 0)
        guard safety.ok else {
            return (false, "Couldn't take a safety copy first — nothing was changed. \(safety.message)")
        }
        return replaceTree(base: base, from: backupBase.appendingPathComponent(name))
    }

    /// What an interrupted restore left in the journal folder. A staged copy
    /// (`.quire-restore-new-…`) is only a copy of a backup and is removed once
    /// it is an hour old (a restore on another device may be using a newer
    /// one). `.quire-restore-old-…` holds what the restore had moved out of the
    /// journal, which may be the only copy: it is never touched, and the
    /// message returned says where it is.
    nonisolated static func sweepRestoreLeftovers(base: URL, now: Date = Date()) -> String? {
        let fm = FileManager.default
        var kept: [String] = []
        for url in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let name = url.lastPathComponent
            if name.hasPrefix(".quire-restore-new-") {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(modified) > 3600 { try? fm.removeItem(at: url) }
            } else if name.hasPrefix(".quire-restore-old-") {
                kept.append(name)
            }
        }
        guard !kept.isEmpty else { return nil }
        return "A restore was interrupted. What it had moved out of your journal is still in the journal folder, in \(kept.sorted().joined(separator: ", ")). Check that nothing is missing before removing it."
    }

    /// Hidden items other than the sidecars stay where they are: .git, Syncthing's
    /// .stfolder/.stignore and the like aren't the journal's to replace. Same rule
    /// as `restorable` in the core.
    private nonisolated static func restorable(_ name: String) -> Bool {
        !name.hasPrefix(".") || name == ".quire" || name == ".nook"
    }

    /// Replace the journal's contents with a backup's. The backup is first checked
    /// to look like a journal, copied into a staging folder inside the journal and
    /// checked against the original; only then does anything live move. The swap
    /// is renames, undone if one fails, under one coordinated write so a sync
    /// provider sees a move and never an emptied journal. Old content goes last.
    /// `beforeMove` runs before each rename, so tests can make one fail.
    nonisolated static func replaceTree(
        base: URL, from backup: URL, beforeMove: (String) throws -> Void = { _ in }
    ) -> (Bool, String) {
        // The caller holds the security scope on the backup folder (`restore`).
        let fm = FileManager.default
        guard fm.fileExists(atPath: backup.appendingPathComponent("inbox").path)
                || fm.fileExists(atPath: backup.appendingPathComponent("split").path)
                || fm.fileExists(atPath: backup.appendingPathComponent("inbox.md").path)
                || fm.fileExists(atPath: backup.appendingPathComponent("journal").path) else {
            return (false, "That folder doesn't look like a Quire backup — nothing was changed.")
        }
        // Unique names: a leftover from a crash may hold the only copy of something.
        let id = UUID().uuidString
        let staged = base.appendingPathComponent(".quire-restore-new-\(id)", isDirectory: true)
        let old = base.appendingPathComponent(".quire-restore-old-\(id)", isDirectory: true)
        do {
            try fm.copyItem(at: backup, to: staged)
            try verifyCopy(of: backup, at: staged)
        } catch {
            try? fm.removeItem(at: staged)
            return (false, "Couldn't copy the backup, so nothing was changed. \(error.localizedDescription)")
        }
        var result: (Bool, String) = (false, "Restore couldn't get access to the journal folder — nothing was changed.")
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: base, options: .forMerging,
                                                         error: &coordinationError) { folder in
            result = swapIn(base: folder, staged: staged, old: old, backupName: backup.lastPathComponent, beforeMove: beforeMove)
        }
        if coordinationError != nil { try? fm.removeItem(at: staged) }
        return result
    }

    private nonisolated static func swapIn(
        base: URL, staged: URL, old: URL, backupName: String, beforeMove: (String) throws -> Void
    ) -> (Bool, String) {
        let fm = FileManager.default
        var movedOut: [String] = [], movedIn: [String] = []
        do {
            let names: (URL) throws -> [String] = { dir in
                try fm.contentsOfDirectory(atPath: dir.path).filter(restorable)
            }
            let live = try names(base), incoming = try names(staged)
            try fm.createDirectory(at: old, withIntermediateDirectories: false)
            for name in live {
                try beforeMove(name)
                try fm.moveItem(at: base.appendingPathComponent(name), to: old.appendingPathComponent(name))
                movedOut.append(name)
            }
            for name in incoming {
                try beforeMove(name)
                try fm.moveItem(at: staged.appendingPathComponent(name), to: base.appendingPathComponent(name))
                movedIn.append(name)
            }
        } catch {
            var stuck = false
            for name in movedIn {
                do { try fm.moveItem(at: base.appendingPathComponent(name), to: staged.appendingPathComponent(name)) } catch { stuck = true }
            }
            for name in movedOut {
                do { try fm.moveItem(at: old.appendingPathComponent(name), to: base.appendingPathComponent(name)) } catch { stuck = true }
            }
            if stuck {
                // Keep both folders: they hold what couldn't be moved back.
                return (false, "Restore failed partway: \(error.localizedDescription). Some items are still in \(old.lastPathComponent) in the journal folder, and a safety copy is in the backup folder.")
            }
            try? fm.removeItem(at: staged)
            try? fm.removeItem(at: old)
            return (false, "Restore failed, and your journal was put back as it was. \(error.localizedDescription)")
        }
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)
        return (true, "Restored \(backupName). The pre-restore journal was saved as a new backup.")
    }

    /// Keep only the newest `keep` backups. The timestamped names sort
    /// lexicographically == chronologically, the same trick jnl uses for entries.
    /// Only finished backups count and only they go: a restore's safety copy
    /// and a copy still being made have other names.
    private nonisolated static func prune(in backupBase: URL, keep: Int) {
        guard keep > 0 else { return }
        for stale in backupNames(in: backupBase).dropFirst(keep) {
            try? FileManager.default.removeItem(at: backupBase.appendingPathComponent(stale))
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
        loadInbox()      // folds a legacy inbox.md or <tag>.md first, when one is there
        rebuildIndex()   // bumps `revision`
        dataSaved = totalDataSaved()
    }

    /// What the journal looked like when the index now showing was read: each
    /// file's size and date by path (a stat-only walk, no file reads). Recorded
    /// when an index is published, never before: a reload that fails must leave
    /// the next look still seeing a change.
    private var lastSignatures: [String: String] = [:]
    private var reloadStartedAt = Date.distantPast
    /// Files this app has written itself since then, and when. A change to one
    /// of these alone is our own write coming back through the watcher.
    private var ownWrites: [String: Date] = [:]
    private func noteOwnWrite(_ rel: String?) {
        if let rel { ownWrites[rel] = Date() }
    }
    /// The day ("YYYY-MM-DD") the index now showing was built for: today's
    /// words, the streak and On this day are all relative to it.
    private var indexDay = ""

    /// Foreground/activation path: skip the full reload when nothing on disk
    /// changed. Every app-switch used to trigger a complete corpus re-read.
    func reloadIfChanged() {
        guard let base = baseURL else { return }
        // The first index is still being built (it records the signatures when
        // it lands), so there is nothing yet to compare against: a second full
        // read here would double the time to open the journal.
        if !indexed, Date().timeIntervalSince(reloadStartedAt) < 120 { return }
        if rebuildIfDayChanged() { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let now = Self.contentSignatures(base: base)
            await MainActor.run { [weak self] in
                guard let self, self.baseURL == base, self.changedElsewhere(now) else { return }
                self.reload()
            }
        }
    }

    /// The index was built for a day that is no longer today (the app sat
    /// suspended overnight, or midnight passed while it was open): read again,
    /// so Today, the streak, the widgets and On this day are about today. No
    /// file need have changed for this. True when it did reload.
    @discardableResult
    func rebuildIfDayChanged() -> Bool {
        guard baseURL != nil, indexed, Self.dayChanged(indexDay: indexDay, today: Self.nowDate()) else { return false }
        reload()
        return true
    }

    nonisolated static func dayChanged(indexDay: String, today: String) -> Bool {
        !indexDay.isEmpty && indexDay != today
    }

    /// Whether `now` differs from the last index in a file this app didn't
    /// write. A difference only in our own files is taken as read.
    private func changedElsewhere(_ now: [String: String]) -> Bool {
        let changed = Self.changedPaths(lastSignatures, now)
        guard !changed.isEmpty else { return false }
        if changed.contains(where: { ownWrites[$0] == nil }) { return true }
        for path in changed { lastSignatures[path] = now[path] }
        return false
    }

    nonisolated static func changedPaths(_ a: [String: String], _ b: [String: String]) -> Set<String> {
        var out = Set<String>()
        for (path, signature) in a where b[path] != signature { out.insert(path) }
        for path in b.keys where a[path] == nil { out.insert(path) }
        return out
    }

    /// Size and date of every entry file and sidecar, by path relative to the
    /// journal folder. Stat-only.
    nonisolated static func contentSignatures(base: URL) -> [String: String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var out: [String: String] = [:]
        func note(_ url: URL, _ rel: String) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return }
            out[rel] = "\(v.fileSize ?? 0):\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        for directory in ["inbox", "journal", "split", ".quire", ".nook"] {
            let root = base.appendingPathComponent(directory)
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            // iOS gives a folder as /var/… or /private/var/…, either way round.
            let prefixes = [root.path + "/", "/private" + root.path + "/"]
            for case let url as URL in en where url.pathExtension == "md" || url.pathExtension == "json" {
                let path = url.path
                if let prefix = prefixes.first(where: { path.hasPrefix($0) }) {
                    note(url, directory + "/" + path.dropFirst(prefix.count))
                } else {
                    note(url, path)
                }
            }
        }
        for url in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: keys)) ?? [] where url.pathExtension == "md" {
            note(url, url.lastPathComponent)
        }
        return out
    }

    /// Cheap change detector over inbox.md + every journal/split md file.
    nonisolated static func contentFingerprint(base: URL) -> String {
        contentSignatures(base: base).map { "\($0.key):\($0.value)" }.sorted().joined(separator: "|")
    }

    /// Read the drafts. No migration here beyond a look in the folder root for
    /// a legacy file: `migrate` lists the whole journal, and this runs after
    /// every discrete change.
    private func loadInbox() {
        guard let core else { inboxDrafts = []; return }
        migrateLegacyIfPresent()
        do { inboxDrafts = JournalParser.withOccurrences(try core.inbox().map(\.entry)) }
        catch { lastWriteError = journalErrorMessage(error) }
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

    /// Coalesce a burst of mutations into one rebuild. Nothing waits on it for
    /// the entry that was edited: an edit puts its own entry into the caches
    /// (`recordPatch`), and until a rebuild lands after any other kind of
    /// change `entries(for:)` reads the core. The rebuild reconciles the rest:
    /// tags, stats, the widget, Spotlight.
    private var rebuildDebounce: Task<Void, Never>?
    /// A rebuild is owed, whether or not a timer is running for it.
    private var rebuildWanted = false
    private var indexGeneration = 0
    private func scheduleRebuild(after nanoseconds: UInt64 = 300_000_000) {
        rebuildWanted = true
        rebuildDebounce?.cancel()
        rebuildDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            // An editor is open (`beginEditing`): `endEditing` runs it.
            guard self.editingDepth == 0 else { return }
            self.rebuildIndex()
        }
    }

    /// The rebuild an autosave put off, now: the composer calls this as it
    /// closes, so the screens beneath show the entry as soon as you're back.
    func settlePendingRebuild() {
        guard rebuildWanted else { return }
        rebuildIndex()
    }

    /// Rebuild the archive/tags/split-journal index off the main thread and
    /// publish the results, so no view body ever does directory-wide file reads.
    private func rebuildIndex() {
        rebuildDebounce?.cancel()
        rebuildDebounce = nil
        rebuildWanted = false
        indexGeneration &+= 1
        let generation = indexGeneration
        // Whatever was patched before now, this build reads after it.
        cachePatches = []
        guard let base = baseURL else {
            buildInFlight = false
            archiveDays = []; tagCounts = []; splitJournals = []
            archiveEntries = []; splitEntriesCache = [:]
            revision &+= 1
            return
        }
        buildInFlight = true
        let startedSeq = mutationSeq, startedUnpatched = unpatchedSeq
        let started = Date()
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
            // Taken before the read: a file that changes while the journal is
            // being read then differs from this at the next look, and the
            // journal is read again. (Taken after, such a change was recorded
            // as seen and stayed unread.)
            let signatures = Self.contentSignatures(base: base)
            // ONE pass: the index, the parsed corpus, and the stats all come
            // out of the same read of each file — this used to be two full
            // corpus reads per rebuild.
            let initial: BuiltIndex
            do { initial = try Self.buildIndex(base: base, triggerDownloads: triggerDownloads) }
            catch {
                await MainActor.run { [weak self] in
                    guard let self, self.baseURL == base, self.indexGeneration == generation else { return }
                    self.buildInFlight = false
                    self.lastWriteError = journalErrorMessage(error)
                }
                return
            }
            var built = initial
            built.heavy.wordsToday += inboxWordsToday
            built.heavy.hasEntryToday = built.heavy.hasEntryToday || hasDraftToday
            let idx = built
            let heavy = idx.heavy
            await MainActor.run { [weak self] in
                guard let self, self.baseURL == base, self.indexGeneration == generation else { return }
                self.lastSignatures = signatures
                self.ownWrites = self.ownWrites.filter { $0.value >= started }
                self.indexDay = todayISO
                self.archiveDays = idx.days
                var map = Dictionary(uniqueKeysWithValues: idx.tags.map { ($0.tag, $0.count) })
                for t in inboxTags { map[t, default: 0] += 1 }
                self.tagCounts = map.map { (tag: $0.key, count: $0.value) }
                    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
                self.splitJournals = idx.splits
                self.archiveEntries = idx.corpus
                self.indexed = true
                self.splitEntriesCache = idx.splitEntries
                // Editor saves made while this was being read: the read may
                // have come before them, so their entries go on top again.
                let later = self.cachePatches.filter { $0.seq > startedSeq }
                self.cachePatches = []
                self.buildInFlight = false
                var settled = true
                for patch in later where patch.source != .inbox {
                    if !self.applyPatch(patch) && !self.holds(patch.updated, in: patch.destination) { settled = false }
                }
                self.freshAsOf = startedUnpatched
                if !settled {
                    self.unpatchedSeq &+= 1
                    self.rebuildWanted = true
                }
                var withSizes = heavy
                withSizes.copySizes(from: self.lastHeavyStats)
                self.lastHeavyStats = withSizes
                // Announced here, at publication — every mutation funnels into
                // this rebuild, and views reloading on `.task(id: revision)`
                // must find the fresh corpus already in place when they fire.
                self.revision &+= 1
                // Today now draws from the journal itself; what it shows is
                // kept for the next launch.
                if self.todaySnapshot != nil { self.todaySnapshot = nil }
                self.saveTodaySnapshot()
                self.writeWidgetSnapshot()
                ReminderScheduler.refresh(hasEntryToday: heavy.hasEntryToday,
                                          streak: heavy.currentStreak)
                #if canImport(CoreSpotlight)
                SpotlightIndexer.scheduleReindex(source: { self.spotlightSource() })
                #endif
            }
            // The sizes, once the journal is showing.
            var sizes = HeavyStats()
            Self.measureSizes(&sizes, base: base)
            let measured = sizes
            await MainActor.run { [weak self] in
                guard let self, self.baseURL == base, self.indexGeneration == generation else { return }
                self.lastHeavyStats.copySizes(from: measured)
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
            // With the app lock on, the widget gets no words from the journal:
            // it says only that there is a memory, and how old ("A memory from
            // three years ago"). The link still opens it, behind the lock.
            if !defaults.bool(forKey: Self.appLockKey) {
                snap.onThisDayPreview  = heavy.onThisDayPreview
                snap.onThisDayExcerpt  = heavy.onThisDayExcerpt.isEmpty ? nil : heavy.onThisDayExcerpt
            }
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

    /// AppLockManager.enabledKey; AppLock.swift isn't compiled into the tests.
    nonisolated static let appLockKey = "appLock"

    /// The lock was switched on or off: what the widget and the weekly note
    /// may say has changed with it.
    private func appLockChanged() {
        guard indexed else { return }
        writeWidgetSnapshot()
        ResurfacingScheduler.settingsChanged(store: self)
    }

    // MARK: Today, as it was last drawn

    /// What Today needs to draw, kept in the app's own container (not the App
    /// Group: this holds titles) and read back at launch, so the page is up
    /// before the journal has been read. It says which day and which folder it
    /// describes; for any other day it is emptied, and for any other folder
    /// dropped.
    struct TodaySnapshot: Codable, Equatable {
        /// One of today's filed entries, as its row shows it. Enough to draw
        /// the row and to find the real entry by `id` once the journal is
        /// read; never a reference to edit with (there is no raw text here).
        struct Row: Codable, Equatable {
            var file: String?
            var index: Int?
            var occurrence = 0
            var ts: String
            var suffix: String
            /// The body lines the row shows, no more.
            var lines: String

            init(_ entry: Entry) {
                file = entry.file; index = entry.fileIndex; occurrence = entry.occurrence
                ts = entry.ts; suffix = entry.suffix
                // The first line (a title, when the header has none) and the
                // first two that aren't media: what `preview` and the row's
                // excerpt read.
                let all = entry.body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                var keep = Set<Int>()
                if !all.isEmpty { keep.insert(0) }
                for (i, line) in all.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("![") {
                    keep.insert(i)
                    if keep.count >= 3 { break }
                }
                lines = keep.sorted().map { String(all[$0].prefix(400)) }.joined(separator: "\n")
            }

            /// A stand-in to draw a row with. Its `id` is the real entry's.
            var entry: Entry {
                var e = Entry(date: String(ts.prefix(10)), ts: ts, suffix: suffix, body: lines,
                              raw: (suffix.isEmpty ? "[\(ts)]" : "[\(ts)] \(suffix)") + (lines.isEmpty ? "" : "\n" + lines))
                e.file = file; e.fileIndex = index; e.occurrence = occurrence
                return e
            }
        }

        /// An entry from this day in an earlier year: its title and tags.
        struct Memory: Codable, Equatable, Identifiable {
            var id: String
            var date: String
            var title: String
            var tags: [String]
        }

        var day: String
        /// The journal folder it was read from.
        var base: String
        /// Filed today, in file order.
        var entries: [Row] = []
        var onThisDay: [Memory] = []
        var wordsToday = 0
        var streak = 0
        var bestStreak = 0
        var inboxDrafts = 0
        var totalEntries = 0
        var totalWords = 0

        /// This snapshot as Today should draw it on `today`. On its own day,
        /// itself. On a later day nothing in it is about today any more:
        /// today's entries, its words and the memories go, and the streak
        /// survives only if it ran through the day before.
        func rolled(to today: String) -> TodaySnapshot {
            guard day != today else { return self }
            var next = self
            next.day = today
            next.entries = []
            next.onThisDay = []
            next.wordsToday = 0
            next.streak = (Self.dayAfter(day) == today && !entries.isEmpty) ? streak : 0
            return next
        }

        static func dayAfter(_ day: String) -> String? {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            guard let date = f.date(from: day),
                  let next = Calendar.current.date(byAdding: .day, value: 1, to: date) else { return nil }
            return f.string(from: next)
        }
    }

    /// Today's page as the caches have it now.
    func makeTodaySnapshot(today day: String? = nil) -> TodaySnapshot? {
        guard let base = baseURL else { return nil }
        let today = day ?? Self.nowDate()
        var snap = TodaySnapshot(day: today, base: base.path)
        snap.entries = (archiveEntries.first { $0.date == today }?.entries ?? []).map(TodaySnapshot.Row.init)
        let monthDay = String(today.suffix(5)), year = String(today.prefix(4))
        for day in archiveEntries where day.date.hasSuffix(monthDay) && String(day.date.prefix(4)) < year {
            for entry in day.entries.prefix(12) {
                snap.onThisDay.append(.init(id: entry.id, date: day.date,
                                            title: String(entry.preview.trimmingCharacters(in: .whitespaces).prefix(400)),
                                            tags: entry.tags))
            }
            if snap.onThisDay.count >= 60 { break }
        }
        let heavy = lastHeavyStats
        snap.wordsToday = heavy.wordsToday
        snap.streak = heavy.currentStreak
        snap.bestStreak = heavy.bestStreak
        snap.inboxDrafts = inboxDrafts.count
        snap.totalEntries = heavy.entries
        snap.totalWords = heavy.words
        return snap
    }

    private var lastTodaySaved: TodaySnapshot?

    /// Keep Today for the next launch. Skipped when nothing on the page moved.
    private func saveTodaySnapshot() {
        #if DEBUG
        if isTestStore { return }
        #endif
        guard let snap = makeTodaySnapshot(), snap != lastTodaySaved, let url = Self.todaySnapshotURL else { return }
        lastTodaySaved = snap
        Task.detached(priority: .utility) { Self.writeTodaySnapshot(snap, to: url) }
    }

    /// The journal folder is being changed: what Today showed is about the old one.
    private func clearTodaySnapshot() {
        todaySnapshot = nil
        lastTodaySaved = nil
        if let url = Self.todaySnapshotURL { try? FileManager.default.removeItem(at: url) }
    }

    /// In Application Support, inside the app's own container.
    nonisolated static var todaySnapshotURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.caddickbrown.quire", isDirectory: true)
            .appendingPathComponent("today.json")
    }

    nonisolated static func writeTodaySnapshot(_ snap: TodaySnapshot, to url: URL) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Unreadable while the device is locked, like anything else that holds
        // journal text and isn't the journal.
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    nonisolated static func loadTodaySnapshot(from url: URL? = todaySnapshotURL) -> TodaySnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TodaySnapshot.self, from: data)
    }

    /// The first body line worth showing under an entry's preview: not the
    /// preview itself, not a media link.
    nonisolated static func excerpt(of entry: Entry) -> String {
        let preview = entry.preview.trimmingCharacters(in: .whitespaces)
        let line = entry.shownBody.split(separator: "\n", omittingEmptySubsequences: true)
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
                body: String(e.shownBody.prefix(400)),
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
            let day = summary(date: staticFileToDate(u), entries: entries)
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

    /// Entries filed on a given day, chronological. From the index in memory
    /// when it says what the disk does; from the core (a read of the whole
    /// journal, so not something to call in a loop) only before the first
    /// index, and between a change the caches weren't given and its rebuild.
    func entries(for date: String) -> [Entry] {
        if cacheFresh { return archiveEntries.first { $0.date == date }?.entries ?? [] }
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
        guard let result = coreMutation(patched: true, { try $0.update(original, text: newText) }) else { return false }
        lastWritten = result
        patchAfterUpdate(original, result, source: .journal(name: name))
        publishCoreChange(reindex: reindex)
        return true
    }

    /// An update through one of the older (Mac) paths: the same patch the
    /// editor's saves make, so the lists are right before the rebuild lands
    /// (and at all, when the caller asked for no rebuild).
    private func patchAfterUpdate(_ original: Entry, _ result: CoreWritten, source: EntrySource) {
        entryTouched(original)
        guard var entry = JournalParser.parseEntries(result.raw).first else { unpatchedSeq &+= 1; return }
        entry.file = result.file
        entry.fileIndex = result.index
        var destination = source
        if case .archive = source { destination = .archive(date: entry.date) }
        recordPatch(replacing: original, with: entry, source: source, destination: destination)
    }

    @discardableResult
    func deleteJournalEntry(name: String, entry: Entry) -> Bool {
        let ok = coreMutation { try $0.delete(entry); return true } ?? false
        if ok { entryTouched(entry) }
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
            // Drafts only: the archive caches are as right as they were.
            if let composerEntry { _ = coreMutation(patched: true) { try $0.delete(composerEntry); return true } }
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
        let result: CoreWritten? = coreMutation(patched: true) { core in
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

    /// Remove a file from the Media Library. It is moved, not unlinked: into
    /// `.quire/media-cleanup/<UTC time>/deleted/`, where it stays for
    /// `recoveryDays`. False (and `lastWriteError`) when it couldn't be moved.
    @discardableResult
    func deleteAsset(_ url: URL) -> Bool {
        guard let base = baseURL, let core else {
            lastWriteError = "The journal folder is unavailable."
            return false
        }
        do {
            let rel = Self.relativePath(of: url, under: base)
            guard rel.hasPrefix("assets/"), fm.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "It is no longer in the media folder."])
            }
            let folder = Self.recoveryFolder(sidecar: try core.sidecar(write: true), bucket: "deleted")
            try AppleVault(base: base).rename(from: rel, to: folder + "/" + rel)
            lastLocalWriteAt = Date()
            Task.detached(priority: .utility) { Self.pruneRecovery(base: base) }
            return true
        } catch {
            lastWriteError = "Couldn't delete \(url.lastPathComponent): \(journalErrorMessage(error))"
            return false
        }
    }

    // MARK: Recovery folder (.quire/media-cleanup, as core/src/media_cleanup.rs)

    /// How long a parked original is kept. The core's RECOVERY_DAYS.
    nonisolated static let recoveryDays = 30

    /// A run's folder name: its UTC time, `20261020T101500.123456789`. The core
    /// prunes by the first fifteen characters, so the shape is its.
    nonisolated static func recoveryStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let whole = date.timeIntervalSince1970.rounded(.down)
        let nanos = Int((date.timeIntervalSince1970 - whole) * 1_000_000_000)
        return f.string(from: Date(timeIntervalSince1970: whole)) + String(format: ".%09d", max(0, min(nanos, 999_999_999)))
    }

    /// `<sidecar>/media-cleanup/<stamp>/<bucket>`: files go under it at their
    /// own journal-relative path, as the core's cleanup lays them out.
    /// `orphans` is the core's own bucket; `deleted` and `datasaver` are Apple's.
    nonisolated static func recoveryFolder(sidecar: String, stamp: String = recoveryStamp(), bucket: String) -> String {
        "\(sidecar)/media-cleanup/\(stamp)/\(bucket)"
    }

    /// Remove recovery folders older than `days`, judged by the UTC time in
    /// their name. A folder named anything else is left alone, and links are
    /// not followed. Returns how many went. Runs when media is cleared,
    /// deleted or compressed, never on a timer.
    @discardableResult
    nonisolated static func pruneRecovery(base: URL, days: Int = recoveryDays, now: Date = Date()) -> Int {
        let fm = FileManager.default
        let root = base.appendingPathComponent(".quire/media-cleanup", isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return 0 }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        var pruned = 0
        for item in items {
            let name = item.lastPathComponent
            guard name.count >= 15, let when = f.date(from: String(name.prefix(15))), when < cutoff,
                  let v = try? item.resourceValues(forKeys: Set(keys)), v.isDirectory == true, v.isSymbolicLink != true
            else { continue }
            var removed = false
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: item, options: .forDeleting, error: nil) { target in
                removed = (try? fm.removeItem(at: target)) != nil
            }
            if removed { pruned += 1 }
        }
        return pruned
    }

    nonisolated private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp",
    ]

    /// Conservatively checked unused assets; clearing retains recovery copies.
    func orphanAssets() -> [URL] {
        guard let baseURL, let core else { return [] }
        do { let files: [String] = try core.call("orphans"); return files.map { baseURL.appendingPathComponent($0) } }
        catch { lastWriteError = journalErrorMessage(error); return [] }
    }

    /// `orphanAssets`, off the main actor: the check reads every entry file.
    func orphanAssetsAsync() async -> [URL] {
        guard let base = baseURL else { return [] }
        let found: Result<[String], Error> = await Task.detached(priority: .userInitiated) {
            Result { try CoreJournal(base: base).call("orphans") }
        }.value
        switch found {
        case .success(let files): return files.map { base.appendingPathComponent($0) }
        case .failure(let error): lastWriteError = journalErrorMessage(error); return []
        }
    }

    /// Clear the unused media: each file is moved into the recovery folder
    /// (never read into memory: one was a 1 GB video), after the core has
    /// checked again that nothing links it. Returns how many were cleared.
    @discardableResult
    func deleteOrphanAssets() -> Int {
        guard let base = baseURL else { lastWriteError = "The journal folder is unavailable."; return 0 }
        let outcome = Self.archiveOrphans(base: base)
        return finishOrphans(outcome)
    }

    /// `deleteOrphanAssets`, off the main actor.
    @discardableResult
    func deleteOrphanAssetsAsync() async -> Int {
        guard let base = baseURL else { lastWriteError = "The journal folder is unavailable."; return 0 }
        let outcome = await Task.detached(priority: .userInitiated) { Self.archiveOrphans(base: base) }.value
        return finishOrphans(outcome)
    }

    private func finishOrphans(_ outcome: (cleared: Int, error: String?)) -> Int {
        if let error = outcome.error { lastWriteError = error }
        if outcome.cleared > 0 {
            lastLocalWriteAt = Date()
            scheduleRebuild()
        }
        return outcome.cleared
    }

    /// The core says which files nothing links (a fresh check, not the list
    /// the person was shown); each is renamed into this run's recovery folder
    /// under file coordination. One that can't be moved stays where it is.
    nonisolated static func archiveOrphans(base: URL) -> (cleared: Int, error: String?) {
        let core = CoreJournal(base: base)
        var cleared = 0
        var failure: String?
        do {
            let orphans: [String] = try core.call("orphans")
            guard !orphans.isEmpty else { return (0, nil) }
            let folder = recoveryFolder(sidecar: try core.sidecar(write: true), bucket: "orphans")
            let vault = AppleVault(base: base)
            for rel in orphans where rel.hasPrefix("assets/") {
                do { try vault.rename(from: rel, to: folder + "/" + rel); cleared += 1 }
                catch { failure = failure ?? "Couldn't clear \((rel as NSString).lastPathComponent): \(journalErrorMessage(error))" }
            }
        } catch { failure = journalErrorMessage(error) }
        pruneRecovery(base: base)
        return (cleared, failure)
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
        guard let dir = newAssetsDirURL, let dest = Self.copyAsset(from: url, into: dir) else { return nil }
        let rel = assetRelativePath(dest)
        scheduleCompression(assetRelPath: rel)   // video/audio, in the background
        return rel
    }

    /// The copy itself, callable off the main actor. Nil on failure.
    nonisolated static func copyAsset(from url: URL, into dir: URL) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        return (try? fm.copyItem(at: url, to: dest)) != nil ? dest : nil
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
        guard let dir = newAssetsDirURL,
              let stored = Self.storeAsset(data, ext: ext, into: dir,
                                           dataSaver: UserDefaults.standard.bool(forKey: "dataSaver")) else { return nil }
        let rel = assetRelativePath(stored.url)
        if stored.saved > 0 { recordCompression(key: Self.ledgerKey(assetRelPath: rel), saved: stored.saved) }
        // Images are handled synchronously above; video/audio compress in the background.
        if !ImageDownsampler.compressible.contains(stored.url.pathExtension) { scheduleCompression(assetRelPath: rel) }
        return rel
    }

    /// Write attached data into `dir` under a fresh name, as a JPEG when it
    /// arrived as HEIC and downsampled when Data Saver is on. Callable off the
    /// main actor; the caller records `saved` in the ledger. Nil on failure.
    nonisolated static func storeAsset(_ data: Data, ext: String, into dir: URL, dataSaver: Bool) -> (url: URL, id: String, saved: Int)? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        var lower = ext.lowercased()
        var out = data
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
        let url = dir.appendingPathComponent("\(id).\(lower)")
        guard (try? out.write(to: url, options: .atomic)) != nil else { return nil }
        return (url, id, max(0, data.count - out.count))
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

    /// What every device's ledger lists as dealt with, so batch runs never repeat one.
    private func allHandledAssets() -> LedgerHandled {
        LedgerHandled(Set(allDataSaverRecords().flatMap(\.assets)))
    }

    /// An asset's name in the ledger: its path under `assets/` with its
    /// extension (`2026/09/x.jpg`), the core's `asset_key`.
    nonisolated static func ledgerKey(assetRelPath rel: String) -> String {
        rel.hasPrefix("assets/") ? String(rel.dropFirst("assets/".count)) : rel
    }

    /// The ids one asset is listed under, as the core's `ledger_add` writes
    /// them: the key, and the key without its extension (what Nook and earlier
    /// Quires look for). Two ids, one asset: nothing counts the list.
    nonisolated static func ledgerIDs(forKey key: String) -> [String] {
        let short = (key as NSString).deletingPathExtension
        return short == key || short.isEmpty ? [key] : [key, short]
    }

    /// The assets the ledgers list as done, read the way the core's `Handled`
    /// reads them. Three forms are about: the path under `assets/` with its
    /// extension (`2026/09/x.jpg`, the core since 0.12 and this app now), the
    /// same without the extension (`2026/09/x`), and the bare file name
    /// without it (`x`, what this app wrote before). A short form can't tell
    /// `x.jpg` from `x.mp4`, so it only counts when no long form explains it.
    struct LedgerHandled {
        private let ids: Set<String>
        /// Short forms a long form accounts for, whole and by file name.
        private let explained: Set<String>

        init(_ ids: Set<String>) {
            self.ids = ids
            var explained = Set<String>()
            for id in ids {
                let ext = (id as NSString).pathExtension.lowercased()
                guard !ext.isEmpty, ImageDownsampler.compressible.contains(ext) || ImageDownsampler.convertible.contains(ext)
                        || MediaTranscoder.video.contains(ext) || MediaTranscoder.audio.contains(ext) else { continue }
                let short = (id as NSString).deletingPathExtension
                explained.insert(short)
                explained.insert((short as NSString).lastPathComponent)
            }
            self.explained = explained
        }

        func has(key: String) -> Bool {
            if ids.contains(key) { return true }
            let short = (key as NSString).deletingPathExtension
            if ids.contains(short), !explained.contains(short) { return true }
            let name = (short as NSString).lastPathComponent
            return name != short && ids.contains(name) && !explained.contains(name)
        }
    }

    /// One asset's saving, counted once: a key the ledger already lists adds
    /// no bytes, as in the core's `ledger_add`.
    private func recordCompression(key: String, saved: Int) {
        guard var rec = loadMyRecord() else { return }
        if !rec.assets.contains(key) { rec.savedBytes += max(0, saved) }
        for id in Self.ledgerIDs(forKey: key) where !rec.assets.contains(id) { rec.assets.append(id) }
        saveMyRecord(rec)
        dataSaved = totalDataSaved()
    }

    /// Several assets at once (a batch run): one read and one write of the
    /// ledger for all of them. `keys` are those now dealt with, gain or none.
    private func recordCompressions(keys: [String], saved: Int) {
        guard !keys.isEmpty, var rec = loadMyRecord() else { return }
        rec.savedBytes += max(0, saved)
        var known = Set(rec.assets)
        for id in keys.flatMap(Self.ledgerIDs(forKey:)) where known.insert(id).inserted { rec.assets.append(id) }
        saveMyRecord(rec)
        dataSaved = totalDataSaved()
    }

    /// Mark an asset as handled (no bytes gained) so batch runs skip it next time.
    private func markHandled(key: String) {
        guard var rec = loadMyRecord() else { return }
        let missing = Self.ledgerIDs(forKey: key).filter { !rec.assets.contains($0) }
        guard !missing.isEmpty else { return }
        rec.assets.append(contentsOf: missing)
        saveMyRecord(rec)
    }

    /// Kick off background video/audio transcoding for a just-attached asset (when
    /// Data Saver is on). The original is stored/returned immediately; the file is
    /// swapped in place (same name/extension) once the export finishes, and the
    /// original goes to the recovery folder for `recoveryDays`.
    func scheduleCompression(assetRelPath: String) {
        guard UserDefaults.standard.bool(forKey: "dataSaver"),
              let base = baseURL, let url = assetURL(forRelative: assetRelPath) else { return }
        let ext = url.pathExtension.lowercased()
        guard MediaTranscoder.video.contains(ext) || MediaTranscoder.audio.contains(ext) else { return }
        let key = Self.ledgerKey(assetRelPath: assetRelPath)
        // Without somewhere to park the original it is not replaced at all.
        guard let sidecar = try? core?.sidecar(write: true) else { return }
        let recovery = base.appendingPathComponent(Self.recoveryFolder(sidecar: sidecar, bucket: "datasaver") + "/" + assetRelPath)
        Task.detached(priority: .background) {
            #if os(iOS)
            // Give the export a grace period if the app is backgrounded mid-encode.
            let bgTask = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "quire.compress") }
            defer { if bgTask != .invalid { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTask) } } }
            #endif
            let outcome = await MediaTranscodeQueue.shared.run { await MediaTranscoder.compress(url: url, ext: ext, recovery: recovery) }
            Self.pruneRecovery(base: base)
            await MainActor.run {
                switch outcome {
                case .saved(let saved): self.recordCompression(key: key, saved: saved)
                case .noGain: self.markHandled(key: key)
                // Not marked: it is tried again by "Compress Existing Media".
                case .failed: break
                }
            }
        }
    }

    struct MediaCompressionResult { var images = 0; var videos = 0; var audios = 0; var bytesSaved = 0; var converted = 0; var failed = 0 }

    /// Turn every HEIC/HEIF in assets/ into a JPEG under the same UUID, and point
    /// every link at it, so the photo shows in Wander on Linux and Android too.
    /// Not filtered by the Data Saver ledger: a HEIC another device has marked
    /// handled (Quire on Linux can't read one) still wants converting.
    ///
    /// The JPEG is written first, then every file linking to the HEIC is
    /// rewritten, and only then is the HEIC moved to the recovery folder —
    /// stopped at any point, every link still resolves. A file that can't be
    /// read (an iCloud placeholder, say) keeps every HEIC for the next run
    /// rather than leaving that file's link dead.
    ///
    /// The entry files are read once for the whole run, off the main actor,
    /// keeping only those that mention a HEIC at all: this used to read every
    /// file in the journal again for each photo.
    private func convertHEICAssets(recovery: String) async -> Int {
        guard let base = baseURL, let dir = assetsDirURL else { return 0 }
        let heics = await Task.detached(priority: .utility) {
            Self.listAssets(in: dir).map(\.url).filter { ImageDownsampler.convertible.contains($0.pathExtension.lowercased()) }
        }.value
        guard !heics.isEmpty else { return 0 }
        let dataSaver = UserDefaults.standard.bool(forKey: "dataSaver")
        let index = await Task.detached(priority: .utility) { Self.heicLinkIndex(base: base) }.value
        var texts = index.texts
        let vault = AppleVault(base: base)

        var converted = 0
        for heic in heics {
            guard baseURL == base else { break }
            let jpgName = "\(heic.deletingPathExtension().lastPathComponent).jpg"
            let jpgURL = heic.deletingLastPathComponent().appendingPathComponent(jpgName)
            let written = await Task.detached(priority: .utility) { () -> Bool in
                guard let data = try? Data(contentsOf: heic),
                      let jpg = ImageDownsampler.jpeg(data, dataSaver: dataSaver) else { return false }
                return (try? jpg.write(to: jpgURL, options: .atomic)) != nil
            }.value
            guard written else { continue }
            var relinked = index.complete
            for (rel, text) in texts {
                guard let renamed = MediaLinks.renaming(text, from: heic.lastPathComponent, to: jpgName) else { continue }
                do {
                    try writeFile(base.appendingPathComponent(rel), renamed, replacing: text)
                    texts[rel] = renamed
                } catch { relinked = false }
            }
            guard relinked else { continue }
            // Parked, not removed: a link this didn't know to rewrite (a
            // template, transfer.md) can still be put right by hand.
            let rel = Self.relativePath(of: heic, under: base)
            try? vault.rename(from: rel, to: recovery + "/" + rel)
            converted += 1
        }
        return converted
    }

    /// Every entry file that mentions a HEIC, with its text, and whether every
    /// file could be read (`complete`).
    nonisolated static func heicLinkIndex(base: URL) -> (texts: [String: String], complete: Bool) {
        let core = CoreJournal(base: base)
        guard let files: [String] = try? core.call("files") else { return ([:], false) }
        var texts: [String: String] = [:]
        var complete = true
        for rel in files {
            guard let text = try? core.text(rel) else { complete = false; continue }
            let lower = text.lowercased()
            if lower.contains(".heic") || lower.contains(".heif") { texts[rel] = text }
        }
        return (texts, complete)
    }

    /// One image, re-encoded smaller in place with its original parked in the
    /// recovery folder. Off the main actor.
    nonisolated static func compressImage(at url: URL, recovery: URL) -> MediaTranscoder.Outcome {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: url) else { return .failed }
        // An animated PNG or a multi-page TIFF would come out as one frame.
        if ImageDownsampler.isMultiFrame(data) { return .noGain }
        guard let shrunk = ImageDownsampler.downsample(data) else { return .failed }
        guard shrunk.count < data.count else { return .noGain }
        let tmp = url.deletingLastPathComponent().appendingPathComponent("._tmp_\(UUID().uuidString).\(url.pathExtension)")
        do {
            try shrunk.write(to: tmp)
            try MediaTranscoder.swap(tmp, into: url, parking: recovery)
            return .saved(data.count - shrunk.count)
        } catch {
            try? fm.removeItem(at: tmp)
            return .failed
        }
    }

    /// Compress existing media (images, video, audio) that no device has processed
    /// yet, in place (same filename/format, so markdown links are untouched),
    /// each original parked in `.quire/media-cleanup/` for `recoveryDays`. The
    /// work runs off the main actor, one file at a time (video/audio through
    /// the serial queue), with `mediaProgress` moving as it goes. Skips anything
    /// already handled elsewhere so nothing is compressed — or counted — twice.
    /// A file is marked handled when it was compressed or when compressing
    /// gained nothing; one that failed (still downloading, unreadable just
    /// now) is left to be tried again.
    @discardableResult
    func compressExistingMedia() async -> MediaCompressionResult {
        guard mediaProgress == nil, let base = baseURL, let core, let dir = assetsDirURL else { return MediaCompressionResult() }
        let sidecar: String
        do { sidecar = try core.sidecar(write: true) }
        catch { lastWriteError = journalErrorMessage(error); return MediaCompressionResult() }
        mediaProgress = (0, 0)
        defer { mediaProgress = nil }
        let recovery = Self.recoveryFolder(sidecar: sidecar, bucket: "datasaver")
        await Task.detached(priority: .utility) { Self.sweepStaleTempFilesNow(under: base) }.value

        var res = MediaCompressionResult()
        res.converted = await convertHEICAssets(recovery: recovery)
        let already = allHandledAssets()
        let candidates = await Task.detached(priority: .utility) {
            Self.listAssets(in: dir).map(\.url).filter { url in
                guard !url.hasDirectoryPath else { return false }
                let ext = url.pathExtension.lowercased()
                let known = ImageDownsampler.compressible.contains(ext)
                    || MediaTranscoder.video.contains(ext) || MediaTranscoder.audio.contains(ext)
                return known && !already.has(key: Self.ledgerKey(assetRelPath: Self.relativePath(of: url, under: base)))
            }
        }.value
        mediaProgress = (0, candidates.count)
        // The ledger is written every so often, not once per file.
        var handled: [String] = []
        var savedSinceFlush = 0
        func flush() {
            recordCompressions(keys: handled, saved: savedSinceFlush)
            handled = []; savedSinceFlush = 0
        }
        for (i, url) in candidates.enumerated() {
            guard baseURL == base else { break }
            let ext = url.pathExtension.lowercased()
            let key = Self.ledgerKey(assetRelPath: Self.relativePath(of: url, under: base))
            let parked = base.appendingPathComponent(recovery + "/" + Self.relativePath(of: url, under: base))
            let isImage = ImageDownsampler.compressible.contains(ext)
            let outcome: MediaTranscoder.Outcome
            if isImage {
                outcome = await Task.detached(priority: .utility) { Self.compressImage(at: url, recovery: parked) }.value
            } else {
                outcome = await MediaTranscodeQueue.shared.run { await MediaTranscoder.compress(url: url, ext: ext, recovery: parked) }
            }
            switch outcome {
            case .saved(let saved):
                if isImage { res.images += 1 } else if MediaTranscoder.video.contains(ext) { res.videos += 1 } else { res.audios += 1 }
                res.bytesSaved += saved
                savedSinceFlush += saved
                handled.append(key)
            case .noGain:
                handled.append(key)
            case .failed:
                res.failed += 1
            }
            mediaProgress = (i + 1, candidates.count)
            if handled.count >= 20 { flush() }
        }
        flush()
        await Task.detached(priority: .utility) { _ = Self.pruneRecovery(base: base) }.value
        if res.failed > 0 {
            lastWriteError = "\(res.failed) media file\(res.failed == 1 ? "" : "s") couldn't be compressed and will be tried again next time."
        }
        lastLocalWriteAt = Date()
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
        return (try? CoreJournal(base: base).inbox().count) ?? 0
    }


    /// Remove leftover `.quire-*.tmp` files from writes that never completed, and
    /// the `._tmp_*` files a Data Saver encode leaves if it is killed part-way.
    /// Age-guarded so an in-flight write from another process (the intents
    /// extension) or an encode still running is never swept out from under it.
    nonisolated static func sweepStaleTempFiles(under base: URL) {
        Task.detached(priority: .background) { sweepStaleTempFilesNow(under: base) }
    }

    nonisolated private static func sweepStaleTempFilesNow(under base: URL) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for case let url as URL in en
        where (url.lastPathComponent.hasPrefix(".quire-") && url.pathExtension == "tmp") || url.lastPathComponent.hasPrefix("._tmp_") {
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
        if coreMutation({ try $0.delete(entry); return true }) == true { entryTouched(entry) }
        publishCoreChange()
    }

    /// Replace a draft's text (from the editor) and persist the inbox. Returns
    /// false when the draft couldn't be found or the write failed.
    @discardableResult
    func updateDraft(_ entry: Entry, newText: String, reindex: Bool = true) -> Bool {
        guard let result = coreMutation(patched: true, { try $0.update(entry, text: newText) }) else { return false }
        lastWritten = result
        patchAfterUpdate(entry, result, source: .inbox)
        publishCoreChange(reindex: reindex)
        return true
    }

    func deleteEditorDraft(_ entry: Entry) -> Bool {
        let ok = coreMutation { try $0.delete(entry); return true } ?? false
        if ok { entryTouched(entry); publishCoreChange() }
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
        guard let result = coreMutation(patched: true, { try $0.update(original, text: newText) }) else { return nil }
        lastWritten = result
        patchAfterUpdate(original, result, source: .archive(date: original.date))
        publishCoreChange(reindex: reindex)
        let date = String((JournalParser.parseEntries(result.raw).first?.ts ?? original.ts).prefix(10))
        return .archive(date: date)
    }

    /// Delete a filed entry from its day file (removes the file if now empty).
    @discardableResult
    func deleteFiledEntry(date: String, entry: Entry) -> Bool {
        let ok = coreMutation { try $0.delete(entry); return true } ?? false
        if ok { entryTouched(entry) }
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

    // MARK: Maintenance off the main actor

    /// One of the long jobs (file everything, transfer.md, conflict copies,
    /// ex-split journals) run off the main actor, on a journal handle of its
    /// own as the index builds and the importer use, so Settings stays live
    /// while it walks the journal. Every write it makes is the core's
    /// compare-and-swap through the coordinated vault, so an autosave landing
    /// beside it is redone, not lost; an editor whose entry the job moved is
    /// refused as stale by the core and keeps its words (the composer's
    /// banner). The caches are marked stale for as long as it runs, and the
    /// inbox and the index are read again when it ends, whatever it did.
    private func maintenance<T: Sendable>(_ work: @escaping @Sendable (CoreJournal) throws -> T) async -> T? {
        guard let base = baseURL else { lastWriteError = "The journal folder is unavailable."; return nil }
        // Nothing reads the caches as the disk's word while files are moving
        // under them.
        unpatchedSeq &+= 1
        let outcome: Result<T, Error> = await Task.detached(priority: .userInitiated) {
            Result { try work(CoreJournal(base: base)) }
        }.value
        // Another folder was chosen meanwhile: this one's result is not its.
        guard baseURL == base else { return nil }
        lastLocalWriteAt = Date()
        mutationSeq &+= 1
        unpatchedSeq &+= 1
        journalDidChange()
        publishCoreChange()
        switch outcome {
        case .success(let value):
            if lastWriteError != nil { lastWriteError = nil }
            return value
        case .failure(let error):
            lastWriteError = journalErrorMessage(error)
            return nil
        }
    }

    private struct FileAllReport: Decodable, Sendable { let filed: Int; let errors: [String] }
    private struct MergeReport: Decodable, Sendable { let journals: Int; let entries: Int; let errors: [String] }

    /// `fileAllDrafts`, off the main actor.
    @discardableResult
    func fileAllDraftsAsync() async -> Int {
        let tags = splitTags
        let report: FileAllReport? = await maintenance { try $0.call("file_all", ["tags": tags]) }
        if let report, !report.errors.isEmpty { lastWriteError = report.errors.joined(separator: "\n") }
        return report?.filed ?? 0
    }

    /// `fileTransfer`, off the main actor.
    @discardableResult
    func fileTransferAsync() async -> Int {
        let tags = splitTags, ts = Self.nowTS()
        let added: Int? = await maintenance { try $0.call("file_transfer", ["ts": ts, "tags": tags]) }
        return added ?? 0
    }

    /// `mergeConflictCopies`, off the main actor. What merged before a copy
    /// that failed still counts, and the failure is said.
    @discardableResult
    func mergeConflictCopiesAsync() async -> Int {
        let done: ConflictMerge? = await maintenance { core in
            var merged = ConflictMerge()
            do {
                let files: [String] = try core.call("conflicts")
                for file in files { let count: Int = try core.call("merge_conflict", ["file": file]); merged.added += count }
            } catch { merged.error = journalErrorMessage(error) }
            return merged
        }
        if let error = done?.error { lastWriteError = error }
        return done?.added ?? 0
    }
    private struct ConflictMerge: Sendable { var added = 0; var error: String? }

    /// `mergeExSplitJournals`, off the main actor.
    @discardableResult
    func mergeExSplitJournalsAsync() async -> MergeResult {
        let tags = splitTags
        let report: MergeReport? = await maintenance { try $0.call("merge", ["tags": tags]) }
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
        /// Takes the folder sizes from another pass, which `measureSizes` fills.
        mutating func copySizes(from other: HeavyStats) {
            journalBytes = other.journalBytes; inboxBytes = other.inboxBytes
            imageBytes = other.imageBytes; videoBytes = other.videoBytes
            audioBytes = other.audioBytes; otherMediaBytes = other.otherMediaBytes
        }
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
    }

    /// Sizes: markdown under the base (minus scratch files), the inbox, and
    /// assets/ split by kind. Stat-only, but a walk of the whole folder: it runs
    /// after the journal is on screen, as only Settings shows it (a third of a
    /// second of the 2.3 the phone took to open the journal, 9 Nov).
    nonisolated static func measureSizes(_ s: inout HeavyStats, base: URL) {
        let fm = FileManager.default
        s.journalBytes = 0; s.imageBytes = 0; s.videoBytes = 0; s.audioBytes = 0; s.otherMediaBytes = 0
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
    /// `expected` is the text the content was worked out from: if the file no
    /// longer reads that way, nothing is written.
    private func writeFile(_ url: URL, _ content: String, replacing expected: String) throws {
        guard let base = baseURL, let core else { throw JournalError.journalUnavailable }
        let prefix = base.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw JournalError.journalUnavailable }
        try core.rewrite(String(url.standardizedFileURL.path.dropFirst(prefix.count)), expected: expected, content)
        lastLocalWriteAt = Date()
        journalDidChange()
    }

    // MARK: Shared-in drafts (share extension handoff)

    /// Where the share extension leaves what it captured: one `share-<id>.md`
    /// per share (older builds appended to a single `pending.md`), each a
    /// jnl-format draft, plus an `assets/` folder of media, inside the App
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
        guard let dir = Self.pendingShareDir, let base = baseURL else { return }
        Self.drainShares(from: dir, into: base, compress: { [weak self] rel in
            self?.scheduleCompression(assetRelPath: rel)
        }, report: { [weak self] message in
            self?.lastWriteError = message
        })
    }

    /// The drain itself, over any two folders so it can be tested.
    ///
    /// Each handoff file is claimed by renaming it to `.processing` *before* it
    /// is read: a share captured between a read and a delete used to land in a
    /// file that was then thrown away. `.processing` files left by a drain that
    /// crashed are picked up too. A claimed file is removed only once its
    /// drafts are in the inbox; one that can't be read is kept for the next
    /// time, never taken for empty and deleted.
    static func drainShares(from dir: URL, into base: URL,
                            compress: (String) -> Void = { _ in },
                            report: (String) -> Void = { _ in },
                            now: Date = Date()) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "md" {
            try? fm.moveItem(at: url, to: dir.appendingPathComponent("\(UUID().uuidString).processing"))
        }
        func captured(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        let claimed = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "processing" }
            .sorted { captured($0) < captured($1) }
        var readable: [URL] = []
        var shared: [Entry] = []
        for url in claimed {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            readable.append(url)
            shared += JournalParser.parseEntries(text)
        }
        // Media first, so the links resolve the moment the drafts appear. A
        // file a draft here links is complete (the draft is written after it);
        // any other may still be being copied in by the extension, so it waits
        // until it has been still for a minute. Media is moved whether or not
        // a draft came with it: left behind once, it used to stay for good.
        let linked = Set(shared.flatMap { MediaLinks.paths(in: $0.raw) }.map { ($0 as NSString).lastPathComponent })
        let pendingAssets = dir.appendingPathComponent("assets", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: pendingAssets, includingPropertiesForKeys: keys), !items.isEmpty {
            let assetsDir = base.appendingPathComponent("assets", isDirectory: true)
            try? fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            for item in items {
                let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard linked.contains(item.lastPathComponent) || now.timeIntervalSince(modified) > 60 else { continue }
                let dest = assetsDir.appendingPathComponent(item.lastPathComponent)
                if (try? fm.moveItem(at: item, to: dest)) != nil {
                    compress("assets/\(item.lastPathComponent)")
                }
            }
        }
        if !shared.isEmpty {
            // An unreadable inbox keeps the claimed files for the next reload
            // rather than being replaced by the shares alone.
            let core = CoreJournal(base: base)
            do {
                for (date, entries) in Dictionary(grouping: shared, by: \.date) {
                    let _: Int = try core.call("insert", ["file": "inbox/" + date.replacingOccurrences(of: "-", with: "/") + ".md", "raws": entries.map(\.raw)])
                }
            } catch { report(journalErrorMessage(error)); return }
        }
        for url in readable { try? fm.removeItem(at: url) }
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

    /// Where a new attachment goes (assets/YYYY/MM), for the importers.
    var newAssetsDirectory: URL? { newAssetsDirURL }

    func setImportProgress(_ p: (done: Int, total: Int)?) {
        importProgress = p
    }

    /// After an import ran off the main actor: its Data Saver savings go in
    /// the ledger, its videos are queued for compression, and the journal is
    /// read again.
    func noteImported(compressed: [String], saved: Int, transcode: [String], reload: Bool) {
        recordCompressions(keys: compressed, saved: saved)
        for rel in transcode { scheduleCompression(assetRelPath: rel) }
        guard reload else { return }
        lastLocalWriteAt = Date()
        mutationSeq &+= 1
        unpatchedSeq &+= 1
        journalDidChange()
        self.reload()
    }

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
    func rewriteContentFile(_ url: URL, _ content: String, replacing expected: String) -> Bool {
        do { try writeFile(url, content, replacing: expected); return true }
        catch { lastWriteError = journalErrorMessage(error); return false }
    }

    /// Maintenance progress for extensions that batch over media (mediaProgress
    /// is otherwise settable only from this file).
    func setMediaProgress(_ p: (done: Int, total: Int)?) {
        mediaProgress = p
    }

    // MARK: On This Day

    /// Filed entries from this calendar day in previous years, newest year
    /// first. From the index in memory once there is one; before that the
    /// matching days are read through the core, one whole-journal read each.
    func onThisDay(reference: Date = Date()) -> [(date: String, entries: [Entry])] {
        let iso = Self.ts(from: reference).prefix(10)
        let monthDay = String(iso.suffix(5))
        let thisYear = String(iso.prefix(4))
        if indexed {
            // `archiveEntries` is newest day first, and holds no empty days.
            return archiveEntries.filter { $0.date.hasSuffix(monthDay) && String($0.date.prefix(4)) < thisYear }
        }
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
    ///
    /// What the watcher says is only that something moved. Whether to read the
    /// journal again is decided off the main actor, from each file's size and
    /// date: nothing is reloaded unless a file other than the ones this app
    /// just wrote has changed, or iCloud holds a conflicting version of one.
    /// An autosave used to come back as a conflict scan and a full reload.
    private func scheduleSyncReload(after delay: TimeInterval = 1.5) {
        syncReloadTask?.cancel()
        syncReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, let base = self.baseURL else { return }
            let now = Date()
            // The first index is still being read (the query's first gathering
            // lands about now on a cold launch): reading it all again would
            // double the time to open, so look once it is in.
            if !self.indexed, now.timeIntervalSince(self.reloadStartedAt) < 120 {
                self.scheduleSyncReload(after: 2)
                return
            }
            // Our own write, echoing straight back through the watcher. Skip
            // it — but not forever: continuous autosave keeps every check
            // inside the echo window, so a check is let through once the
            // session has gone `syncStarvationCeiling` without one, and a
            // change from another device can't wait out the whole session.
            if now.timeIntervalSince(self.lastLocalWriteAt) < 2,
               now.timeIntervalSince(self.lastSyncCheckAt) < Self.syncStarvationCeiling {
                self.scheduleSyncReload(after: 2)
                return
            }
            self.lastSyncCheckAt = now
            let found = await Task.detached(priority: .utility) {
                (signatures: Self.contentSignatures(base: base), conflicted: Self.filesWithConflicts(base: base, splits: []))
            }.value
            guard !Task.isCancelled, self.baseURL == base else { return }
            let elsewhere = self.changedElsewhere(found.signatures)
            guard elsewhere || !found.conflicted.isEmpty else { return }
            for url in found.conflicted { self.resolveConflicts(at: url) }
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
    /// main actor (`scheduleSyncReload`); only the merge itself (which rewrites
    /// files and touches the caches) comes back. This used to enumerate every
    /// day file and ask `NSFileVersion` about each one on the main actor —
    /// ~200 ms of stall on a journal of a few thousand entries, every time the
    /// watcher fired.
    ///
    /// This is the finding: the subset of journal files carrying unresolved
    /// iCloud conflicts.
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

    /// More than one image in the file: an animated PNG, a multi-page TIFF.
    /// Re-encoding keeps only the first, so these are left as they are.
    static func isMultiFrame(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// Downsample to `maxPixel` on the longest edge and re-encode in the same
    /// format at `quality` (lossy formats only). Returns nil if not a decodable
    /// image, if it holds more than one frame, or on failure — callers keep
    /// the original bytes in that case.
    static func downsample(_ data: Data, maxPixel: Int = 2048, quality: Double = 0.7) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) == 1,
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

    /// What became of one file. Only `saved` and `noGain` are final: a file
    /// that `failed` (unreadable just now, an export that didn't finish) is
    /// worth another try, so it must not be recorded as dealt with.
    enum Outcome: Sendable, Equatable { case saved(Int), noGain, failed }

    /// Transcode `url` to a temp file and, if the result is smaller, atomically swap
    /// it in place. Returns bytes saved, or nil if skipped / no gain / failure.
    static func compressInPlace(url: URL, ext: String) async -> Int? {
        if case .saved(let saved) = await compress(url: url, ext: ext, recovery: nil) { return saved }
        return nil
    }

    /// Transcode `url` to a temp file and, if the result is smaller, swap it in
    /// place, moving the original to `recovery` first (the recovery folder's
    /// path for it) so the re-encode can be undone.
    static func compress(url: URL, ext: String, recovery: URL?) async -> Outcome {
        let fm = FileManager.default
        guard let originalSize = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, originalSize > 0
        else { return .failed }
        guard video.contains(ext) || audio.contains(ext) else { return .noGain }
        let tmp = url.deletingLastPathComponent().appendingPathComponent("._tmp_\(UUID().uuidString).\(ext)")
        let ok: Bool
        if video.contains(ext) {
            ok = await transcodeVideo(from: url, to: tmp, as: fileType(forExt: ext) ?? .mov)
        } else {
            ok = await transcodeAudio(from: url, to: tmp)
        }
        guard ok, let newSize = try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int else {
            try? fm.removeItem(at: tmp)
            return .failed
        }
        guard newSize < originalSize else {
            try? fm.removeItem(at: tmp)
            return .noGain
        }
        do {
            try swap(tmp, into: url, parking: recovery)
            return .saved(originalSize - newSize)
        } catch {
            try? fm.removeItem(at: tmp)
            return .failed
        }
    }

    /// Put `tmp` where `url` is. With `recovery`, the original is moved there
    /// first and put back if the new file can't be moved in; without, it is
    /// replaced. Coordinated either way, so the swap can't race an iCloud sync
    /// of the same file (the coordinator serialises us against any
    /// presenter/daemon writer).
    static func swap(_ tmp: URL, into url: URL, parking recovery: URL?) throws {
        let fm = FileManager.default
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        if let recovery {
            try fm.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
            coordinator.coordinate(writingItemAt: url, options: .forMoving,
                                   writingItemAt: recovery, options: .forReplacing, error: &coordinationError) { original, parked in
                result = Result {
                    try fm.moveItem(at: original, to: parked)
                    do { try fm.moveItem(at: tmp, to: original) }
                    catch {
                        try? fm.moveItem(at: parked, to: original)
                        throw error
                    }
                }
            }
        } else {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { dest in
                result = Result { _ = try fm.replaceItemAt(dest, withItemAt: tmp) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
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

extension Notification.Name {
    /// The app lock was switched on or off (AppLockManager posts it).
    static let quireAppLockChanged = Notification.Name("com.caddickbrown.quire.appLockChanged")
}
