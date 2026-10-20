//
//  JournalScreen.swift
//  Quire
//
//  Everything that has been filed, by month and day. Tags run across the top as
//  words with counts; picking one narrows the list, and so does Starred.
//

#if os(iOS)

import SwiftUI

struct JournalScreen: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q

    var open: (EntryRef) -> Void
    var edit: (EntryRef) -> Void
    var retime: (EntryRef) -> Void
    var search: () -> Void
    var settings: () -> Void
    var media: () -> Void

    @State private var tag: String?
    @State private var starredOnly = false
    @State private var allTags = false
    @State private var selected: Int?
    @State private var deleting: Entry?

    private struct Month: Identifiable {
        let id: String   // "2026-09"
        var days: [(date: String, entries: [Entry])]
        var count: Int { days.reduce(0) { $0 + $1.entries.count } }
    }

    /// Days, newest first, narrowed by the chosen tag or the star filter.
    private var days: [(date: String, entries: [Entry])] {
        var days = store.archiveEntries
        if let tag {
            let wanted = tag.hasPrefix("@") ? tag : "@" + tag
            days = days.compactMap { day in
                let kept = day.entries.filter { $0.tags.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
                return kept.isEmpty ? nil : (day.date, kept)
            }
        }
        if starredOnly {
            days = days.compactMap { day in
                let kept = day.entries.filter(\.isStarred)
                return kept.isEmpty ? nil : (day.date, kept)
            }
        }
        return days
    }

    private var months: [Month] {
        var out: [Month] = []
        for day in days {
            let key = String(day.date.prefix(7))
            if out.last?.id == key { out[out.count - 1].days.append(day) }
            else { out.append(Month(id: key, days: [day])) }
        }
        return out
    }

    var body: some View {
        let months = months
        let flat = months.flatMap { $0.days.flatMap { $0.entries.reversed() } }
        let selectedID = selected.flatMap { flat.indices.contains($0) ? flat[$0].id : nil }
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                QMasthead(onSearch: search, onSettings: settings)
                QTitle(kicker: "\(store.archiveEntries.reduce(0) { $0 + $1.entries.count }) filed", title: "Journal")
                QLink(title: "Media Library", action: media)
                filters
                if months.isEmpty {
                    Text(!store.indexed ? "Loading your journal…"
                         : tag != nil || starredOnly ? "Nothing matches."
                         : "Nothing is filed yet. File a draft from the inbox and it lands here.")
                        .font(q.writing(18)).foregroundStyle(q.mutedColor)
                }
                ForEach(months) { month in
                    VStack(alignment: .leading, spacing: 16) {
                        QLabel(QDate.monthYear(month.id + "-01"), trailing: "\(month.count)")
                            .padding(.bottom, 4).overlay(alignment: .bottom) { QRule() }
                        ForEach(month.days, id: \.date) { day in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(QDate.shortDay(day.date).uppercased()).tracking(1.4)
                                    .font(q.label(11)).foregroundStyle(q.mutedColor)
                                ForEach(day.entries.reversed()) { entry in
                                    let ref = EntryRef(entry: entry, source: .archive(date: day.date))
                                    QEntryRow(entry: entry, selected: entry.id == selectedID, onOpen: { open(ref) })
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 24)
        }
        .onChange(of: selectedID) { _, id in
            if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
        .qKeyList(entries: flat, index: $selected, listTitle: "Journal", autoSelect: true,
                  onOpen: { open(EntryRef(entry: $0, source: .archive(date: $0.date))) },
                  letter: { entry, key in
                      let source = EntrySource.archive(date: entry.date)
                      switch key {
                      case "e": edit(EntryRef(entry: entry, source: source)); return true
                      case "*": store.toggleStar(entry, source: source); return true
                      case "u": _ = store.returnToInbox(entry, source: source); return true
                      case "t": retime(EntryRef(entry: entry, source: source)); return true
                      case "d": deleting = entry; return true
                      default: return false
                      }
                  })
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deleting { _ = store.deleteFiledEntry(date: d.date, entry: d) }
                deleting = nil
            }
        }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                filterLink("All", on: tag == nil && !starredOnly) { tag = nil; starredOnly = false }
                filterLink("Starred", on: starredOnly) { starredOnly.toggle() }
                if let tag { filterLink("\(tag) ✕", on: true) { self.tag = nil } }
                Spacer()
                filterLink("Random", on: false) {
                    if let r = store.randomEntry() { open(EntryRef(entry: r.entry, source: .archive(date: r.date))) }
                }
            }
            let tags = store.tagCounts.prefix(allTags ? 40 : 6)
            if !tags.isEmpty {
                // "@work 75 · @walk 49 · …"
                FlowText(items: tags.map { ($0.tag, $0.count) }, selected: tag) { tag = $0 == tag ? nil : $0 }
                if store.tagCounts.count > 6 {
                    QLink(title: allTags ? "Fewer" : "\(store.tagCounts.count - 6) more") { allTags.toggle() }
                }
            }
        }
    }

    private func filterLink(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(q.caps(title))
                .tracking(q.isMarathon ? 1.2 : 0)
                .font(q.isMarathon ? q.label(12, weight: on ? .medium : .regular) : q.ui(14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? q.accentColor : q.inkColor)
                .underline(on, color: q.accentColor)
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Tags with counts, flowing and wrapping like a sentence.
private struct FlowText: View {
    @Environment(\.quire) private var q
    let items: [(String, Int)]
    let selected: String?
    let pick: (String) -> Void

    var body: some View {
        Text(items.enumerated().reduce(into: AttributedString()) { out, pair in
            let (i, item) = pair
            let name = item.0.hasPrefix("@") ? item.0 : "@" + item.0
            var tag = AttributedString(name)
            tag.foregroundColor = item.0 == selected ? q.accentColor : q.inkColor
            tag.link = URL(string: "quire-tag://\(item.0.replacingOccurrences(of: "@", with: ""))")
            var count = AttributedString(" \(item.1)")
            count.foregroundColor = q.mutedColor
            out += tag; out += count
            if i < items.count - 1 {
                var dot = AttributedString("  ·  "); dot.foregroundColor = q.mutedColor; out += dot
            }
        })
        .font(q.isMarathon ? q.label(11) : q.ui(13)).lineSpacing(8)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "quire-tag", let host = url.host { pick("@" + host) }
            return .handled
        })
    }
}

#endif
