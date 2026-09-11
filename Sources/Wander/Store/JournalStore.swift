//
//  JournalStore.swift
//  Wander
//
//  The observable layer over `JournalLibrary`: what is selected, what is being
//  typed, which page is showing, and when the draft gets written back. All of
//  the file work lives in WanderCore; this is the part SwiftUI watches.
//

import Foundation
import SwiftUI
import WanderCore

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The text being typed, held apart from the store on purpose.
///
/// Everything the index, the masthead and the stats column read is derived from
/// the whole journal, so publishing a keystroke from the store rebuilt all of
/// it — thousands of entries regrouped and recounted per character. Only the
/// editor and the live counts watch a `Draft`, so typing costs what typing
/// should; the store hears about it once, on the debounced save.
@MainActor
final class Draft: ObservableObject {
    @Published var title: String = ""
    @Published var body: String = ""
}

@MainActor
final class JournalStore: ObservableObject {

    enum SaveState: Equatable {
        case idle
        case editing
        case saved(Date)
        case failed(String)
    }

    /// One section of the index: a month of the journal, or the whole inbox.
    struct Section: Identifiable {
        let title: String
        /// A slice of the page's entries, not a copy of them.
        let entries: ArraySlice<Entry>
        let inbox: Bool
        var id: String { title }
    }

    @Published private(set) var entries: [Entry] = [] {      // newest first
        didSet { rebuildIndex() }
    }
    @Published var selection: Entry.ID? {
        didSet { if selection != oldValue { rebuildSelection() } }
    }
    @Published var query: String = "" {
        didSet { if query != oldValue { rebuildIndex() } }
    }
    /// Remembered across launches: reopening on the inbox you left open is the
    /// behaviour a shelf of notebooks has.
    @Published private(set) var page: Page = .journal {
        didSet {
            UserDefaults.standard.set(page.rawValue, forKey: Self.pageKey)
            if page != oldValue { rebuildIndex() }
        }
    }
    @Published private(set) var saveState: SaveState = .idle
    @Published private(set) var library: JournalLibrary

    /// The live text of the selected entry. The editor binds straight to the
    /// draft; it is folded back into `entries` (and the file) on the debounced
    /// save.
    let draft = Draft()

    var draftTitle: String {
        get { draft.title }
        set { draft.title = newValue }
    }

    var draftBody: String {
        get { draft.body }
        set { draft.body = newValue }
    }

    // MARK: Derived state
    //
    // Held rather than computed. Each of these walks the whole journal, and a
    // SwiftUI body reads several of them several times over; recomputing on
    // every read is what made a keystroke cost a third of a second. They are
    // refreshed together whenever the entries, the query or the page changes —
    // which is to say when the answer can actually have changed.

    /// Sidebar sections for the current page. The journal and the starred cut
    /// are set by month; the inbox is one undated run, because inbox.md is.
    @Published private(set) var sections: [Section] = []
    @Published private(set) var selectedEntry: Entry?
    @Published private(set) var selectedIsUnfiled = false
    /// Position of the selected entry in the whole journal, oldest = 1 — the
    /// masthead's "No. 014".
    @Published private(set) var selectedNumber: Int?
    @Published private(set) var totalWords = 0
    @Published private(set) var entriesThisMonth = 0
    @Published private(set) var streak = 0
    /// Days that already hold at least one entry — the calendar dots them.
    @Published private(set) var datesWithEntries: Set<String> = []
    private var pageCounts: [Page: Int] = [:]

    /// Badge count for the masthead's page switches.
    func count(of page: Page) -> Int { pageCounts[page] ?? 0 }

    /// Bumped to ask the index to take keyboard focus (⌘F).
    @Published var searchFocusRequest: Int = 0
    /// The entry a delete has been asked for; the window confirms before it goes.
    @Published var deletionCandidate: Entry?
    /// The entry whose date and time are being changed, if the sheet is open.
    @Published var reschedulingEntry: Entry?

