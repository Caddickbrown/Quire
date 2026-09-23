//
//  StreamView.swift
//  Nook
//
//  The Stream: the whole corpus on one scrolling page, oldest at the top —
//  like opening a physical journal and reading straight down. Timestamps sit in
//  a narrow left margin, the prose runs full-length in the right column, and a
//  hairline day break separates one day from the next. Nothing is truncated and
//  nothing pushes: tapping an entry turns that row into an editor in place.
//
//  Inbox drafts can be interleaved into the flow of time (toolbar tray toggle);
//  they read at reduced opacity with a pencil in the margin, so they're clearly
//  unfiled without being hidden.
//

import SwiftUI

/// What the Stream puts on the page. The archive is the default surface; drafts
/// can be folded into the flow of time beside it, or read on their own.
enum StreamDrafts: String, CaseIterable, Identifiable {
    case hidden, mixed, only
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hidden: return "Filed entries only"
        case .mixed:  return "Filed entries and drafts"
        case .only:   return "Drafts only"
        }
    }

    var systemImage: String {
        switch self {
        case .hidden: return "tray"
        case .mixed:  return "tray.full"
        case .only:   return "tray.and.arrow.down"
        }
    }

    var includesArchive: Bool { self != .only }
    var includesDrafts: Bool { self != .hidden }
}

/// One entry on the page, with the file it came from so edits go to the right
/// place. `id` is stable across reloads (`Entry.id` is a fresh UUID per parse)
/// and disambiguated, since two entries can share a timestamp.
struct StreamItem: Identifiable {
    let id: String
    let entry: Entry
    let source: EntrySource

    var isDraft: Bool {
        if case .inbox = source { return true }
        return false
    }
}

struct StreamDaySection: Identifiable {
    let date: String
    let items: [StreamItem]
    var id: String { date }
}

