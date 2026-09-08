//
//  SidebarView.swift
//  Wander
//
//  The index: a search rule, then every entry set in month sections — the
//  contents page of a notebook rather than a mail app's list.
//

import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: JournalStore
    @Environment(\.theme) private var theme
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            search
            Rule()
            entries
            Rule()
            HStack(spacing: 8) {
                AccentBlock(title: "New entry") { store.newEntry() }
                AccentBlock(title: "Draft", filled: false) { store.newDraft() }
                    .frame(width: 82)
            }
            .padding(14)
        }
        .background(theme.panel.color)
        .onChange(of: store.searchFocusRequest) { searchFocused = true }
    }

    private var search: some View {
        HStack(spacing: 9) {
            SmallCaps("Find")
            TextField("", text: $store.query, prompt: Text("title, text or @tag")
                .font(Face.serif(13, italic: true))
                .foregroundColor(theme.muted.opacity(0.7).color))
                .textFieldStyle(.plain)
                .font(Face.sans(13))
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
                    ForEach(store.sections, id: \.title) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                EntryRow(entry: entry,
                                         selected: entry.id == store.selection,
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
            return "Nothing filed yet. The first entry is the hardest to place; it needn't be good."
        case .inbox:
            return "The inbox is empty — start a draft when something isn't ready to be dated."
        case .starred:
            return "Nothing starred. Star an entry to keep it where you can find it again."
        }
    }
}

private struct EntryRow: View {
    let entry: Entry
    let selected: Bool
    @ObservedObject var store: JournalStore
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button {
            store.select(entry.id)
        } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(selected ? theme.accent.color : Color.clear)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        title
                        Spacer(minLength: 4)
                        if entry.isStarred {
                            Text("\u{2731}")
                                .font(Face.sans(9))
                                .foregroundStyle(theme.accent.color)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SmallCaps(meta)
                        Spacer(minLength: 4)
                        // Filing is the one thing a draft is waiting for, so it
                        // sits on the row rather than behind a menu.
                        if store.isUnfiled(entry), hovering || selected {
                            QuietButton(title: "File") { store.file(entry) }
                        }
                    }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .bottom) { Rule(tone: theme.ruleFaint) }
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
            Button("Reveal in Finder") { store.reveal(entry) }
            Button("Copy Markdown") { store.copyMarkdown(entry) }
            Divider()
            Button("Delete\u{2026}", role: .destructive) { store.deletionCandidate = entry }
        }
    }

    private var title: some View {
        Group {
            if entry.preview.isEmpty {
                Text("Untitled")
                    .font(Face.serif(14.5, italic: true))
                    .foregroundStyle(theme.muted.color)
            } else {
                Text(entry.preview)
                    .font(Face.serif(14.5))
                    .foregroundStyle(theme.ink.color)
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
        if selected { return theme.surface.color }
        if hovering { return theme.rule.opacity(0.35).color }
        return .clear
    }
}