    private var draftEntry: Entry?
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var lastFingerprint = ""
    /// Guards against a slow fingerprint landing after a newer one.
    private var fingerprintToken = 0
    private var fingerprintPending = false

    private static let folderKey = "journalFolderPath"
    private static let bookmarkKey = "journalFolderBookmark"
    private static let pageKey = "page"

    /// Held for as long as the app uses a folder the user picked, so the grant
    /// stays open. Only meaningful under the sandbox; harmless without it.
    private var scopedURL: URL?

    var baseURL: URL { library.baseURL }

    // MARK: Lifecycle

    init() {
        library = JournalLibrary(baseURL: JournalLibrary.resolveBase(preferred: nil))
        // A remembered folder is reached through its bookmark, not its path: a
        // path alone stops working the moment the app is sandboxed, and breaks
        // anyway if the folder is moved or renamed.
        if let remembered = Self.resolveRememberedFolder() {
            scopedURL = remembered.scoped ? remembered.url : nil
            library = JournalLibrary(baseURL: remembered.url)
        }
        library.ensureFolders()
        if let saved = UserDefaults.standard.string(forKey: Self.pageKey),
           let remembered = Page(rawValue: saved) {
            page = remembered
        }
        reload()
        select(firstVisibleID)
    }

    /// The first entry on the page being shown — what to fall back to whenever a
    /// selection is lost, so the editor never holds an entry the index isn't
    /// listing.
    private var firstVisibleID: Entry.ID? { sections.flatMap(\.entries).first?.id }

    // MARK: Loading

    func reload() {
        entries = library.load()
        lastFingerprint = library.fingerprint()

        // An unsaved new entry lives only in memory until it has text; keep it.
        if let draft = draftEntry, draft.source == nil,
           !entries.contains(where: { $0.id == draft.id }) {
            entries.insert(draft, at: 0)
        }
        if let selection, !entries.contains(where: { $0.id == selection }) {
            select(firstVisibleID)
        }
    }

    /// Skip the re-read when nothing on disk has changed — an edit made in jnl
    /// or Nook while Wander was in the background still shows up on activation.
    func reloadIfChanged() {
        // A write of our own may not have been fingerprinted yet; re-reading on
        // the strength of a stale one would be a reload for nothing.
        guard !dirty, !fingerprintPending else { return }
        let current = library.fingerprint()
        guard current != lastFingerprint else { return }
        let keep = selection
        reload()
        if let keep, entries.contains(where: { $0.id == keep }) { select(keep) }
    }

    // MARK: Selection and drafts

    func select(_ id: Entry.ID?) {
        guard id != selection || draftEntry == nil else { return }
        flush()
        selection = id
        let entry = entries.first { $0.id == id }
        draftEntry = entry
        draftTitle = entry?.displayTitle ?? ""
        draftBody = entry?.body ?? ""
        dirty = false
        saveState = .idle
    }

    /// Switch page, keeping the open entry if it belongs there.
    func show(_ page: Page) {
        guard page != self.page else { return }
        self.page = page
        let visible = sections.flatMap(\.entries)
        if let selection, visible.contains(where: { $0.id == selection }) { return }
        select(visible.first?.id)
    }

    /// Called by the editor on every keystroke; the write itself is debounced.
    /// The draft is compared against the entry rather than trusted, because
    /// loading a different entry also changes the bound text — an edit is only
    /// an edit when the text differs from what is filed.
    func edited() {
        guard let base = draftEntry else { return }
        guard draftTitle != base.displayTitle || draftBody != base.body else {
            saveTask?.cancel()
            dirty = false
            if saveState == .editing { saveState = .idle }
            return
        }
        dirty = true
        // Only on the transition. `@Published` fires on assignment, not on
        // change, and a keystroke that republished the store from here undid
        // the point of keeping the draft separate.
        if saveState != .editing { saveState = .editing }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Fold the draft back into the entry and rewrite its file.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty, let base = draftEntry else { return }
        dirty = false

        let revised = base.revised(title: draftTitle, body: draftBody)
        let isEmpty = revised.suffix.isEmpty && revised.body.isEmpty

        // Trailing whitespace alone can't cost a file rewrite.
        if revised.raw == base.raw, base.source != nil {
            saveState = .saved(Date())
            return
        }

        do {
            if isEmpty {
                // Never leave an empty stub on disk. If it was written earlier
                // (title typed, then deleted), take it back out of the file.
                if base.source != nil { try library.remove(base) }
                var carried = revised
                carried.source = nil
                replaceInMemory(base, with: carried)
                saveState = .idle
            } else {
                let written = try library.persist(revised, previous: base)
                replaceInMemory(base, with: written)
                saveState = .saved(Date())
            }
            refreshFingerprint()
        } catch {
            dirty = true
            saveState = .failed(error.localizedDescription)
        }
    }

