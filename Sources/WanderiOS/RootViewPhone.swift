//
//  RootViewPhone.swift
//  wander (iOS)
//
//  Masthead, index, page. On iPad the two sit side by side; on a phone the
//  index pushes the page. The panels become sheets, because a 390pt window has
//  no margins to give away.
//

#if os(iOS)
import SwiftUI
import WanderCore

struct RootViewPhone: View {
    @ObservedObject var store: JournalStore
    @AppStorage("focusMode") private var focusMode = false
    @AppStorage("typewriter") private var typewriter = false
    @AppStorage("typeSize") private var typeSize = 17.5
    @AppStorage("lineSpacing") private var lineSpacing = 0.42
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @Environment(\.colorScheme) private var systemScheme
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var showingStats = false
    @State private var showingOptions = false

    private var appearance: Binding<Appearance> {
        Binding(get: { Appearance(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }

    private var effectiveScheme: ColorScheme {
        appearance.wrappedValue.colorScheme ?? systemScheme
    }

    private var theme: Theme { Theme.resolve(effectiveScheme) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            VStack(spacing: 0) {
                masthead
                SidebarView(store: store)
            }
            .background(theme.panel.color)
            .navigationBarHidden(true)
        } detail: {
            VStack(spacing: 0) {
                EditorView(store: store,
                           typeSize: $typeSize,
                           leading: $lineSpacing,
                           focusMode: focusMode,
                           typewriter: typewriter)
            }
            .background(theme.paper.color)
            .toolbar { toolbar }
            .toolbarBackground(theme.paper.color, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(theme.accent.color)
        .environment(\.theme, theme)
        .preferredColorScheme(appearance.wrappedValue.colorScheme)
        .sheet(isPresented: $showingStats) {
            panelSheet { StatsPanel(store: store) }
        }
        .sheet(isPresented: $showingOptions) {
            panelSheet {
                OptionsPanel(store: store,
                             typeSize: $typeSize,
                             leading: $lineSpacing,
                             focusMode: Binding(get: { focusMode }, set: { focusMode = $0 }),
                             typewriter: Binding(get: { typewriter }, set: { typewriter = $0 }),
                             appearance: appearance,
                             showIndex: .constant(true),
                             showStats: .constant(true),
                             showOptions: .constant(true))
            }
        }
        .sheet(item: $store.reschedulingEntry) { entry in
            RescheduleSheet(entry: entry, store: store)
                .environment(\.theme, theme)
        }
        .confirmationDialog("Delete this entry?",
                            isPresented: Binding(get: { store.deletionCandidate != nil },
                                                 set: { if !$0 { store.deletionCandidate = nil } }),
                            presenting: store.deletionCandidate) { entry in
            Button("Delete", role: .destructive) {
                store.delete(entry)
                store.deletionCandidate = nil
            }
        }
        .onChange(of: scenePhaseIsActive) { _, active in
            active ? store.reloadIfChanged() : store.flush()
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    private var scenePhaseIsActive: Bool { scenePhase == .active }

    private var masthead: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 13) {
                Text("wander")
                    .font(Face.serif(24, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.ink.color)
                ForEach(orderedPages, id: \.self) { page in
                    PageTab(title: label(for: page), active: page == store.page) {
                        withAnimation(.easeOut(duration: 0.14)) { store.show(page) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            Rule(weight: 2, tone: theme.ink)
                .padding(.horizontal, 16)
        }
    }

    private var orderedPages: [Page] {
        [store.page] + Page.allCases.filter { $0 != store.page }
    }

    private func label(for page: Page) -> String {
        guard page == .inbox else { return page.label }
        let count = store.count(of: .inbox)
        return count > 0 ? "\(page.label) \(count)" : page.label
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { store.newEntry() } label: { Image(systemName: "square.and.pencil") }
            Menu {
                Button("New Draft") { store.newDraft() }
                if let entry = store.selectedEntry {
                    Button(entry.isStarred ? "Unstar" : "Star") { store.toggleStar(entry) }
                    Button(store.isUnfiled(entry) ? "File" : "Return to Inbox") {
                        store.toggleFiling(entry)
                    }
                    Button("Date & Time…") { store.reschedulingEntry = entry }
                    Button("Copy Markdown") { store.copyMarkdown(entry) }
                    Divider()
                    Button("Delete…", role: .destructive) { store.deletionCandidate = entry }
                }
                Divider()
                Button("Stats") { showingStats = true }
                Button("Options") { showingOptions = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func panelSheet<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .environment(\.theme, theme)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
}
#endif
