//
//  InboxView.swift
//  Nook
//
//  The inbox: unfiled drafts. On macOS it's an email-style two-pane (list +
//  selected draft); on iOS the list pushes to the editor. Each draft can be
//  Filed, Edited, or Deleted. Search / sort / File All live in the toolbar.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum InboxSort: String, CaseIterable, Identifiable {
    case newest, oldest, longest, shortest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest:   return "Newest first"
        case .oldest:   return "Oldest first"
        case .longest:  return "Longest first"
        case .shortest: return "Shortest first"
        }
    }
}

/// How the inbox list is broken up: date headers, or one flat list.
enum InboxGrouping: String, CaseIterable, Identifiable {
    case date, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .date: return "Group by date"
        case .none: return "No grouping"
        }
    }
}

enum SwipeAction: String, CaseIterable, Identifiable {
    case file, delete, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .file:   return "File"
        case .delete: return "Delete"
        case .none:   return "None"
        }
    }
}

struct InboxView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    @AppStorage("inboxSort") private var sortRaw: String = InboxSort.newest.rawValue
    @AppStorage("inboxGrouping") private var groupingRaw: String = InboxGrouping.date.rawValue
    @AppStorage("inboxSwipeLeft") private var swipeLeftRaw = SwipeAction.file.rawValue
    @AppStorage("inboxSwipeRight") private var swipeRightRaw = SwipeAction.delete.rawValue
    @State private var searchText = ""
    @State private var selectedTS: String?

    private var drafts: [Entry] {
        var d = store.inboxDrafts
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty { d = d.filter { $0.raw.lowercased().contains(q) } }
        switch InboxSort(rawValue: sortRaw) ?? .newest {
        case .newest:   d.sort { $0.ts > $1.ts }
        case .oldest:   d.sort { $0.ts < $1.ts }
        case .longest:  d.sort { $0.wordCount > $1.wordCount }
        case .shortest: d.sort { $0.wordCount < $1.wordCount }
        }
        return d
    }

    var body: some View {
        content
            .searchable(text: $searchText, prompt: "Search drafts")
            .navigationTitle("Inbox")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarItems }
    }

    private func selectRandom() {
        guard let draft = store.inboxDrafts.randomElement() else { return }
        #if os(macOS)
        selectedTS = draft.ts
        #else
        nav.path.append(Route.entry(draft, .inbox))
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if store.inboxDrafts.isEmpty {
            ContentUnavailableView(
                "Inbox is empty",
                systemImage: "tray",
                description: Text("Drafts you write appear here until you file them.")
            )
        } else {
            #if os(macOS)
            HStack(spacing: 0) {
                draftList
                    .frame(width: 320)
                Divider()
                Group {
                    // Look the draft up in the full inbox (not the search-filtered
                    // list) so editing out the search term doesn't kick you out.
                    if let ts = selectedTS, let draft = store.inboxDrafts.first(where: { $0.ts == ts }) {
                        EntryDetailView(entry: draft, source: .inbox).id(ts)
                    } else {
                        ContentUnavailableView("Select a draft", systemImage: "tray")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #else
            draftList
            #endif
        }
    }

    /// Drafts grouped into date sections (order follows the current sort).
    private var draftSections: [(date: String, entries: [Entry])] {
        var order: [String] = [], map: [String: [Entry]] = [:]
        for d in drafts {
            if map[d.date] == nil { order.append(d.date) }
            map[d.date, default: []].append(d)
        }
        switch InboxSort(rawValue: sortRaw) ?? .newest {
        case .longest, .shortest: order.sort { $0 > $1 }   // dates newest-first
        default: break                                     // already in ts order
        }
        return order.map { (date: $0, entries: map[$0] ?? []) }
    }

    private var grouping: InboxGrouping { InboxGrouping(rawValue: groupingRaw) ?? .date }

    private var draftList: some View {
        List(selection: selectionBinding) {
            if grouping == .date {
                ForEach(draftSections, id: \.date) { section in
                    Section(Theme.sectionDate(section.date, style: dateStyleRaw)) {
                        ForEach(section.entries) { draftRow($0) }
                    }
                }
            } else {
                ForEach(drafts) { draftRow($0) }
            }
        }
        #if os(iOS)
        // Pull down past the top to jump to a random draft.
        .refreshable { selectRandom() }
        .background { DiceRefreshDecorator() }
        #endif
    }

    private func draftRow(_ draft: Entry) -> some View {
        row(for: draft)
            .tag(draft.ts)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                swipeButton(SwipeAction(rawValue: swipeRightRaw) ?? .delete, draft)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                swipeButton(SwipeAction(rawValue: swipeLeftRaw) ?? .file, draft)
            }
            .contextMenu {
                Button { store.fileDraft(draft) } label: { Label("Archive", systemImage: "archivebox") }
                Button { store.toggleStar(draft, source: .inbox) } label: {
                    Label(draft.isStarred ? "Unstar" : "Star",
                          systemImage: draft.isStarred ? "star.slash" : "star")
                }
                #if os(macOS)
                Button { store.revealEntry(source: .inbox) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                #endif
                Button(role: .destructive) { store.deleteDraft(draft) } label: { Label("Delete", systemImage: "trash") }
                    .destructiveAction()
            }
    }

    @ViewBuilder
    private func swipeButton(_ action: SwipeAction, _ draft: Entry) -> some View {
        switch action {
        case .file:
            Button { store.fileDraft(draft) } label: { Label("File", systemImage: "archivebox") }
                .tint(.green)
        case .delete:
            // Explicitly red: a destructive role alone doesn't tint the leading edge.
            Button(role: .destructive) { store.deleteDraft(draft) } label: { Label("Delete", systemImage: "trash") }
                .tint(.red)
        case .none:
            EmptyView()
        }
    }

    /// On macOS the list drives the side pane; on iOS rows push via NavigationLink.
    @ViewBuilder
    private func row(for draft: Entry) -> some View {
        #if os(macOS)
        DraftRow(draft: draft)
        #else
        NavigationLink(value: Route.entry(draft, .inbox)) {
            DraftRow(draft: draft)
        }
        #endif
    }

    private var selectionBinding: Binding<String?> {
        #if os(macOS)
        return $selectedTS
        #else
        return .constant(nil)
        #endif
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                selectRandom()
            } label: {
                Label("Random", systemImage: "dice")
            }
            .disabled(store.inboxDrafts.isEmpty)
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(InboxSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Grouping", selection: $groupingRaw) {
                    ForEach(InboxGrouping.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Button { store.fileAllDrafts() } label: { Label("File All", systemImage: "archivebox") }
                    .disabled(store.inboxDrafts.isEmpty)
                Button { store.sortInbox() } label: { Label("Sort file by date", systemImage: "calendar") }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
        }
    }
}

#if os(iOS)
/// Swaps the pull-to-refresh spinner for a spinning dice, since pulling down
/// here rolls a random entry rather than reloading anything.
///
/// `.refreshable` gives no hook for a custom indicator, so this drops an
/// invisible probe into the list's background, walks up to the enclosing scroll
/// view, and restyles its refresh control. If the hierarchy ever changes shape
/// the lookup simply finds nothing and the stock spinner stays.
struct DiceRefreshDecorator: UIViewRepresentable {
    private static let diceTag = 0x0D1CE

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: UIView, context: Context) {
        // SwiftUI attaches the refresh control after this layout pass, and not
        // always on the first run loop turn, so the lookup retries for a beat.
        decorate(from: probe, attempt: 0)
    }

    private func decorate(from probe: UIView, attempt: Int) {
        guard attempt < 10 else { return }          // give up; stock spinner stays
        guard let refresh = Self.findRefreshControl(from: probe) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                decorate(from: probe, attempt: attempt + 1)
            }
            return
        }
        guard refresh.viewWithTag(Self.diceTag) == nil else { return }

        refresh.tintColor = .clear      // hide the stock spinner, keep the mechanics

        let dice = UIImageView(image: UIImage(systemName: "dice"))
        dice.tag = Self.diceTag
        dice.tintColor = .secondaryLabel
        dice.contentMode = .scaleAspectFit
        dice.translatesAutoresizingMaskIntoConstraints = false
        refresh.addSubview(dice)
        NSLayoutConstraint.activate([
            dice.centerXAnchor.constraint(equalTo: refresh.centerXAnchor),
            dice.centerYAnchor.constraint(equalTo: refresh.centerYAnchor),
            dice.widthAnchor.constraint(equalToConstant: 22),
            dice.heightAnchor.constraint(equalToConstant: 22),
        ])

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1.1
        spin.repeatCount = .infinity
        dice.layer.add(spin, forKey: "spin")
    }

    /// Look up the enclosing scroll view's refresh control, then — if the probe
    /// isn't hosted inside the scroll view at all — search down from the window
    /// for the first one that has a refresh control.
    private static func findRefreshControl(from probe: UIView) -> UIRefreshControl? {
        var view: UIView? = probe
        while let current = view {
            if let scroll = current as? UIScrollView, let refresh = scroll.refreshControl {
                return refresh
            }
            view = current.superview
        }
        guard let root = probe.window else { return nil }
        return firstRefreshControl(in: root)
    }

    private static func firstRefreshControl(in view: UIView) -> UIRefreshControl? {
        if let scroll = view as? UIScrollView, let refresh = scroll.refreshControl {
            return refresh
        }
        for subview in view.subviews {
            if let found = firstRefreshControl(in: subview) { return found }
        }
        return nil
    }
}
#endif

private struct DraftRow: View {
    let draft: Entry

    private var time: String { String(draft.ts.suffix(8).prefix(5)) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if draft.isStarred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(draft.preview.isEmpty ? "(empty)" : draft.preview)
                        .lineLimit(1)
                        .font(.body)
                }
                HStack(spacing: 8) {
                    Text(time)
                    Text("·")
                    Text("\(draft.wordCount) words")
                    ForEach(draft.mediaBadges, id: \.self) { symbol in
                        Image(systemName: symbol)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !draft.tags.isEmpty {
                    Text(draft.tags.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            EntryThumbnail(entry: draft)
        }
        .padding(.vertical, 2)
    }
}