    /// Re-take the folder's fingerprint after a write of our own, off the main
    /// actor: it stats every file in the journal, and a save happens while the
    /// writing carries on.
    private func refreshFingerprint() {
        fingerprintToken += 1
        fingerprintPending = true
        let token = fingerprintToken
        let library = self.library
        Task.detached(priority: .utility) {
            let taken = library.fingerprint()
            await MainActor.run { [weak self] in
                guard let self, self.fingerprintToken == token else { return }
                self.lastFingerprint = taken
                self.fingerprintPending = false
            }
        }
    }

    private func replaceInMemory(_ old: Entry, with new: Entry) {
        if let index = entries.firstIndex(where: { $0.id == old.id }) {
            entries[index] = new
        } else {
            entries.insert(new, at: 0)
        }
        draftEntry = new
        if selection == old.id { selection = new.id }
    }

    // MARK: Moving between files

    /// Move an entry to `target` under the timestamp `desired` — the one
    /// primitive behind retiming, filing and unfiling.
    @discardableResult
    private func move(_ current: Entry, to target: URL, stamp desired: String) -> Bool {
        let stamp = library.freeStamp(desired, in: target, excluding: current)
        var head = "[\(stamp)]"
        if !current.suffix.isEmpty { head += " " + current.suffix }
        let moved = Entry(date: String(stamp.prefix(10)), ts: stamp,
                          suffix: current.suffix, body: current.body,
                          raw: current.body.isEmpty ? head : head + "\n" + current.body,
                          source: target)
        do {
            try library.remove(current)
            // An entry with neither title nor body is never written — moving an
            // untouched new entry to another day must not leave a stub behind.
            let blank = moved.suffix.isEmpty && moved.body.isEmpty
            var written = moved
            if blank {
                written.source = nil
            } else {
                written = try library.persist(moved, previous: nil)
            }
            entries.removeAll { $0.id == current.id }
            entries.append(written)
            entries = JournalParser.sortedByTimestamp(entries).reversed()
            selection = written.id
            draftEntry = written
            draftTitle = written.displayTitle
            draftBody = written.body
            dirty = false
            saveState = blank ? .idle : .saved(Date())
            refreshFingerprint()
            return true
        } catch {
            saveState = .failed(error.localizedDescription)
            return false
        }
    }

    /// Change an entry's timestamp. For a filed entry the date is the filename,
    /// so this moves it between day files. A draft stays in inbox.md, which
    /// isn't dated — retiming there must not quietly file it.
    func reschedule(_ entry: Entry, to date: Date) {
        flush()
        let current = entries.first { $0.id == entry.id } ?? entry
        let stamp = Formats.stamp.string(from: date)
        guard stamp != current.ts else { return }
        guard let target = isUnfiled(current)
                ? library.inboxURL
                : library.dayFile(for: String(stamp.prefix(10))) else { return }
        move(current, to: target, stamp: stamp)
    }

    /// Draft ▸ journal: inbox.md into journal/YYYY/MM/DD.md, by its own date.
    func file(_ entry: Entry) {
        flush()
        let current = entries.first { $0.id == entry.id } ?? entry
        guard let target = library.dayFile(for: current.date) else { return }
        move(current, to: target, stamp: current.ts)
    }

