//
//  RootView.swift
//  Wander
//
//  Masthead, heavy rule, then up to four columns: the index, the page being
//  written, and the two panels — Stats and Options. Each column slides.
//

import SwiftUI
import WanderCore

enum Appearance: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "Auto"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var next: Appearance {
        let all = Appearance.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

struct RootView: View {
    @ObservedObject var store: JournalStore
    @AppStorage("focusMode") private var focusMode = false
    @AppStorage("typewriter") private var typewriter = false
    @AppStorage("typeSize") private var typeSize = 17.5
    @AppStorage("lineSpacing") private var lineSpacing = 0.42
    @AppStorage("showIndex") private var showIndex = true
    @AppStorage("showStats") private var showStats = true
    @AppStorage("showOptions") private var showOptions = false
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @Environment(\.colorScheme) private var systemScheme

    private var appearance: Binding<Appearance> {
        Binding(get: { Appearance(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }

    /// An explicit Light/Dark choice wins over the system's, for this view's own
    /// colours as well as its children's.
    private var effectiveScheme: ColorScheme {
        appearance.wrappedValue.colorScheme ?? systemScheme
    }

    private var theme: Theme { Theme.resolve(effectiveScheme) }

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
        .onAppear { DockIcon.apply(for: effectiveScheme) }
        .onChange(of: effectiveScheme) { _, scheme in DockIcon.apply(for: scheme) }
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

    private var masthead: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("wander")
                    .font(Face.serif(26, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.ink.color)
                pages
                Spacer(minLength: 20)
                SmallCaps(runningHead)
                columnToggles
            }
            // The wordmark keeps the page's left margin, so the masthead sits
            // below the traffic lights rather than beside them.
            .padding(.leading, 34)
            .padding(.trailing, 34)
            .padding(.top, 22)
            .padding(.bottom, 8)
            Rule(weight: 2, tone: theme.ink)
                .padding(.horizontal, 34)
        }
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
                .font(Face.sans(10))
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

    /// A column that slides rather than appears: the content keeps its width and
    /// the frame around it closes, so the panel travels off its own edge instead
    /// of reflowing as it goes.
    @ViewBuilder
    private func sliding<V: View>(_ open: Bool, width: CGFloat, ruleOn edge: HorizontalEdge,
                                  @ViewBuilder content: () -> V) -> some View {
        HStack(spacing: 0) {
            if edge == .leading { VRule() }
            content().frame(width: width)
            if edge == .trailing { VRule() }
        }
        .frame(width: open ? width + 1 : 0,
               alignment: edge == .trailing ? .trailing : .leading)
        .clipped()
        .opacity(open ? 1 : 0)
    }

    private var columns: some View {
        HStack(spacing: 0) {
            sliding(indexOpen, width: 250, ruleOn: .trailing) {
                SidebarView(store: store)
            }
            EditorView(store: store,
                       typeSize: $typeSize,
                       leading: $lineSpacing,
                       focusMode: focusMode,
                       typewriter: typewriter)
                .layoutPriority(1)
            sliding(statsOpen, width: 252, ruleOn: .leading) {
                StatsPanel(store: store)
            }
            sliding(optionsOpen, width: 252, ruleOn: .leading) {
                OptionsPanel(store: store,
                             typeSize: $typeSize,
                             leading: $lineSpacing,
                             focusMode: Binding(get: { focusMode }, set: { focusMode = $0 }),
                             typewriter: Binding(get: { typewriter }, set: { typewriter = $0 }),
                             appearance: appearance,
                             showIndex: Binding(get: { showIndex }, set: { showIndex = $0 }),
                             showStats: Binding(get: { showStats }, set: { showStats = $0 }),
                             showOptions: Binding(get: { showOptions }, set: { showOptions = $0 }))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(Motion.column, value: indexOpen)
        .animation(Motion.column, value: statsOpen)
        .animation(Motion.column, value: optionsOpen)
    }
}
