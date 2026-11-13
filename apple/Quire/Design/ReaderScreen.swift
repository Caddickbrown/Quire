//
//  ReaderScreen.swift
//  Quire
//
//  One entry, set as a page. Actions are icons along the top; the text gets the
//  measure and the leading it deserves.
//

#if os(iOS)

import SwiftUI
import UIKit

struct ReaderScreen: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q
    @Environment(\.dismiss) private var dismiss
    /// Settings → Text size (16–26); the body is set two points above it.
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)

    let ref: EntryRef
    var onEdit: (EntryRef) -> Void
    var onRetime: (EntryRef) -> Void
    /// `t` from the keyboard, which may change the date on the monitor instead.
    var onRetimeKey: ((EntryRef) -> Void)?
    /// Set when the page sits beside the list (regular width) rather than pushed
    /// over it: leaving clears the selection instead of popping the stack.
    var onClose: (() -> Void)?

    @State private var entry: Entry
    @State private var confirmDelete = false
    @State private var routerID = UUID()
    @State private var visible = false
    @State private var scroller = QScrollHandle()
    /// The body as blocks, kept until the body changes (see `Parsed`).
    @State private var parsed = Parsed()

    init(ref: EntryRef, onEdit: @escaping (EntryRef) -> Void, onRetime: @escaping (EntryRef) -> Void,
         onRetimeKey: ((EntryRef) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.ref = ref
        self.onEdit = onEdit
        self.onRetime = onRetime
        self.onRetimeKey = onRetimeKey
        self.onClose = onClose
        _entry = State(initialValue: ref.entry)
    }

    private var current: EntryRef { EntryRef(entry: entry, source: ref.source) }
    private var isDraft: Bool { ref.source == .inbox }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(QMarkdown.emphasis(q.caps(entry.qHasTitle ? entry.displayTitle : "Untitled")))
                        .font(q.isMarathon ? q.display(30) : q.writing(34, weight: .medium, italic: !entry.qHasTitle))
                        .foregroundStyle(entry.qHasTitle ? q.inkColor : q.mutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                    QTitleRule().qDrawIn()
                    ForEach(Array(parsed.blocks(of: entry.shownBody).enumerated()), id: \.offset) { _, block in blockView(block) }
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26).padding(.top, 12).padding(.bottom, 40)
                .background(QScrollAttach(handle: scroller))
            }
        }
        .background(q.pageColor)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: ref) { _, new in entry = new.entry; mirror() }
        .onChange(of: store.revision) { _, _ in refresh(); mirror() }
        .onAppear { visible = true; mirror(); registerKeys() }
        .onDisappear {
            visible = false
            DeskConfirm.shared.cancel(owner: routerID)
            ExternalDisplayModel.shared.releasePage(owner: routerID)
            KeyCommandRouter.shared.unregister(routerID)
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        }
        .qKeyBlocker(active: confirmDelete, onEscape: { confirmDelete = false })
    }

    // MARK: Actions

    private var actionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Beside the list there is nothing to go back to.
                if onClose == nil { QLink(title: "‹ Back") { close() } }
                Spacer()
                action(entry.isStarred ? "star.fill" : "star", entry.isStarred ? "Starred" : "Star",
                       color: entry.isStarred ? q.accentColor : q.mutedColor) {
                    store.toggleStar(entry, source: ref.source); refresh()
                }
                if isDraft {
                    action("archivebox", "File", color: q.accentColor, bold: true) { store.fileDraft(entry); close() }
                } else {
                    action("tray.and.arrow.up", "Return to inbox", color: q.mutedColor) {
                        _ = store.returnToInbox(entry, source: ref.source); close()
                    }
                }
                action("trash", "Delete", color: .red) { askDelete() }
                action("pencil", "Edit", color: q.inkColor, bold: true) { onEdit(current) }
            }
            .padding(.horizontal, 20)
            Button { onRetime(current) } label: {
                Text("\(QDate.fullDay(entry.date)), \(QDate.time(entry.ts))")
                    .font(q.ui(13)).foregroundStyle(q.inkColor)
                    .underline(pattern: .dot)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 36)
                    .padding(.horizontal, 26)
            }
            .buttonStyle(.plain)
            QRule()
        }
    }

    /// A plain icon, as in the masthead: no bubble, a 44pt target, the word as
    /// its accessibility label. Accent still marks File; Edit is the heavier one.
    private func action(_ symbol: String, _ label: String, color: Color, bold: Bool = false,
                        _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 18, weight: bold ? .semibold : .regular))
                .foregroundStyle(color)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Show the entry on a connected monitor while it is open.
    private func mirror() {
        guard visible else { return }
        ExternalDisplayModel.shared.present(.reading(
            title: entry.displayTitle, date: QDate.date(entry.ts) ?? Date(), text: entry.shownBody, isStarred: entry.isStarred,
            isDraft: isDraft), owner: routerID)
    }

    /// The page here and its twin on the monitor, together.
    private func scroll(_ direction: Int) {
        scroller.step(direction)
        ExternalDisplayModel.shared.pageScroll.step(direction)
    }

    /// The terminal app's keys for an open entry: ↑/↓ or j/k scroll, e edit, * star,
    /// f file, u return to the inbox, t date and time, d delete, Esc back to the list
    /// it came from, with or without a monitor. The list keeps its selection, and its
    /// own Esc goes on to Today.
    private func registerKeys() {
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: { scroll(-1) }, moveDown: { scroll(1) }, open: {},
            clear: { close() },
            key: { k in
                switch k {
                case "j": scroll(1); return true
                case "k": scroll(-1); return true
                case "e": onEdit(current); return true
                case "*": store.toggleStar(entry, source: ref.source); refresh(); return true
                case "f": if isDraft { store.fileDraft(entry); close() }; return isDraft
                case "u": if !isDraft { _ = store.returnToInbox(entry, source: ref.source); close() }; return !isDraft
                case "t": (onRetimeKey ?? onRetime)(current); return true
                case "d": askDelete(); return true
                default: return false
                }
            }))
    }

    /// On the monitor in desk mode, where the keyboard can answer; the phone's
    /// dialog otherwise.
    private func askDelete() {
        let asked = DeskConfirm.shared.ask(.init(kicker: isDraft ? "Draft" : "Entry",
                                                 question: isDraft ? "Delete this draft?" : "Delete this entry?",
                                                 detail: DeskConfirm.describe(entry), when: DeskConfirm.when(entry),
                                                 action: "Delete"), owner: routerID) {
            delete(); return nil
        }
        if !asked { confirmDelete = true }
    }

    private func delete() {
        switch ref.source {
        case .inbox: store.deleteDraft(entry)
        case .archive(let d): _ = store.deleteFiledEntry(date: d, entry: entry)
        case .journal(let n): _ = store.deleteJournalEntry(name: n, entry: entry)
        }
        close()
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// Re-read the entry after an edit, a retime or a star (an edit that moved
    /// it to another day pops back instead).
    private func refresh() {
        let pool: [Entry]
        switch ref.source {
        case .inbox: pool = store.inboxDrafts
        case .archive: pool = store.archiveEntries.first { $0.date == entry.date }?.entries ?? []
        case .journal(let n): pool = store.entries(inJournal: n)
        }
        if let found = Self.locate(entry, in: pool) { entry = found }
    }

    /// The entry on this page, among those now in its file. Two entries can
    /// share a second (imports make these), so the timestamp alone found the
    /// first of them and Star, Delete and Edit then acted on that one. Its id
    /// first (the file, the second, and which of that second's entries it is);
    /// then its text, for an entry that came without a place in a file; a
    /// timestamp only when a single entry has it.
    static func locate(_ entry: Entry, in pool: [Entry]) -> Entry? {
        if let same = pool.first(where: { $0.id == entry.id }) { return same }
        let sameText = pool.filter { $0.raw == entry.raw }
        if sameText.count == 1 { return sameText[0] }
        let sameTime = pool.filter { $0.ts == entry.ts }
        return sameTime.count == 1 ? sameTime[0] : nil
    }

    // MARK: Body

    fileprivate enum Block { case heading(String, Int), quote(String), media(String, caption: String), text(String) }

    /// The blocks of the body last drawn. The page is redrawn for every change
    /// the store announces (each autosave, under the composer too), and parsing
    /// the body again each time, links and all, was done for nothing.
    private final class Parsed {
        private var body: String?
        private var blocks: [Block] = []
        func blocks(of body: String) -> [Block] {
            if self.body == body { return blocks }
            blocks = ReaderScreen.blocks(of: body)
            self.body = body
            return blocks
        }
    }

    private static func blocks(of body: String) -> [Block] {
        body.components(separatedBy: "\n\n").flatMap { raw -> [Block] in
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { return [] }
            // Only the first line of a block is its heading. `## Morning` with
            // its paragraph straight under it, no blank line between, was set
            // whole in heading type and cut off at 300 characters; what follows
            // the line now reads as any other text does (a quote, a photo).
            let hashes = part.prefix { $0 == "#" }.count
            let line = part.prefix { $0 != "\n" }
            // (A heading line that carries a photo is left to the photo's path, as before.)
            if hashes > 0, hashes <= 3, part.dropFirst(hashes).first == " ", !line.contains("![") {
                let rest = part.dropFirst(line.count).trimmingCharacters(in: .whitespacesAndNewlines)
                let heading = Block.heading(String(line.dropFirst(hashes + 1)).qClamped(300), hashes)
                return [heading] + (rest.isEmpty ? [] : prose(rest))
            }
            return prose(part)
        }
    }

    /// A block that isn't a heading: media and the text around it, a quote, or text.
    private static func prose(_ part: String) -> [Block] {
        // Media links are found with the same parser the Journal page uses,
        // so a photo that shows there shows here: wherever it sits in the
        // paragraph, and with a caption, a title or spaces round it. Text
        // around it, a voice memo's transcript say, reads as text.
        let segments = parseMediaSegments(part)
        if segments.contains(where: { if case .image = $0 { true } else { false } }) {
            return segments.flatMap { seg -> [Block] in
                switch seg {
                case .image(let path, let caption): return [.media(path, caption: caption)]
                case .text(let t):
                    let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? [] : text.qChunks(1500).map { Block.text($0) }
                }
            }
        }
        if part.hasPrefix(">") {
            return part.split(separator: "\n").map { $0.drop { $0 == ">" || $0 == " " } }.joined(separator: "\n")
                .qChunks(1500).map { Block.quote($0) }
        }
        return part.qChunks(1500).map { Block.text($0) }
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(QMarkdown.inline(text, accent: q.accentColor))
                .font(q.writing(level == 1 ? 28 : 23, weight: .medium)).foregroundStyle(q.inkColor)
                .padding(.top, 8)
        case .quote(let text):
            Text(QMarkdown.inline(text, accent: q.accentColor))
                .font(q.writing(19, italic: true)).foregroundStyle(q.mutedColor).lineSpacing(6)
                .padding(.leading, 16)
        case .media(let path, let caption):
            VStack(spacing: 8) {
                mediaView(path, caption: caption)
                if !caption.isEmpty {
                    Text(caption)
                        .font(q.writing(15, italic: true)).foregroundStyle(q.mutedColor)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        case .text(let text):
            Text(QMarkdown.inline(text, accent: q.accentColor))
                .font(q.writing(fontSize + 2)).foregroundStyle(q.inkColor).lineSpacing(8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func mediaView(_ path: String, caption: String) -> some View {
        let url = store.assetURL(forRelative: path)
        switch MediaKind(path: path) {
        // A player belongs to its file: blocks are told apart by their place on
        // the page, so without this another file arriving in the same place
        // kept the last one's player, still playing.
        case .video where url != nil:
            VideoView(url: url!)
                .aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
                .accessibilityLabel(caption.isEmpty ? "Attached video" : caption)
                .id(url!)
        case .audio where url != nil:
            AudioPlayerView(url: url!)
                .id(url!)
        default:
            if let url {
                ReaderImage(url: url, path: path, caption: caption).id(url)
            } else {
                Text(path).font(q.mono(12)).foregroundStyle(q.mutedColor)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(entry.wordCount) words · \(isDraft ? "draft" : "filed")")
            Spacer()
            if let file = entry.file { Text(file).lineLimit(1).truncationMode(.head) }
        }
        .font(q.mono(11)).foregroundStyle(q.mutedColor)
        .padding(.top, 10)
    }
}

/// A photo on the page. Decoded off the main thread, and no larger than the
/// screen can show: a full-size photo read while the page was being drawn held
/// the page up, and held tens of megabytes for each one.
private struct ReaderImage: View {
    @Environment(\.quire) private var q
    @Environment(\.displayScale) private var displayScale
    let url: URL
    let path: String
    let caption: String

    private enum Loaded { case waiting, image(Image), missing }
    @State private var loaded = Loaded.waiting

    /// The screen's longer side, in pixels: enough for either way up.
    private var side: Int {
        let bounds = UIScreen.main.bounds.size
        return Int(max(bounds.width, bounds.height) * displayScale)
    }

    var body: some View {
        Group {
            switch loaded {
            case .image(let image):
                image.resizable().scaledToFit().frame(maxWidth: .infinity)
                    .accessibilityLabel(caption.isEmpty ? "Attached photo" : caption)
            case .missing:
                Text(path).font(q.mono(12)).foregroundStyle(q.mutedColor)
            case .waiting:
                // Room for it, so the page moves little when it arrives.
                Color.clear.aspectRatio(4 / 3, contentMode: .fit).frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .task(id: url) {
            let side = side
            if let hit = RowThumbnail.cached(url, side: side) { loaded = .image(hit); return }
            let image = await Task.detached(priority: .userInitiated) { RowThumbnail.load(url, side: side) }.value
            guard !Task.isCancelled else { return }
            loaded = image.map(Loaded.image) ?? .missing
        }
    }
}

#endif