    /// Journal ▸ draft: back to inbox.md, to be worked on and filed again.
    func unfile(_ entry: Entry) {
        flush()
        let current = entries.first { $0.id == entry.id } ?? entry
        guard !isUnfiled(current) else { return }
        move(current, to: library.inboxURL, stamp: current.ts)
    }

    /// Toggle whichever way the entry sits, and follow it to the page it now
    /// lives on so the open entry doesn't vanish from the index.
    func toggleFiling(_ entry: Entry) {
        let wasUnfiled = isUnfiled(entry)
        wasUnfiled ? file(entry) : unfile(entry)
        if page == .journal && !wasUnfiled { page = .inbox }
        else if page == .inbox && wasUnfiled { page = .journal }
    }

    func isUnfiled(_ entry: Entry) -> Bool {
        entry.source == nil ? false : library.isUnfiled(entry)
    }

    func destinationName(for entry: Entry, at date: Date) -> String {
        library.destinationName(for: entry, on: Formats.day.string(from: date))
    }

    // MARK: Commands

    /// Start writing. New work goes to `inbox.md`, not into the dated record:
    /// what you have just begun is rarely ready to belong to a day, and filing
    /// it later (⌘J) is one keystroke. There is no second way to start — an
    /// entry that should be dated is written here and then filed.
    func newEntry() {
        flush()
        page = .inbox
        var entry = Entry.blank()
        entry.source = library.inboxURL
        entries.insert(entry, at: 0)
        openFresh(entry)
    }

    private func openFresh(_ entry: Entry) {
        selection = entry.id
        draftEntry = entry
        draftTitle = ""
        draftBody = ""
        dirty = false
        saveState = .idle
    }

    func delete(_ entry: Entry) {
        saveTask?.cancel()
        dirty = false
        try? library.remove(entry)
        entries.removeAll { $0.id == entry.id }
        if selection == entry.id {
            draftEntry = nil
            select(firstVisibleID)
        }
        refreshFingerprint()
    }

    func toggleStar(_ entry: Entry) {
        let flipped = entry.revised(title: entry.displayTitle,
                                    body: entry.body,
                                    starred: !entry.isStarred)
        guard !flipped.suffix.isEmpty || !flipped.body.isEmpty else { return }
        if let written = try? library.persist(flipped, previous: entry) {
            replaceInMemory(entry, with: written)
            if selection == written.id { draftEntry = written }
            saveState = .saved(Date())
        }
    }

    func toggleStarOnSelection() {
        flush()
        guard let entry = selectedEntry else { return }
        toggleStar(entry)
    }

    /// Move the selection through the index: -1 newer, +1 older.
    func step(_ delta: Int) {
        let list = sections.flatMap(\.entries)
        guard !list.isEmpty else { return }
        guard let current = list.firstIndex(where: { $0.id == selection }) else {
            return select(list.first?.id)
        }
        select(list[min(max(current + delta, 0), list.count - 1)].id)
    }

    /// Copy an entry's markdown — header line included, so it can be pasted
    /// straight into another jnl file.
    func copyMarkdown(_ entry: Entry) {
        flush()
        let current = entries.first { $0.id == entry.id } ?? entry
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current.raw, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = current.raw
        #endif
    }

    // MARK: Folder

