//
//  RootView.swift
//  Wander
//
//  Masthead, heavy rule, then up to four columns: the index, the page being
//  written, and the two panels — Stats and Options. Each column slides.
//

import SwiftUI
import WanderCore

#if os(macOS)

struct RootView: View {
    @ObservedObject var store: JournalStore
    @AppStorage("focusMode") private var focusMode = false
    @AppStorage("typewriter") private var typewriter = false
    @AppStorage("typeSize") private var typeSize = 17.5
    @AppStorage("lineSpacing") private var lineSpacing = 0.3
    @AppStorage("showIndex") private var showIndex = true
    @AppStorage("showStats") private var showStats = true
    @AppStorage("showOptions") private var showOptions = false
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @AppStorage("theme") private var themeID = "almanac"
    @Environment(\.colorScheme) private var systemScheme
    @State private var showingThemes = false

    private var appearance: Binding<Appearance> {
        Binding(get: { Appearance(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }

    /// An explicit Light/Dark choice wins over the system's, for this view's own
    /// colours as well as its children's.
    private var effectiveScheme: ColorScheme {
        appearance.wrappedValue.colorScheme ?? systemScheme
    }

    private var theme: Theme { Theme.resolve(themeID, effectiveScheme) }

    var body: some View {
        VStack(spacing: 0) {
            masthead
            columns
        }
        // A hidden title bar still leaves SwiftUI a 28pt top safe area, which
        // stacked on the masthead's own padding and pushed the wordmark well
        // below the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .background(theme.paper.color)
        .environment(\.theme, theme)
        .environment(\.colorScheme, effectiveScheme)
        .preferredColorScheme(appearance.wrappedValue.colorScheme)
        .sheet(isPresented: $showingThemes) {
            ThemesSheet(themeID: Binding(get: { themeID }, set: { themeID = $0 }),
                        typeSize: $typeSize,
                        leading: $lineSpacing,
                        appearance: appearance)
                .environment(\.theme, theme)
                .environment(\.colorScheme, effectiveScheme)
        }
        .sheet(item: $store.reschedulingEntry) { entry in
            RescheduleSheet(entry: entry, store: store)
                .environment(\.theme, theme)
                .environment(\.colorScheme, effectiveScheme)
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: Binding(get: { store.deletionCandidate != nil },
                                 set: { if !$0 { store.deletionCandidate = nil } }),
            presenting: store.deletionCandidate
        ) { entry in
            Button("Delete", role: .destructive) {
                store.delete(entry)
                store.deletionCandidate = nil
            }
            Button("Keep", role: .cancel) { store.deletionCandidate = nil }
        } message: { entry in
            Text("“\(entry.preview.isEmpty ? "Untitled" : entry.preview)” will be removed from "
                 + "\(entry.source?.lastPathComponent ?? "the journal") on disk.")
        }
        .onAppear {
            DockIcon.apply(theme: themeID, dark: effectiveScheme == .dark)
            if ProcessInfo.processInfo.arguments.contains("--demo-themes") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingThemes = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openThemes)) { _ in
            showingThemes = true
        }
        .onChange(of: themeID) { _, id in DockIcon.apply(theme: id, dark: effectiveScheme == .dark) }
        .onChange(of: effectiveScheme) { _, scheme in
            DockIcon.apply(theme: themeID, dark: scheme == .dark)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reloadIfChanged()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willResignActiveNotification)) { _ in
            store.flush()
        }
    }

    // MARK: Masthead

    // MARK: Masthead — five settings, because these looks disagree about what a
    // masthead is: a ruled line, a solid band, a centred plate, a newspaper's
    // double rule, or nothing at all.

    @ViewBuilder
    private var masthead: some View {
        switch theme.mastheadStyle {
        case .band:    bandMasthead
        case .centred: centredMasthead
        case .double:  doubleMasthead
        case .none:    plainMasthead
        case .rule:    ruledMasthead
        }
    }

    private var wordmark: some View {
        Text("wander")
            .font(theme.display(26 * min(1.15, theme.displayScale + 0.15)))
            .tracking(theme.displayTracking)
            .textCase(theme.displayUppercase ? .uppercase : nil)
            .foregroundStyle(theme.ink.color)
    }

    private var mastheadRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            wordmark
            pages
            Spacer(minLength: 20)
            SmallCaps(runningHead)
            columnToggles
        }
        .padding(.leading, 34)
        .padding(.trailing, 34)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private var ruledMasthead: some View {
        VStack(spacing: 0) {
            mastheadRow
            Rule(weight: theme.mastheadRule, tone: theme.ink)
                .padding(.horizontal, 34)
        }
    }

    private var plainMasthead: some View {
        mastheadRow
    }

    /// A solid bar of ink with the type knocked out of it.
    private var bandMasthead: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("wander")
                .font(theme.display(24 * min(1.15, theme.displayScale + 0.15)))
                .tracking(theme.displayTracking)
                .textCase(theme.displayUppercase ? .uppercase : nil)
                .foregroundStyle(theme.paper.color)
            HStack(alignment: .firstTextBaseline, spacing: 13) {
                ForEach(orderedPages, id: \.self) { page in
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) { store.show(page) }
                    } label: {
                        SmallCaps(label(for: page),
                                  tone: page == store.page ? bandAccent : theme.paper.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 20)
            SmallCaps(runningHead, tone: theme.paper.opacity(0.65))
            columnToggles
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .background(theme.ink.color)
    }

