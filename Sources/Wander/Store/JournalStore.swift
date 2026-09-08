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

@MainActor
final class JournalStore: ObservableObject {

    enum SaveState: Equatable {
        case idle
        case editing
        case saved(Date)
        case failed(String)
    }

    @Published private(set) var entries: [Entry] = []      // newest first
    @Published var selection: Entry.ID?
    @Published var query: String = ""
    @Published private(set) var page: Page = .journal
    @Published private(set) var saveState: SaveState = .idle
    @Published private(set) var library: JournalLibrary

    /// The live text of the selected entry. The editor binds straight to these;
    /// they are folded back into `entries` (and the file) on the debounced save.
    @Published var draftTitle: String = ""
    @Published var draftBody: String = ""

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

    private static let folderKey = "journalFolderPath"

    var baseURL: URL { library.baseURL }

    // MARK: Lifecycle

    init() {
        library = JournalLibrary(
            baseURL: JournalLibrary.resolveBase(
                preferred: UserDefaults.standard.string(forKey: Self.folderKey)))
        library.ensureFolders()
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
        guard !dirty else { return }
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

    var selectedEntry: Entry? { entries.first { $0.id == selection } }

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
        saveState = .editing
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
            lastFingerprint = library.fingerprint()
        } catch {
            dirty = true
            saveState = .failed(error.localizedDescription)
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
            lastFingerprint = library.fingerprint()
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

    var selectedIsUnfiled: Bool { selectedEntry.map(isUnfiled) ?? false }

    func destinationName(for entry: Entry, at date: Date) -> String {
        library.destinationName(for: entry, on: Formats.day.string(from: date))
    }

    // MARK: Commands

    func newEntry() {
        flush()
        if page == .inbox { page = .journal }
        let entry = Entry.blank()
        entries.insert(entry, at: 0)
        openFresh(entry)
    }

    /// A draft: same as a new entry, but destined for inbox.md rather than a day
    /// file, so unfinished writing doesn't land in the dated record.
    func newDraft() {
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
        lastFingerprint = library.fingerprint()
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
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        library = JournalLibrary(baseURL: url)
        library.ensureFolders()
        draftEntry = nil
        selection = nil
        reload()
        select(firstVisibleID)
    }

    // MARK: Derived

    var filtered: [Entry] {
        entries.filter { JournalIndex.matches($0, query: query) }
    }

    /// Sidebar sections for the current page. The journal and the starred cut
    /// are set by month; the inbox is one undated run, because inbox.md is.
    var sections: [(title: String, entries: [Entry], inbox: Bool)] {
        switch page {
        case .journal:
            return JournalIndex.months(of: filtered.filter { !isUnfiled($0) })
                .map { ($0.title, $0.entries, false) }
        case .inbox:
            let drafts = filtered.filter(isUnfiled)
            return drafts.isEmpty ? [] : [("Inbox", drafts, true)]
        case .starred:
            return JournalIndex.months(of: filtered.filter(\.isStarred))
                .map { ($0.title, $0.entries, false) }
        }
    }

    /// Badge count for the masthead's page switches.
    func count(of page: Page) -> Int {
        switch page {
        case .journal: return entries.filter { !isUnfiled($0) }.count
        case .inbox:   return entries.filter(isUnfiled).count
        case .starred: return entries.filter(\.isStarred).count
        }
    }

    /// Days that already hold at least one entry — the calendar dots them.
    var datesWithEntries: Set<String> { Set(entries.map(\.date)) }

    var totalWords: Int { entries.reduce(0) { $0 + $1.wordCount } }

    var entriesThisMonth: Int {
        let prefix = String(Formats.day.string(from: Date()).prefix(7))
        return entries.filter { $0.date.hasPrefix(prefix) }.count
    }

    var streak: Int { JournalIndex.streak(of: entries) }

    /// Position of the selected entry in the whole journal, oldest = 1 — the
    /// masthead's "No. 014".
    var selectedNumber: Int? {
        guard let selection, let index = entries.firstIndex(where: { $0.id == selection })
        else { return nil }
        return entries.count - index
    }
}
