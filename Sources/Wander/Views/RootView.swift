//
//  RootView.swift
//  Wander
//
//  Masthead, heavy rule, three columns. Focus mode drops the outer two.
//

import SwiftUI

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
    @AppStorage("showIndex") private var showIndex = true
    @AppStorage("showMargin") private var showMargin = true
    @AppStorage("typewriter") private var typewriter = false
    @AppStorage("typeSize") private var typeSize = 17.5
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @Environment(\.colorScheme) private var systemScheme
    @State private var optionsOpen = false

    private var appearance: Binding<Appearance> {
        Binding(get: { Appearance(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }

    /// An explicit Light/Dark choice wins over the system's, for this view's
    /// own colours as well as its children's.
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
        // was stacking on the masthead's own padding and pushing the wordmark
        // well below the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .background(theme.paper.color)
        .environment(\.theme, theme)
        .environment(\.colorScheme, effectiveScheme)
        .preferredColorScheme(appearance.wrappedValue.colorScheme)
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
        .sheet(item: $store.reschedulingEntry) { entry in
            RescheduleSheet(entry: entry, store: store)
                .environment(\.theme, theme)
                .environment(\.colorScheme, effectiveScheme)
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
            // below the traffic lights rather than beside them — just clear of
            // the lights' 28pt band, and no further.
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
    /// thing waiting to be dealt with. A number on Starred would read as a
    /// badge for work outstanding, which starring isn't.
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

    /// Focus mode closes both columns; otherwise each is remembered separately.
    private var indexOpen: Bool { showIndex && !focusMode }
    private var marginOpen: Bool { showMargin && !focusMode }

    /// Two small-caps switches at the end of the running head — the only chrome
    /// the masthead carries.
    private var columnToggles: some View {
        HStack(spacing: 12) {
            Text("\u{2502}")
                .font(Face.sans(10))
                .foregroundStyle(theme.rule.color)
            QuietButton(title: "Index",
                        tone: indexOpen ? theme.accent : nil) {
                withAnimation(.easeOut(duration: 0.16)) { showIndex.toggle() }
            }
            .opacity(focusMode ? 0.4 : 1)
            QuietButton(title: "Margin",
                        tone: marginOpen ? theme.accent : nil) {
                withAnimation(.easeOut(duration: 0.16)) { showMargin.toggle() }
            }
            .opacity(focusMode ? 0.4 : 1)
            QuietButton(title: "Options", tone: optionsOpen ? theme.accent : nil) {
                optionsOpen.toggle()
            }
            .popover(isPresented: $optionsOpen, arrowEdge: .bottom) {
                OptionsPopover(store: store,
                               typeSize: $typeSize,
                               focusMode: Binding(get: { focusMode }, set: { focusMode = $0 }),
                               typewriter: Binding(get: { typewriter }, set: { typewriter = $0 }),
                               appearance: appearance,
                               showIndex: Binding(get: { showIndex }, set: { showIndex = $0 }),
                               showMargin: Binding(get: { showMargin }, set: { showMargin = $0 }))
                    .environment(\.theme, theme)
                    .environment(\.colorScheme, effectiveScheme)
            }
        }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            if indexOpen {
                SidebarView(store: store)
                    .frame(width: 250)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                VRule()
            }
            EditorView(store: store,
                       typeSize: $typeSize,
                       focusMode: focusMode,
                       typewriter: typewriter)
            if marginOpen {
                VRule()
                MarginView(store: store,
                           typeSize: $typeSize,
                           focusMode: Binding(get: { focusMode }, set: { focusMode = $0 }),
                           typewriter: Binding(get: { typewriter }, set: { typewriter = $0 }),
                           appearance: appearance)
                    .frame(width: 252)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity)
        .clipped()
    }
}