struct StreamView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    // Oldest first by default: the stream reads forwards, like a bound journal.
    @AppStorage("streamSort") private var sortRaw: String = ArchiveSort.oldest.rawValue
    // The archive alone by default — the stream is primarily a reading surface
    // for what's been filed.
    @AppStorage("streamDrafts") private var draftsRaw: String = StreamDrafts.hidden.rawValue
    @Environment(\.accent) private var accent
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// The archive, re-read whenever the store says the files changed.
    @State private var loaded: [(date: String, entries: [Entry])] = []
    /// The merged, sorted page — cached rather than recomputed per body pass, so
    /// a long corpus isn't re-sorted every time a row changes state.
    @State private var sections: [StreamDaySection] = []
    @State private var activeID: String?
    /// Hardware-keyboard selection (↑/↓), mirrored to the external display —
    /// the Stream was the one list the arrows couldn't drive.
    @State private var kbIndex: Int?

    private var oldestFirst: Bool { ArchiveSort(rawValue: sortRaw) == .oldest }
    private var drafts: StreamDrafts { StreamDrafts(rawValue: draftsRaw) ?? .hidden }

    /// iPhone turns the margin into a spine: the time reads bottom-to-top along
    /// the edge, the way a book spine does, so the prose keeps nearly the full
    /// width.
    private var spineTime: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if sections.isEmpty {
                ContentUnavailableView(
                    "Nothing to read yet",
                    systemImage: "scroll",
                    description: Text(drafts == .only
                        ? "Unfiled drafts appear here. Your filed entries are behind the tray button."
                        : "File drafts from your inbox and they'll appear here. The tray button folds unfiled drafts in too.")
                )
            } else {
                page
            }
        }
        .navigationTitle("Stream")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarItems }
        // `revision` bumps on every index rebuild — every file, delete, star,
        // and editor flush — so this is the one signal the page needs.
        .task(id: store.revision) { reload() }
        .onChange(of: store.inboxDrafts.map(\.raw)) { _, _ in rebuild() }
        .onChange(of: sortRaw) { _, _ in rebuild() }
        .onChange(of: draftsRaw) { _, _ in rebuild() }
    }

    /// The page's items in reading order — what the arrow keys walk.
    private var flatItems: [StreamItem] { sections.flatMap(\.items) }

    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                StreamRow(item: item,
                                          spineTime: spineTime,
                                          activeID: $activeID,
                                          keyboardSelected: isKeyboardSelected(item))
                                    .id(item.id)
                            }
                            .padding(.top, 2)
                        } header: {
                            dayBreak(section.date)
                        }
                    }
                }
                .padding(.bottom, 80)
                // Tapping the page outside any entry commits and deactivates.
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { activeID = nil }
                }
            }
            // Bring a freshly activated entry to the top, clear of the keyboard.
            .onChange(of: activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: kbIndex) { _, i in
                let items = flatItems
                guard let i, items.indices.contains(i) else { return }
                withAnimation { proxy.scrollTo(items[i].id, anchor: .center) }
            }
        }
        // ↑/↓ walk the page, ↩ edits the selected entry in place, ⎋ closes it —
        // and the selection mirrors to the external display like every list.
        .entryListNavigation(entries: flatItems.map(\.entry), index: $kbIndex, listTitle: "Stream") { entry in
            if let hit = flatItems.first(where: { $0.entry.id == entry.id }) { activeID = hit.id }
        }
    }

    private func isKeyboardSelected(_ item: StreamItem) -> Bool {
        guard let i = kbIndex else { return false }
        let items = flatItems
        return items.indices.contains(i) && items[i].id == item.id
    }

    /// A day break: the date, then a hairline running to the edge. Background
    /// level on purpose — it separates, it doesn't announce.
    ///
    /// Pinned, so whichever day you're reading names itself at the top of the
    /// page until the next one pushes it off — you're never scrolling through
    /// undated prose wondering when this was. That needs an opaque backing:
    /// the entries scroll underneath it.
    private func dayBreak(_ date: String) -> some View {
        HStack(spacing: 10) {
            Text(Theme.sectionDate(date, style: dateStyleRaw))
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // The bar material alone is translucent, and prose sliding underneath a
        // pinned header shows straight through it — so give it opaque backing.
        .background(.bar)
        .background(.background)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("Show", selection: $draftsRaw) {
                    ForEach(StreamDrafts.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Show", systemImage: drafts.systemImage)
                    .foregroundStyle(drafts == .hidden ? Color.secondary : accent)
            }
            .help(drafts.label)

            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(ArchiveSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    // MARK: Data

    private func reload() {
        loaded = store.allEntriesByDay()
        rebuild()
    }

    /// Merge the archive with (optionally) the inbox, sort the lot by timestamp,
    /// then cut it into day sections in that same order.
    private func rebuild() {
        var items: [StreamItem] = []
        var seen: [String: Int] = [:]
        func add(_ entry: Entry, _ source: EntrySource, draft: Bool) {
            let key = (draft ? "i-" : "a-") + entry.ts
            let n = seen[key, default: 0]
            seen[key] = n + 1
            items.append(StreamItem(id: "\(key)#\(n)", entry: entry, source: source))
        }
        if drafts.includesArchive {
            for day in loaded {
                for e in day.entries { add(e, .archive(date: day.date), draft: false) }
            }
        }
        if drafts.includesDrafts {
            for d in store.inboxDrafts { add(d, .inbox, draft: true) }
        }
        items.sort { oldestFirst ? $0.entry.ts < $1.entry.ts : $0.entry.ts > $1.entry.ts }

        var order: [String] = []
        var byDay: [String: [StreamItem]] = [:]
        for item in items {
            if byDay[item.entry.date] == nil { order.append(item.entry.date) }
            byDay[item.entry.date, default: []].append(item)
        }
        sections = order.map { StreamDaySection(date: $0, items: byDay[$0] ?? []) }
    }
}

// MARK: - A row

/// One entry as it sits on the page: margin on the left, prose on the right,
/// swapping to an in-place editor when it's the active row.
private struct StreamRow: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accent) private var accent
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue

    let item: StreamItem
    let spineTime: Bool
    @Binding var activeID: String?
    var keyboardSelected = false

    #if os(iOS)
    /// Horizontal swipe offset. There's no resting-open state: a swipe past the
    /// threshold fires, anything less springs back.
    @State private var offset: CGFloat = 0
    @State private var horizontal: Bool?
    #endif

    private var entry: Entry { item.entry }
    private var isActive: Bool { activeID == item.id }
    private var size: CGFloat { CGFloat(fontSize) }
    private var font: Font { Theme.font(writingFontRaw, size: size) }
    private var time: String { String(entry.ts.suffix(8).prefix(5)) }

    var body: some View {
        #if os(iOS)
        ZStack {
            swipeBackdrop
            row
                .background(Color(.systemBackground))
                .offset(x: offset)
                .simultaneousGesture(swipeGesture)
        }
        #else
        row
        #endif
    }

    private var row: some View {
        HStack(alignment: .top, spacing: spineTime ? 8 : 14) {
            margin
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Unfiled drafts recede without disappearing — no background tint needed.
        .opacity(item.isDraft && !isActive ? 0.6 : 1)
        .background {
            if keyboardSelected && !isActive {
                RoundedRectangle(cornerRadius: 8)
                    .fill(accent.opacity(0.12))
                    .padding(.horizontal, 6)
            }
            if isActive {
                RoundedRectangle(cornerRadius: 8)
                    .fill(accent.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.35)))
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isActive { activeID = item.id } }
        .contextMenu { menu }
        // The swipes, spoken: VoiceOver can't perform a drag-offset gesture.
        .accessibilityAction(named: item.isDraft ? "File" : "Star") {
            if item.isDraft { store.fileDraft(entry) }
            else { store.toggleStar(entry, source: item.source) }
        }
        .accessibilityAction(named: "Delete") { delete() }
    }

    // MARK: Margin

    /// The page margin: time, then a star and a draft pencil under it. Narrow
    /// and quiet — a printed journal's margin, not a control strip.
    @ViewBuilder
    private var margin: some View {
        if spineTime {
            VStack(spacing: 5) {
                Text(time)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 18, height: 46)
                marks
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 18)
        } else {
            VStack(alignment: .trailing, spacing: 5) {
                Text(time)
                marks
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 48, alignment: .trailing)
            // Sit the time on the first line of body text, not above it.
            .padding(.top, 3)
        }
    }

    @ViewBuilder
    private var marks: some View {
        if entry.isStarred {
            Image(systemName: "star.fill").foregroundStyle(.yellow)
        }
        if item.isDraft {
            Image(systemName: "square.and.pencil")
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if isActive {
            StreamEditor(item: item) { activeID = nil }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !entry.displayTitle.isEmpty {
                    Text(entry.displayTitle)
                        .font(font.weight(.semibold))
                        .foregroundStyle(Theme.bodyText(colorScheme))
                }
                if entry.body.isEmpty {
                    if entry.displayTitle.isEmpty {
                        Text("Empty entry")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    // Full text — the stream never truncates. Images come through
                    // the thumbnail cache so scrolling the corpus doesn't decode
                    // every photo at full resolution.
                    MediaBody(text: entry.body,
                              font: font,
                              textColor: Theme.bodyText(colorScheme),
                              contentPadding: 0,
                              selectableText: false,
                              maxImageHeight: 260,
                              thumbnailSide: 600)
                }
            }
        }
    }

    // MARK: Menu + actions

    @ViewBuilder
    private var menu: some View {
        if item.isDraft {
            Button { store.fileDraft(entry) } label: { Label("File", systemImage: "archivebox") }
        } else {
            Button { returnToInbox() } label: {
                Label("Return to Inbox", systemImage: "tray.and.arrow.up")
            }
        }
        Button { store.toggleStar(entry, source: item.source) } label: {
            Label(entry.isStarred ? "Unstar" : "Star",
                  systemImage: entry.isStarred ? "star.slash" : "star")
        }
        #if os(macOS)
        Button { store.revealEntry(source: item.source) } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        #endif
        Button(role: .destructive) { delete() } label: { Label("Delete", systemImage: "trash") }
            .destructiveAction()
    }

    private func returnToInbox() {
        if isActive { activeID = nil }
        store.returnToInbox(entry, source: item.source)
    }

    private func delete() {
        if isActive { activeID = nil }
        switch item.source {
        case .inbox:          store.deleteDraft(entry)
        case .archive(let d): store.deleteFiledEntry(date: d, entry: entry)
        case .journal(let n): store.deleteJournalEntry(name: n, entry: entry)
        }
    }

    // MARK: Swipe (iOS)

    #if os(iOS)
    /// Right-swipe files, and only drafts have anywhere to be filed to.
    private var canFile: Bool { item.isDraft }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                // Decide the axis once, on the first real movement: a vertical
                // drag belongs to the scroll view and mustn't drag the row too.
                if horizontal == nil {
                    horizontal = abs(value.translation.width) > abs(value.translation.height)
                }
                guard horizontal == true else { return }
                var dx = value.translation.width
                if !canFile { dx = min(dx, 0) }
                offset = max(-220, min(220, dx))
            }
            .onEnded { _ in
                defer { horizontal = nil }
                guard horizontal == true else { return }
                let threshold: CGFloat = 110
                if offset <= -threshold {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.easeOut(duration: 0.18)) { offset = 0 }
                    delete()
                } else if canFile, offset >= threshold {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.easeOut(duration: 0.18)) { offset = 0 }
                    if isActive { activeID = nil }
                    store.fileDraft(entry)
                } else {
                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.85)) {
                        offset = 0
                    }
                }
            }
    }

    @ViewBuilder
    private var swipeBackdrop: some View {
        if offset != 0 {
            let filing = offset > 0
            ZStack(alignment: filing ? .leading : .trailing) {
                (filing ? Color.green : Color.red)
                    .opacity(min(1, abs(offset) / 110))
                Image(systemName: filing ? "archivebox" : "trash")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
            }
        }
    }
    #endif
}