    /// An accent that survives being put on the ink band — Brutalist's accent
    /// is the ink itself, and its tint is a yellow that only works as a fill.
    private var bandAccent: Tone { theme.accentOnBand }

    /// Wordmark on its own line, centred, the way a title page sets one.
    private var centredMasthead: some View {
        VStack(spacing: 6) {
            HStack {
                SmallCaps(runningHead)
                Spacer()
                columnToggles
            }
            wordmark
                .padding(.top, 2)
            pages
                .padding(.bottom, 2)
            Rule(weight: max(1, theme.mastheadRule), tone: theme.rule)
        }
        .padding(.leading, 72)
        .padding(.trailing, 34)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    /// Heavy rule, hairline under it, masthead centred between two slugs.
    private var doubleMasthead: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SmallCaps("No. \(Formats.groupNumber(store.selectedNumber ?? 1))")
                Spacer()
                wordmark
                Spacer()
                SmallCaps(Formats.longDay.string(from: Date()))
            }
            .padding(.bottom, 10)
            Rule(weight: 3, tone: theme.ink)
            Rule(tone: theme.ink).padding(.top, 3)
            HStack(spacing: 22) {
                pages
                Spacer()
                columnToggles
            }
            .padding(.top, 7)
        }
        .padding(.leading, 72)
        .padding(.trailing, 34)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    /// The page being read comes first, in accent; the rest follow in grey.
    private var pages: some View {
        HStack(alignment: .firstTextBaseline, spacing: 13) {
            ForEach(orderedPages, id: \.self) { page in
                PageTab(title: label(for: page), active: page == store.page) {
                    withAnimation(.easeOut(duration: 0.14)) { store.show(page) }
                }
            }
            if focusMode { SmallCaps("Focus", tone: theme.accent) }
        }
    }

    private var orderedPages: [Page] {
        [store.page] + Page.allCases.filter { $0 != store.page }
    }

    /// Only the inbox carries a count — it is a queue, and the number is the
    /// thing waiting to be dealt with. A number on Starred would read as a badge
    /// for work outstanding, which starring isn't.
    private func label(for page: Page) -> String {
        guard page == .inbox else { return page.label }
        let count = store.count(of: .inbox)
        return count > 0 ? "\(page.label) \(count)" : page.label
    }

    private var runningHead: String {
        var parts: [String] = []
        if let number = store.selectedNumber { parts.append("No. \(Formats.groupNumber(number))") }
        parts.append(Formats.longDay.string(from: Date()))
        if store.streak > 1 { parts.append("\(store.streak)-day streak") }
        return parts.joined(separator: " · ")
    }

    // MARK: Columns

    /// Focus mode closes every column; otherwise each is remembered separately.
    private var indexOpen: Bool { showIndex && !focusMode }
    private var statsOpen: Bool { showStats && !focusMode }
    private var optionsOpen: Bool { showOptions && !focusMode }

    private var columnToggles: some View {
        HStack(spacing: 12) {
            Text("\u{2502}")
                .font(theme.ui(10))
                .foregroundStyle(theme.rule.color)
            toggle("Index", open: indexOpen) { showIndex.toggle() }
            toggle("Stats", open: statsOpen) { showStats.toggle() }
            toggle("Options", open: optionsOpen) { showOptions.toggle() }
        }
    }

    private func toggle(_ title: String, open: Bool, action: @escaping () -> Void) -> some View {
        QuietButton(title: title, tone: open ? theme.accent : nil) {
            withAnimation(Motion.column) { action() }
        }
        .opacity(focusMode ? 0.4 : 1)
    }

    /// Broken grid's ghost numeral: the open entry's day.
    private var ghostCaption: String {
        guard let entry = store.selectedEntry else { return "" }
        return String(entry.date.suffix(2))
    }

    private var columns: some View {
        HStack(spacing: 0) {
            SlidingColumn(open: indexOpen, width: 250, ruleOn: .trailing) {
                SidebarView(store: store)
            }
            EditorView(store: store,
                       draft: store.draft,
                       typeSize: $typeSize,
                       leading: $lineSpacing,
                       focusMode: focusMode,
                       typewriter: typewriter,
                       ornamentCaption: ghostCaption)
                .layoutPriority(1)
            SlidingColumn(open: statsOpen, width: 252, ruleOn: .leading) {
                StatsPanel(store: store, draft: store.draft)
            }
            SlidingColumn(open: optionsOpen, width: 252, ruleOn: .leading) {
                OptionsPanel(store: store,
                             typeSize: $typeSize,
                             leading: $lineSpacing,
                             focusMode: Binding(get: { focusMode }, set: { focusMode = $0 }),
                             typewriter: Binding(get: { typewriter }, set: { typewriter = $0 }),
                             appearance: appearance,
                             showIndex: Binding(get: { showIndex }, set: { showIndex = $0 }),
                             showStats: Binding(get: { showStats }, set: { showStats = $0 }),
                             showOptions: Binding(get: { showOptions }, set: { showOptions = $0 }),
                             themeID: Binding(get: { themeID }, set: { themeID = $0 }),
                             showingThemes: $showingThemes)
            }
        }
        .frame(maxHeight: .infinity)
        .animation(Motion.column, value: indexOpen)
        .animation(Motion.column, value: statsOpen)
        .animation(Motion.column, value: optionsOpen)
    }
}

#endif
