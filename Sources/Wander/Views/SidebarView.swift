//
//  SidebarView.swift
//  Wander
//
//  The index: a search rule, then every entry set in month sections — the
//  contents page of a notebook rather than a mail app's list.
//

import SwiftUI
import WanderCore

struct SidebarView: View {
    @ObservedObject var store: JournalStore
    @Environment(\.theme) private var theme
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Bauhaus's rail is a column of its own, not a backdrop: it has to
            // take width from the index rather than sit under it.
            if theme.ornament == .rail { ThemeOrnament(theme: theme).frame(width: 74) }
            content
        }
        .background(theme.panel.color)
    }

    private var content: some View {
        VStack(spacing: 0) {
            search
            Rule()
            entries
            Rule()
            AccentBlock(title: "New") { store.newEntry() }
                .padding(14)
        }
        .onChange(of: store.searchFocusRequest) { searchFocused = true }
    }

    private var search: some View {
        HStack(spacing: 9) {
            SmallCaps("Find")
            TextField("", text: $store.query, prompt: Text("title, text or @tag")
                .font(theme.proseItalic(13))
                .foregroundColor(theme.muted.opacity(0.7).color))
                .textFieldStyle(.plain)
                .font(theme.ui(13))
                .foregroundStyle(theme.ink.color)
                .focused($searchFocused)
            if !store.query.isEmpty {
                QuietButton(title: "Clear") { store.query = "" }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 11)
    }

    private var entries: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(store.sections) { section in
                        Section {
                            // Enumerated rather than searched: the row needs its
                            // place in the section to pick a fill, and asking
                            // `firstIndex(of:)` for it compared whole entries
                            // down the list for every row drawn.
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { position, entry in
                                EntryRow(entry: entry,
                                         selected: entry.id == store.selection,
                                         position: position,
                                         store: store)
                                    .id(entry.id)
                            }
                        } header: {
                            sectionHeader(section.title,
                                          count: section.entries.count,
                                          inbox: section.inbox)
                        }
                    }
                    if store.sections.isEmpty { empty }
                }
            }
            .onChange(of: store.selection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, inbox: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            SmallCaps(title, tone: inbox ? theme.accent : nil)
            Spacer()
            SmallCaps("\(count)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 6)
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rule(tone: theme.ink) }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Marginalia(text: emptyNote)
        }
        .padding(.horizontal, 14)
        .padding(.top, 22)
    }

    private var emptyNote: String {
        guard store.query.isEmpty else { return "No entry matches that." }
        switch store.page {
        case .journal:
            return "Nothing filed yet. Entries arrive here from the inbox, by \u{2318}J."
        case .inbox:
            return "The inbox is empty. \u{2318}N starts an entry here; file it to a day when it "
                 + "is ready to belong to one."
        case .starred:
            return "Nothing starred. Star an entry to keep it where you can find it again."
        }
    }
}

private struct EntryRow: View {
    let entry: Entry
    let selected: Bool
    let position: Int
    @ObservedObject var store: JournalStore
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button {
            store.select(entry.id)
        } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(selected && theme.rowStyle != .card ? theme.accent.color : Color.clear)
                    .frame(width: theme.rowStyle == .block ? theme.border : 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        title
                        Spacer(minLength: 4)
                        if entry.isStarred {
                            Text("\u{2731}")
                                .font(theme.ui(9))
                                .foregroundStyle(theme.accent.color)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SmallCaps(meta)
                        Spacer(minLength: 4)
                        // Filing is the one thing a draft is waiting for, so it
                        // sits on the row rather than behind a menu.
                        if store.isUnfiled(entry), hovering || selected {
                            // Through the toggle, not `file`, so the row leaves
                            // without taking the open entry's place in the
                            // editor with it.
                            QuietButton(title: "File") { store.toggleFiling(entry) }
                        }
                    }
                }
                .padding(.vertical, theme.rowStyle == .card ? 11 : 9)
                .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay {
                if theme.rowStyle == .card {
                    RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                        .stroke(selected ? theme.accent.color : theme.rule.color,
                                lineWidth: theme.border)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.rowStyle == .card ? theme.corner : 0,
                                        style: .continuous))
            .overlay(alignment: .bottom) {
                // Only the ruled style draws a line between rows; the others
                // separate by card, block or plain air.
                if theme.rowStyle == .rule { Rule(tone: theme.ruleFaint) }
            }
            .padding(.horizontal, theme.rowStyle == .card ? 10 : 0)
            .padding(.vertical, theme.rowStyle == .card ? 4 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(entry.isStarred ? "Unstar" : "Star") { store.toggleStar(entry) }
            Button(store.isUnfiled(entry) ? "File to Journal" : "Return to Inbox") {
                store.toggleFiling(entry)
            }
            Button("Date & Time\u{2026}") { store.reschedulingEntry = entry }
            #if os(macOS)
            Button("Reveal in Finder") { store.reveal(entry) }
            #endif
            Button("Copy Markdown") { store.copyMarkdown(entry) }
            Divider()
            Button("Delete\u{2026}", role: .destructive) { store.deletionCandidate = entry }
        }
    }

    private var title: some View {
        Group {
            if entry.preview.isEmpty {
                Text("Untitled")
                    .font(theme.proseItalic(14.5))
                    .foregroundStyle(theme.muted.color)
            } else {
                Text(entry.preview)
                    .font(theme.rowTitle(14.5))
                    .foregroundStyle(titleTone.color)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var meta: String {
        let day = entry.createdDate.map { Formats.shortDay.string(from: $0) } ?? entry.date
        let words = entry.wordCount
        let counted = "\(day) · \(words) \(words == 1 ? "word" : "words")"
        return store.isUnfiled(entry) ? "Draft · " + counted : counted
    }

    private var background: Color {
        switch theme.rowStyle {
        case .plain, .indent:
            // No fill at all — the accent bar and the ink weight carry it.
            return hovering ? theme.rule.opacity(0.3).color : .clear
        case .block:
            if selected { return theme.ink.color }
            return hovering ? theme.rule.opacity(0.3).color : .clear
        case .card:
            if theme.rowColours {
                // Pink, teal, plain, in rotation — the selected one takes the accent.
                if selected { return theme.accent.color }
                let fills: [Color] = [theme.surface.color, theme.tint.color, theme.surface.color]
                return fills[position % fills.count]
            }
            return selected ? theme.surface.color : theme.surface.opacity(0.6).color
        case .rule:
            if selected { return theme.surface.color }
            return hovering ? theme.rule.opacity(0.35).color : .clear
        }
    }

    /// A block-style row inverts when selected, so its text has to invert too.
    private var titleTone: Tone {
        if theme.rowStyle == .block && selected { return theme.paper }
        if theme.rowColours && selected { return theme.paper }
        return theme.ink
    }
}
