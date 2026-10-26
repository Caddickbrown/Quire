//
//  ReaderScreen.swift
//  Quire
//
//  One entry, set as a page. Actions are words along the top; the text gets the
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

    @State private var entry: Entry
    @State private var confirmDelete = false
    @State private var routerID = UUID()

    init(ref: EntryRef, onEdit: @escaping (EntryRef) -> Void, onRetime: @escaping (EntryRef) -> Void) {
        self.ref = ref
        self.onEdit = onEdit
        self.onRetime = onRetime
        _entry = State(initialValue: ref.entry)
    }

    private var current: EntryRef { EntryRef(entry: entry, source: ref.source) }
    private var isDraft: Bool { ref.source == .inbox }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(q.caps(entry.qHasTitle ? entry.displayTitle : "Untitled"))
                        .font(q.isMarathon ? q.display(30) : q.writing(34, weight: .medium, italic: !entry.qHasTitle))
                        .foregroundStyle(entry.qHasTitle ? q.inkColor : q.mutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                    QTitleRule()
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26).padding(.top, 12).padding(.bottom, 40)
            }
        }
        .background(q.pageColor)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: store.revision) { _, _ in refresh(); mirror() }
        .onAppear { mirror(); registerKeys() }
        .onDisappear {
            ExternalDisplayModel.shared.clearEntry(writing: false)
            KeyCommandRouter.shared.unregister(routerID)
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                QLink(title: "‹ Back") { dismiss() }
                Spacer()
                action(entry.isStarred ? "★ Starred" : "☆ Star", color: entry.isStarred ? q.accentColor : q.mutedColor) {
                    store.toggleStar(entry, source: ref.source); refresh()
                }
                if isDraft {
                    action("File", color: q.accentColor, bold: true) { store.fileDraft(entry); dismiss() }
                } else {
                    action("Return to inbox", color: q.mutedColor) { _ = store.returnToInbox(entry, source: ref.source); dismiss() }
                }
                action("Delete", color: q.mutedColor) { confirmDelete = true }
                action("Edit", color: q.inkColor, bold: true) { onEdit(current) }
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

    private func action(_ title: String, color: Color, bold: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(q.ui(13, weight: bold ? .semibold : .regular)).foregroundStyle(color)
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Show the entry on a connected monitor while it is open.
    private func mirror() {
        ExternalDisplayModel.shared.present(.reading(
            title: entry.displayTitle, date: QDate.date(entry.ts) ?? Date(), text: entry.body, isStarred: entry.isStarred))
    }

    /// The terminal app's keys for an open entry: e edit, * star, f file, u return
    /// to the inbox, t date and time, d delete, Esc back.
    private func registerKeys() {
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: {}, moveDown: {}, open: {},
            clear: { dismiss() },
            key: { k in
                switch k {
                case "e": onEdit(current); return true
                case "*": store.toggleStar(entry, source: ref.source); refresh(); return true
                case "f": if isDraft { store.fileDraft(entry); dismiss() }; return isDraft
                case "u": if !isDraft { _ = store.returnToInbox(entry, source: ref.source); dismiss() }; return !isDraft
                case "t": onRetime(current); return true
                case "d": confirmDelete = true; return true
                default: return false
                }
            }))
    }

    private func delete() {
        switch ref.source {
        case .inbox: store.deleteDraft(entry)
        case .archive(let d): _ = store.deleteFiledEntry(date: d, entry: entry)
        case .journal(let n): _ = store.deleteJournalEntry(name: n, entry: entry)
        }
        dismiss()
    }

    /// Re-read the entry after an edit, a retime or a star. Matched by timestamp
    /// (an edit that moved it to another day pops back instead).
    private func refresh() {
        let found: Entry?
        switch ref.source {
        case .inbox: found = store.inboxDrafts.first { $0.ts == entry.ts }
        case .archive: found = store.archiveEntries.first { $0.date == entry.date }?.entries.first { $0.ts == entry.ts }
        case .journal(let n): found = store.entries(inJournal: n).first { $0.ts == entry.ts }
        }
        if let found { entry = found }
    }

    // MARK: Body

    private enum Block { case heading(String, Int), quote(String), media(String), text(String) }

    private var blocks: [Block] {
        entry.body.components(separatedBy: "\n\n").flatMap { raw -> [Block] in
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { return [] }
            if part.hasPrefix("![") , let open = part.firstIndex(of: "("), let close = part.lastIndex(of: ")"), open < close {
                return [.media(String(part[part.index(after: open)..<close]))]
            }
            let hashes = part.prefix { $0 == "#" }.count
            if hashes > 0, hashes <= 3, part.dropFirst(hashes).first == " " {
                return [.heading(String(part.dropFirst(hashes + 1)).qClamped(300), hashes)]
            }
            if part.hasPrefix(">") {
                return part.split(separator: "\n").map { $0.drop { $0 == ">" || $0 == " " } }.joined(separator: "\n")
                    .qChunks(1500).map { Block.quote($0) }
            }
            return part.qChunks(1500).map { Block.text($0) }
        }
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
        case .media(let path):
            if let url = store.assetURL(forRelative: path), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .accessibilityLabel("Attached photo")
            } else {
                Text(path).font(q.mono(12)).foregroundStyle(q.mutedColor)
            }
        case .text(let text):
            Text(QMarkdown.inline(text, accent: q.accentColor))
                .font(q.writing(fontSize + 2)).foregroundStyle(q.inkColor).lineSpacing(8)
                .fixedSize(horizontal: false, vertical: true)
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

#endif
