//
//  RootViewPhone.swift
//  wander (iOS)
//
//  On iPad the index and the page sit side by side, as they do on the Mac. On a
//  phone there is only room for one, so the page is the root — you land in what
//  you were writing — and the index arrives as a sheet. Stats and Options are
//  sheets on both, because a 390pt window has no margins to give away.
//

#if os(iOS)
import SwiftUI
import WanderCore

struct RootViewPhone: View {
    @ObservedObject var store: JournalStore
    @AppStorage("focusMode") private var focusMode = false
    @AppStorage("typewriter") private var typewriter = false
    @AppStorage("typeSize") private var typeSize = 17.5
    @AppStorage("lineSpacing") private var lineSpacing = 0.3
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @AppStorage("theme") private var themeID = "almanac"
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingIndex = false
    /// iPad opens with the index showing; a notebook lies open at its contents.
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var showingStats = false
    @State private var showingOptions = false
    @State private var showingThemes = false

    private var appearance: Binding<Appearance> {
        Binding(get: { Appearance(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }

    private var effectiveScheme: ColorScheme {
        appearance.wrappedValue.colorScheme ?? systemScheme
    }

    private var theme: Theme { Theme.resolve(themeID, effectiveScheme) }

    var body: some View {
        presented
            .onAppear {
                // iOS refuses the icon swap while the scene is still coming up,
                // so ask once it has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    AppIconSwitcher.apply(theme: themeID)
                }
            }
            .onChange(of: themeID) { _, id in AppIconSwitcher.apply(theme: id) }
            .onChange(of: scenePhase) { _, phase in
                phase == .active ? store.reloadIfChanged() : store.flush()
            }
    }

    private var shell: some View {
        Group {
            if sizeClass == .compact {
                NavigationStack {
                    page
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { showingIndex = true } label: {
                                    Image(systemName: "list.bullet")
                                }
                            }
                            toolbar
                        }
                }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    index.navigationBarTitleDisplayMode(.inline)
                } detail: {
                    NavigationStack { page.toolbar { toolbar } }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .background(theme.paper.color.ignoresSafeArea())
    }

    private var styled: some View {
        shell
            .tint(theme.accent.color)
            .environment(\.theme, theme)
            .preferredColorScheme(appearance.wrappedValue.colorScheme)
    }

    private var presented: some View {
        styled
        .sheet(isPresented: $showingIndex) {
            index
                .environment(\.theme, theme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingStats) {
            StatsPanel(store: store, draft: store.draft)
                .environment(\.theme, theme)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingOptions) {
            OptionsPanel(store: store,
                         typeSize: $typeSize,
                         leading: $lineSpacing,
                         focusMode: Binding(get: { focusMode }, set: { focusMode = $0 }),
                         typewriter: Binding(get: { typewriter }, set: { typewriter = $0 }),
                         appearance: appearance,
                         showIndex: .constant(true),
                         showStats: .constant(true),
                         showOptions: .constant(true),
                         themeID: Binding(get: { themeID }, set: { themeID = $0 }),
                         showingThemes: $showingThemes)
                .environment(\.theme, theme)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingThemes) {
            // On a phone the themes are swiped through full size, not picked
            // off a grid of thumbnails.
            ThemeSwiper(themeID: Binding(get: { themeID }, set: { themeID = $0 }),
                        typeSize: $typeSize,
                        leading: $lineSpacing,
                        appearance: appearance)
                .environment(\.theme, theme)
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
    }

    // MARK: Pieces

    private var page: some View {
        EditorView(store: store,
                   draft: store.draft,
                   typeSize: $typeSize,
                   leading: $lineSpacing,
                   focusMode: focusMode,
                   typewriter: typewriter)
            .background(theme.paper.color.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.paper.color, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { wordmark }
            }
    }

    private var index: some View {
        VStack(spacing: 0) {
            pageSwitches
            SidebarView(store: store)
        }
        .background(theme.panel.color.ignoresSafeArea())
        .onChange(of: store.selection) { _, _ in showingIndex = false }
    }

    private var wordmark: some View {
        HStack(spacing: 8) {
            Text("wander")
                .font(theme.display(19))
                .tracking(theme.displayTracking)
                .textCase(theme.displayUppercase ? .uppercase : nil)
                .foregroundStyle(theme.ink.color)
                .fixedSize()
            SmallCaps(store.page.label, tone: theme.accent)
        }
    }

    /// The masthead, cut down to what a sheet needs: the wordmark and the three
    /// pages, over the heavy rule.
    private var pageSwitches: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 13) {
                Text("wander")
                    .font(theme.display(24))
                    .tracking(theme.displayTracking)
                    .textCase(theme.displayUppercase ? .uppercase : nil)
                    .foregroundStyle(theme.ink.color)
                    .fixedSize()
                ForEach(orderedPages, id: \.self) { page in
                    PageTab(title: label(for: page), active: page == store.page) {
                        withAnimation(.easeOut(duration: 0.14)) { store.show(page) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
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
                if let entry = store.selectedEntry {
                    Button(entry.isStarred ? "Unstar" : "Star") { store.toggleStar(entry) }
                    Button(store.isUnfiled(entry) ? "File" : "Return to Inbox") {
                        store.toggleFiling(entry)
                    }
                    Button("Date & Time\u{2026}") { store.reschedulingEntry = entry }
                    Button("Copy Markdown") { store.copyMarkdown(entry) }
                    Divider()
                    Button("Delete\u{2026}", role: .destructive) { store.deletionCandidate = entry }
                }
                Divider()
                Button("Stats") { showingStats = true }
                Button("Options") { showingOptions = true }
                Button("Themes\u{2026}") { showingThemes = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}
#endif