// MARK: - Editing in place

/// The active row's editor: a title line and the same text editor the composer
/// uses, sized to its content so it lives inside the page's scroll rather than
/// scrolling within itself. Autosaves on the composer's debounce.
private struct StreamEditor: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accent) private var accent
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("highlightTags") private var highlightTags = true

    let item: StreamItem
    let onDone: () -> Void

    @State private var title: String
    @State private var text: String
    @State private var baselineRaw: String
    @State private var saveTask: Task<Void, Never>?
    @State private var pendingReindex = false
    @FocusState private var focused: Bool

    init(item: StreamItem, onDone: @escaping () -> Void) {
        self.item = item
        self.onDone = onDone
        _title = State(initialValue: item.entry.suffix)
        _text = State(initialValue: item.entry.body)
        _baselineRaw = State(initialValue: item.entry.raw)
    }

    private var size: CGFloat { CGFloat(fontSize) }
    private var font: Font { Theme.font(writingFontRaw, size: size) }
    private var composed: Entry {
        JournalStore.makeEntry(timestamp: item.entry.ts, title: title, body: text)
    }
    private var isDirty: Bool { composed.raw != baselineRaw }
    private var isStarred: Bool { title.trimmingCharacters(in: .whitespaces).hasSuffix("*") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title)
                .font(font.weight(.semibold))
                .textFieldStyle(.plain)
                .onSubmit { focused = true }

            WritingTextEditor(text: $text,
                              fontRaw: writingFontRaw,
                              size: size,
                              textColor: Theme.bodyText(colorScheme),
                              lineSpacing: Theme.lineSpacing(for: size),
                              highlightTags: highlightTags,
                              accent: accent,
                              sizeToFit: true)
                .focused($focused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Begin writing")
                            .font(font)
                            .foregroundStyle(Theme.placeholder(colorScheme))
                            .allowsHitTesting(false)
                    }
                }

            footer
        }
        .onAppear { focused = true }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onDisappear { flush() }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if item.isDraft {
                Button {
                    flush()
                    store.fileDraft(composed)
                    onDone()
                } label: {
                    Label("File", systemImage: "archivebox")
                }
                .help("File into the archive")
            }
            Button { toggleStar() } label: {
                Label(isStarred ? "Unstar" : "Star", systemImage: isStarred ? "star.fill" : "star")
                    .foregroundStyle(isStarred ? Color.yellow : Color.secondary)
            }
            .help(isStarred ? "Unstar" : "Star")
            Spacer()
            Button {
                flush()
                onDone()
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .help("Done")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.footnote)
        .padding(.top, 2)
    }

    private func toggleStar() {
        let base = title.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("*") {
            title = String(base.dropLast()).trimmingCharacters(in: .whitespaces)
        } else {
            title = base.isEmpty ? "*" : base + " *"
        }
    }

    // MARK: Autosave — same shape as the composer and the entry editor

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    /// `reindex: false` on the debounced path: typing writes the file without
    /// rebuilding the index, so the whole page doesn't re-render per keystroke.
    private func commit(reindex: Bool = false) {
        guard isDirty else { return }
        let raw = composed.raw
        switch item.source {
        case .inbox:          store.updateDraft(item.entry, newText: raw, reindex: reindex)
        case .archive(let d): store.updateFiledEntry(date: d, original: item.entry, newText: raw, reindex: reindex)
        case .journal(let n): store.updateJournalEntry(name: n, original: item.entry, newText: raw, reindex: reindex)
        }
        baselineRaw = raw
        pendingReindex = !reindex
    }

    /// Persist and make the store reload, so leaving the row shows what was
    /// saved. The reload is what refreshes the page: an in-place text edit
    /// changes neither an entry count nor a day's preview, so re-indexing alone
    /// wouldn't republish anything for the stream to pick up.
    private func flush() {
        saveTask?.cancel()
        if isDirty {
            commit()
            pendingReindex = true
        }
        if pendingReindex { store.reload() }
        pendingReindex = false
    }
}