    #if os(macOS)
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a journal folder — a Nook or jnl folder works as-is."
        panel.directoryURL = baseURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(url)
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([baseURL])
    }

    func reveal(_ entry: Entry) {
        flush()
        guard let url = (entries.first { $0.id == entry.id } ?? entry).source else {
            return revealFolder()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    func adopt(_ url: URL) {
        flush()
        // Access first, then bookmark: a folder handed over by the iOS document
        // picker isn't readable — and can't be bookmarked — until the grant is
        // open.
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        if let bookmark = Self.makeBookmark(for: url) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        library = JournalLibrary(baseURL: url)
        library.ensureFolders()
        draftEntry = nil
        selection = nil
        reload()
        select(firstVisibleID)
    }

    // MARK: Remembering the folder

    /// Security-scoped where the platform allows it, plain otherwise — a
    /// non-sandboxed app can't always mint a scoped bookmark, and doesn't need
    /// one.
    private static func makeBookmark(for url: URL) -> Data? {
        #if os(macOS)
        if let scoped = try? url.bookmarkData(options: .withSecurityScope,
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil) {
            return scoped
        }
        #endif
        return try? url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The folder the user last chose, resolved from its bookmark. A stale
    /// bookmark still resolves, but only for now — it is re-minted so a moved
    /// or renamed folder doesn't become unreachable on some later launch.
    private static func resolveRememberedFolder() -> (url: URL, scoped: Bool)? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            if let url = try? URL(resolvingBookmarkData: data, options: options,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let scoped = url.startAccessingSecurityScopedResource()
                if stale, let fresh = makeBookmark(for: url) {
                    defaults.set(fresh, forKey: bookmarkKey)
                }
                defaults.set(url.path, forKey: folderKey)
                return (url, scoped)
            }
        }
        // Nothing bookmarked: fall back to a remembered path, which is how
        // folders chosen before bookmarks existed were stored.
        if let path = defaults.string(forKey: folderKey),
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if let bookmark = makeBookmark(for: url) { defaults.set(bookmark, forKey: bookmarkKey) }
            return (url, false)
        }
        return nil
    }

    // MARK: Derived

    /// Recompute everything the index and the panels read. One pass over the
    /// journal, on the changes that can move the answer: a reload, an edit
    /// folded back in, a new search, a different page.
    private func rebuildIndex() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = needle.isEmpty
            ? entries
            : entries.filter { $0.raw.lowercased().contains(needle) }

        var journal: [Entry] = []
        var inbox: [Entry] = []
        var starred: [Entry] = []
        var days = Set<String>()
        var words = 0
        for entry in visible {
            if library.isUnfiled(entry) { inbox.append(entry) } else { journal.append(entry) }
            if entry.isStarred { starred.append(entry) }
        }
        for entry in entries {
            days.insert(entry.date)
            words += entry.wordCount
        }

        switch page {
        case .journal:
            sections = JournalIndex.months(of: journal)
                .map { Section(title: $0.title, entries: $0.entries, inbox: false) }
        case .inbox:
            sections = inbox.isEmpty ? [] : [Section(title: "Inbox", entries: inbox[...], inbox: true)]
        case .starred:
            sections = JournalIndex.months(of: starred)
                .map { Section(title: $0.title, entries: $0.entries, inbox: false) }
        }

        // The badges count the whole journal, not the search — a filtered count
        // beside "Inbox" would read as the queue having emptied.
        if needle.isEmpty {
            pageCounts = [.journal: journal.count, .inbox: inbox.count, .starred: starred.count]
        } else {
            var counts: [Page: Int] = [.journal: 0, .inbox: 0, .starred: 0]
            for entry in entries {
                if library.isUnfiled(entry) { counts[.inbox]! += 1 } else { counts[.journal]! += 1 }
                if entry.isStarred { counts[.starred]! += 1 }
            }
            pageCounts = counts
        }

        datesWithEntries = days
        totalWords = words
        streak = JournalIndex.streak(of: entries)
        let month = String(Formats.day.string(from: Date()).prefix(7))
        entriesThisMonth = entries.reduce(0) { $0 + ($1.date.hasPrefix(month) ? 1 : 0) }
        rebuildSelection()
    }

    /// The three things that follow the selection rather than the journal.
    private func rebuildSelection() {
        guard let selection, let index = entries.firstIndex(where: { $0.id == selection }) else {
            selectedEntry = nil
            selectedIsUnfiled = false
            selectedNumber = nil
            return
        }
        let entry = entries[index]
        selectedEntry = entry
        selectedIsUnfiled = library.isUnfiled(entry)
        selectedNumber = entries.count - index
    }
}
