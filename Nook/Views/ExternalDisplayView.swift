//
//  ExternalDisplayView.swift
//  Nook
//
//  Second-screen support. Plug an iPhone or iPad into a monitor and iOS mirrors
//  the app by default; declaring an external-display scene (see the scene
//  manifest in Nook/iOS/Info.plist, which points at
//  `ExternalDisplaySceneDelegate` below) opts out of mirroring and hands Nook
//  its own window on the monitor instead. Two things follow from that:
//
//  * the device panel becomes independent of the monitor, so dimming it no
//    longer dims what everyone else is looking at — which is what makes the
//    "Dim device screen" setting worth having, and
//  * the monitor can show something better suited to being read from across a
//    room than a phone UI blown up.
//
//  The external window follows what you're doing: composing puts a live wall of
//  the text on the monitor as you type, reading an entry lays it out with its
//  media inline, and with neither on screen it rests on an idle screen.
//
//  Cross-platform by design — the content model and the views compile on macOS
//  (where they go unused) and only the UIKit scene plumbing and the brightness
//  control are `#if os(iOS)`, so WritingView / EntryDetailView can call
//  `.externalDisplay(...)` without carrying a platform guard of their own.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - What the second screen is showing

enum ExternalDisplayContent: Equatable {
    /// Nothing selected anywhere — the monitor shows journal stats, and the
    /// hint bar tells you which keys get you out of it.
    case idle
    /// A list being arrowed through. Stats give way to this on the first ↑/↓.
    case browsing(listTitle: String, rows: [ExternalRow], selected: Int)
    /// The composer's live text, republished as you type.
    case composing(title: String, date: Date, text: String)
    /// An entry being read, rendered with its media inline.
    case reading(title: String, date: Date, text: String, isStarred: Bool)
}

/// One row of the browse list. A flattened copy rather than an `Entry` because
/// this crosses to the other scene every keystroke and only needs to be drawn.
struct ExternalRow: Equatable, Identifiable {
    let id: String        // the entry's timestamp
    let date: String      // ISO "YYYY-MM-DD"
    let title: String
    let starred: Bool

    /// Cap what's handed over: the monitor shows a window of about a dozen
    /// rows, so shipping a whole journal would be copying for nobody.
    static let maxRows = 300

    static func rows(from entries: [Entry]) -> [ExternalRow] {
        entries.prefix(maxRows).map {
            ExternalRow(id: $0.ts,
                        date: $0.date,
                        title: $0.preview,
                        starred: $0.isStarred)
        }
    }
}

// MARK: - Model

/// Shared state between the app's own scene and the external-display scene.
/// A singleton because the two scenes have separate view hierarchies: the
/// external window is built by a UIKit scene delegate, which can't reach the
/// app scene's environment (`@UIApplicationDelegateAdaptor` and any
/// `environmentObject` injected at the app root are both out of its reach).
@MainActor final class ExternalDisplayModel: ObservableObject {
    static let shared = ExternalDisplayModel()

    static let autoDimKey  = "dimWithExternalDisplay"
    static let dimLevelKey = "externalDisplayDimLevel"
    /// Dimmest the setting will go. Not 0 — a fully dark panel reads as a dead
    /// phone, and the last few percent of backlight are worth little anyway.
    static let dimFloor: Double = 0.02

    @Published private(set) var content: ExternalDisplayContent = .idle
    @Published private(set) var isConnected = false
    /// Set once by RootView so the external window can resolve `assets/…` links.
    /// Published so a display that was already plugged in at launch swaps off
    /// its placeholder as soon as the app's own scene comes up.
    @Published var store: JournalStore?
    /// Mirrored from the app's own window. An external-display scene gets its
    /// own trait collection, which does *not* follow the device's appearance —
    /// left to itself the monitor stays in light mode with the app in dark. So
    /// RootView pushes its resolved scheme here and the external window forces
    /// it, which also makes the Auto theme track the system on both screens.
    @Published var colorScheme: ColorScheme = .light

    /// The latest content regardless of whether anything is plugged in.
    /// `content` only tracks it while a display is attached — otherwise every
    /// keystroke in the composer would publish to nobody.
    private var latest: ExternalDisplayContent = .idle

    func present(_ new: ExternalDisplayContent) {
        latest = new
        // Nothing goes to the monitor while the app lock is up. The veil only
        // covers the device — the monitor is a window of its own, and left to
        // itself it would keep showing the entry that was open when the phone
        // was put down. `latest` is still kept, so unlocking restores it.
        guard !AppLockManager.shared.showsVeil else { return }
        if isConnected { content = new }
    }

    /// The app lock engaged or lifted (called by AppLockManager): the monitor
    /// falls back to the idle stats screen while covered, and picks up where it
    /// left off once the app is unlocked.
    func applyLockState(locked: Bool) {
        guard isConnected else { return }
        content = locked ? .idle : latest
    }

    /// Fall back to the idle screen, but only if `shown` is still what's up
    /// there. On a push the outgoing view's `onDisappear` can land *after* the
    /// incoming view has already claimed the screen, which would otherwise
    /// blank a display that just started showing something.
    func clear(ifShowing shown: ExternalDisplayContent) {
        guard latest == shown else { return }
        present(.idle)
    }

    /// Drop back to stats when a list loses its selection or goes away — but
    /// only from *that* list's browse screen, so a list disappearing behind a
    /// pushed entry doesn't yank the entry off the monitor.
    func clearBrowse(listTitle: String) {
        if case .browsing(let title, _, _) = latest, title == listTitle {
            present(.idle)
        }
    }

    #if os(iOS)

    /// The user's brightness before we touched it, so unplugging puts it back
    /// exactly. Nil whenever we haven't dimmed.
    private var brightnessToRestore: CGFloat?
    private var terminationObserver: NSObjectProtocol?

    func displayDidConnect() {
        isConnected = true
        content = latest
        applyAutoDim()
    }

    func displayDidDisconnect() {
        isConnected = false
        content = .idle
        restoreBrightness()
    }

    /// Re-evaluate the dim setting immediately rather than on the next
    /// reconnect — called from Settings so the toggle and slider feel live.
    func autoDimPreferenceChanged() {
        guard isConnected else { return }
        if UserDefaults.standard.bool(forKey: Self.autoDimKey) {
            applyAutoDim()
        } else {
            restoreBrightness()
        }
    }

    /// The screen the app's own window sits on — i.e. the built-in panel.
    /// `UIScreen.main` is deprecated; the application scene's screen is the
    /// supported way to get at it, and is the only screen whose `brightness`
    /// is writable.
    private var deviceScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }?
            .screen
    }

    private func applyAutoDim() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.autoDimKey), let screen = deviceScreen else { return }
        // Only capture the baseline on the first dim, so dragging the slider
        // doesn't overwrite it with our own dimmed value.
        if brightnessToRestore == nil { brightnessToRestore = screen.brightness }
        let level = defaults.object(forKey: Self.dimLevelKey) as? Double ?? Self.dimFloor
        screen.brightness = CGFloat(min(0.5, max(Self.dimFloor, level)))
        observeTermination()
    }

    private func restoreBrightness() {
        guard let saved = brightnessToRestore else { return }
        deviceScreen?.brightness = saved
        brightnessToRestore = nil
    }

    /// Unplugging restores brightness, but so must quitting — otherwise the
    /// device is left dark with nothing on screen to explain why.
    private func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ExternalDisplayModel.shared.restoreBrightness() }
        }
    }

    #endif
}

// MARK: - Scene plumbing (iOS)

#if os(iOS)
/// Delegate for the scene declared under
/// `UIWindowSceneSessionRoleExternalDisplayNonInteractive` in the iOS
/// Info.plist. Declaring that scene is what stops iOS mirroring the app; this
/// builds the window that takes the mirror's place.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard session.role == .windowExternalDisplayNonInteractive,
              let windowScene = scene as? UIWindowScene
        else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: ExternalDisplayRoot())
        // Shown but never made key — the device window keeps keyboard focus.
        window.isHidden = false
        self.window = window
        MainActor.assumeIsolated { ExternalDisplayModel.shared.displayDidConnect() }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard scene.session.role == .windowExternalDisplayNonInteractive else { return }
        window = nil
        MainActor.assumeIsolated { ExternalDisplayModel.shared.displayDidDisconnect() }
    }
}
#endif

// MARK: - Pushing content from the app's own views

extension View {
    /// Show `content` on the external display for as long as this view is on
    /// screen. A no-op on macOS, and nearly free on iOS with nothing plugged
    /// in — the model holds the value without republishing it.
    func externalDisplay(_ content: ExternalDisplayContent) -> some View {
        #if os(iOS)
        return modifier(ExternalDisplayPresenter(content: content))
        #else
        return self
        #endif
    }
}

private struct ExternalDisplayPresenter: ViewModifier {
    let content: ExternalDisplayContent

    func body(content view: Content) -> some View {
        view
            .onAppear { ExternalDisplayModel.shared.present(content) }
            .onChange(of: content) { _, new in ExternalDisplayModel.shared.present(new) }
            .onDisappear { ExternalDisplayModel.shared.clear(ifShowing: content) }
    }
}

// MARK: - Layout metrics

/// Type sized for the monitor rather than the phone. The app's own text-size
/// preference is calibrated for arm's length; an external display is usually
/// 1080p or better and read from across a room, so everything scales off the
/// panel's own height instead.
struct ExternalDisplayMetrics {
    let text: CGFloat
    let title: CGFloat
    let caption: CGFloat
    let padding: CGFloat
    let gap: CGFloat

    init(size: CGSize) {
        let height = max(size.height, 320)
        text    = min(58, max(22, height * 0.046))
        title   = text * 1.45
        caption = text * 0.52
        // TVs overscan and monitors have bezels; keep well inside both.
        padding = max(28, min(size.width, size.height) * 0.07)
        gap     = text * 0.9
    }
}

// MARK: - The window shown on the monitor

struct ExternalDisplayRoot: View {
    @ObservedObject private var model = ExternalDisplayModel.shared
    @AppStorage("colorScheme") private var colorSchemeRaw = AppColorScheme.auto.rawValue
    @AppStorage("accentColor")  private var accentRaw     = AccentTheme.blue.rawValue

    var body: some View {
        let accent = AccentTheme.color(forRaw: accentRaw)
        // Prefer the scheme RootView resolved for the device window; fall back
        // to the stored preference for the moment before the app scene is up.
        let scheme = model.store == nil
            ? (AppColorScheme(rawValue: colorSchemeRaw)?.resolved ?? model.colorScheme)
            : model.colorScheme
        GeometryReader { geo in
            let metrics = ExternalDisplayMetrics(size: geo.size)
            ZStack {
                ExternalBackground()
                // The store arrives with the app's own scene. A display plugged
                // in before launch connects first, so hold the idle screen
                // until it does — media links can't resolve without it.
                if let store = model.store {
                    VStack(spacing: 0) {
                        content(metrics: metrics)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ExternalHintBar(hints: hints, metrics: metrics)
                    }
                    .environmentObject(store)
                } else {
                    ExternalIdleView(metrics: metrics)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .tint(accent)
        .environment(\.accent, accent)
        // Both: `environment` settles this window's own subtree immediately,
        // `preferredColorScheme` settles the window behind it.
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(scheme)
    }

    @ViewBuilder
    private func content(metrics: ExternalDisplayMetrics) -> some View {
        switch model.content {
        case .idle:
            ExternalIdleView(metrics: metrics)
        case .browsing(let listTitle, let rows, let selected):
            ExternalBrowseView(listTitle: listTitle, rows: rows,
                               selected: selected, metrics: metrics)
        case .composing(let title, let date, let text):
            ExternalEntryView(title: title, date: date, text: text,
                              isStarred: false, live: true, metrics: metrics)
        case .reading(let title, let date, let text, let isStarred):
            ExternalEntryView(title: title, date: date, text: text,
                              isStarred: isStarred, live: false, metrics: metrics)
        }
    }

    /// Which keys are live right now. Shown on the monitor because the device
    /// screen is dimmed — there is nowhere else to read them.
    private var hints: [ShortcutHint] {
        switch model.content {
        case .idle:
            return [.init(key: "↑↓", label: "Browse"),
                    .init(key: "⌘N", label: "New"),
                    .init(key: "?",  label: "Hints")]
        case .browsing:
            return [.init(key: "↑↓", label: "Move"),
                    .init(key: "↩",  label: "Open"),
                    .init(key: "⎋",  label: "Back"),
                    .init(key: "⌘N", label: "New")]
        case .composing:
            // Only one of these: in the composer ⌘N and ⌘S both run newEntry()
            // — save this draft to the inbox and start a blank one — so listing
            // both implied a distinction that doesn't exist.
            return [.init(key: "⌘S", label: "Save & New"),
                    .init(key: "?",  label: "Hints")]
        case .reading:
            return [.init(key: "⎋",  label: "Back"),
                    .init(key: "⌘N", label: "New")]
        }
    }
}

/// The key prompts along the bottom of the monitor. Hidden with `?`.
private struct ExternalHintBar: View {
    let hints: [ShortcutHint]
    let metrics: ExternalDisplayMetrics

    @Environment(\.accent) private var accent
    @AppStorage(ShortcutHints.key) private var showHints = true

    var body: some View {
        if showHints && !hints.isEmpty {
            HStack(spacing: metrics.caption * 1.6) {
                ForEach(hints) { hint in
                    HStack(spacing: metrics.caption * 0.4) {
                        Text(hint.key)
                            .font(.system(size: metrics.caption * 0.95, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(hint.label)
                            .font(.system(size: metrics.caption * 0.95))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.horizontal, metrics.padding)
            .padding(.bottom, metrics.padding * 0.55)
            .padding(.top, metrics.caption * 0.6)
        }
    }
}

// MARK: - Browsing

/// The entry list as arrowed through on the device. Only a window of rows
/// around the selection is drawn — the monitor is for reading at a distance,
/// not for scrolling a whole journal past someone.
private struct ExternalBrowseView: View {
    let listTitle: String
    let rows: [ExternalRow]
    let selected: Int
    let metrics: ExternalDisplayMetrics

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accent) private var accent
    @AppStorage("writingFont") private var writingFontRaw = WritingFont.lato.rawValue
    @AppStorage("dateStyle")   private var dateStyleRaw   = DateStyle.weekday.rawValue

    /// Rows either side of the selection, clamped to the ends of the list.
    private var window: Range<Int> {
        let span = 9
        guard rows.count > span else { return 0..<rows.count }
        let half = span / 2
        let start = min(max(selected - half, 0), rows.count - span)
        return start..<(start + span)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap * 0.5) {
            header
            VStack(alignment: .leading, spacing: 0) {
                ForEach(window, id: \.self) { i in
                    row(rows[i], isSelected: i == selected)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: metrics.caption * 0.7) {
            HStack(alignment: .firstTextBaseline) {
                Text(listTitle.uppercased())
                    .tracking(metrics.caption * 0.18)
                Spacer(minLength: metrics.caption)
                Text("\(selected + 1) of \(rows.count)")
            }
            .font(.system(size: metrics.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(accent.opacity(0.35))
                .frame(maxWidth: .infinity)
                .frame(height: max(1, metrics.caption * 0.07))
        }
    }

    private func row(_ row: ExternalRow, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.caption) {
            Text(Theme.displayDate(row.date, style: dateStyleRaw))
                .font(.system(size: metrics.caption * 1.1, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: metrics.text * 6, alignment: .leading)
            Text(row.title.isEmpty ? "Untitled" : row.title)
                .font(Theme.font(writingFontRaw, size: metrics.text * 0.78))
                .foregroundStyle(row.title.isEmpty
                                 ? Theme.placeholder(colorScheme)
                                 : Theme.bodyText(colorScheme))
                .lineLimit(1)
            Spacer(minLength: 0)
            if row.starred {
                Image(systemName: "star.fill")
                    .font(.system(size: metrics.caption))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, metrics.caption * 0.45)
        .padding(.horizontal, metrics.caption * 0.6)
        .background(
            RoundedRectangle(cornerRadius: metrics.caption * 0.4)
                .fill(isSelected ? accent.opacity(0.22) : .clear)
        )
        .overlay(alignment: .leading) {
            // A bar on the selected row, so the highlight survives being
            // photographed off a projector or seen at a bad angle.
            if isSelected {
                Rectangle()
                    .fill(accent)
                    .frame(width: max(2, metrics.caption * 0.12))
            }
        }
    }
}

/// A flat, deliberate backdrop rather than the system grouped background —
/// projected large, system chrome colours read as "a phone screen on a wall".
private struct ExternalBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (colorScheme == .dark ? Color(white: 0.06) : Color(white: 0.97))
            .ignoresSafeArea()
    }
}

// MARK: - Entries (composing and reading share one layout)

/// The single layout the external display uses for an entry, whether you're
/// writing it or reading it. Composing and reading used to be two views that
/// drifted apart — same screen, different margins and header shapes — so they
/// are one view with a `live` flag now: the only differences are the caret and
/// whether the body renders media.
private struct ExternalEntryView: View {
    let title: String
    let date: Date
    let text: String
    let isStarred: Bool
    /// True while composing: adds the blinking caret and keeps the newest words
    /// in view. False when reading: the body renders its media inline instead.
    let live: Bool
    let metrics: ExternalDisplayMetrics

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accent) private var accent
    @AppStorage("writingFont") private var writingFontRaw = WritingFont.lato.rawValue
    @AppStorage("dateStyle")   private var dateStyleRaw   = DateStyle.weekday.rawValue

    @State private var caretVisible = true
    private let blink = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    private static let bottomAnchor = "nook.external.bottom"

    private var writingFont: Font { Theme.font(writingFontRaw, size: metrics.text) }
    private var displayTitle: String { Entry.strippingStarMarker(title) }
    private var starred: Bool { isStarred || Entry.hasStarMarker(title) }
    private var tags: [String] { JournalParser.splitTags(title + "\n" + text) }
    private var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
    private var isoDate: String { String(JournalStore.ts(from: date).prefix(10)) }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap) {
            header
            entryBody(for: text)
            footer
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    /// Runs the full width of the screen — date and star on an eyebrow row, the
    /// title beneath it, then a rule spanning edge to edge. A title that only
    /// stretched as far as its own text read as if it had been left unfinished.
    private var header: some View {
        VStack(alignment: .leading, spacing: metrics.caption * 0.7) {
            HStack(alignment: .firstTextBaseline) {
                Text(Theme.displayDate(isoDate, style: dateStyleRaw).uppercased())
                    .tracking(metrics.caption * 0.18)
                Spacer(minLength: metrics.caption)
                if starred {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
            }
            .font(.system(size: metrics.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !displayTitle.isEmpty {
                Text(displayTitle)
                    .font(Theme.font(writingFontRaw, size: metrics.title).weight(.bold))
                    .foregroundStyle(Theme.bodyText(colorScheme))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle()
                .fill(accent.opacity(0.35))
                .frame(maxWidth: .infinity)
                .frame(height: max(1, metrics.caption * 0.07))
        }
    }

    // MARK: Body

    @ViewBuilder
    private func entryBody(for text: String) -> some View {
        if live {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    liveText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Keep the newest words in view — nobody watching the
                    // monitor can scroll it themselves.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .onChange(of: text) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
        } else {
            // contentPadding 0: this view already supplies the margin, and a
            // second inset would indent a read entry further than a composed
            // one on the very same screen.
            MediaPreview(text: text,
                         font: writingFont,
                         textColor: Theme.bodyText(colorScheme),
                         contentPadding: 0)
        }
        Spacer(minLength: 0)
    }

    /// Body text with a blinking caret pinned to the end, so a reader can see
    /// the writing is live rather than a stale screenshot. The caret is a block
    /// element (U+258C) drawn in the system font rather than the writing font:
    /// Lato has no glyph for it, and the substituted one sat off the baseline.
    private var liveText: some View {
        let written = text.isEmpty
            ? Text(Theme.placeholderPrompts[0]).foregroundColor(Theme.placeholder(colorScheme))
            : Text(text).foregroundColor(Theme.bodyText(colorScheme))
        let caret = Text("▌")
            .font(.system(size: metrics.text))
            .foregroundColor(caretVisible ? accent : .clear)
        return (written.font(writingFont) + caret)
            .lineSpacing(Theme.lineSpacing(for: metrics.text))
            .onReceive(blink) { _ in caretVisible.toggle() }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if tags.isEmpty {
                Text(" ")
            } else {
                Text(tags.joined(separator: "  "))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.caption)
            Text(wordCount == 1 ? "1 word" : "\(wordCount) words")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: metrics.caption))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Idle (stats)

/// What the monitor rests on with nothing selected: the journal at a glance.
/// The numbers come from the App Group snapshot the widget already reads, so
/// resting here costs no journal I/O — and the hint bar under it is what tells
/// you the arrow keys will turn this into the browser.
private struct ExternalIdleView: View {
    let metrics: ExternalDisplayMetrics

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accent) private var accent
    @AppStorage("writingFont") private var writingFontRaw = WritingFont.lato.rawValue
    @AppStorage("dateStyle")   private var dateStyleRaw   = DateStyle.weekday.rawValue

    @State private var snapshot = NookSnapshot.load()

    private var today: String {
        Theme.displayDate(String(JournalStore.ts(from: Date()).prefix(10)), style: dateStyleRaw)
    }

    private var tiles: [(value: String, label: String, accented: Bool)] {
        [(Self.short(snapshot.currentStreak), snapshot.currentStreak == 1 ? "day streak" : "day streak", true),
         (Self.short(snapshot.totalDays),     "days written",  false),
         (Self.short(snapshot.totalWords),    "words",         false),
         (Self.short(snapshot.inboxDrafts),   snapshot.inboxDrafts == 1 ? "draft" : "drafts", false)]
    }

    /// 47,000 words is noise at this size; 47k reads at a glance.
    private static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fm", Double(n) / 1_000_000) }
        if n >= 10_000    { return "\(n / 1000)k" }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap) {
            header
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    VStack(spacing: metrics.caption * 0.45) {
                        Text(tile.value)
                            .font(.system(size: metrics.title * 1.15, weight: .bold))
                            .foregroundStyle(tile.accented ? accent : Theme.bodyText(colorScheme))
                        Text(tile.label)
                            .font(.system(size: metrics.caption))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if let preview = snapshot.onThisDayPreview, !preview.isEmpty,
               let ago = snapshot.onThisDayYearsAgo {
                Text("On this day, \(ago) year\(ago == 1 ? "" : "s") ago — \(preview)")
                    .font(.system(size: metrics.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Spacer(minLength: 0)
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Cheap: re-reads the shared snapshot, not the journal.
        .onAppear { snapshot = NookSnapshot.load() }
    }

    /// Same eyebrow-title-rule shape as an entry, so resting on stats doesn't
    /// look like a different app from writing in one.
    private var header: some View {
        VStack(alignment: .leading, spacing: metrics.caption * 0.7) {
            Text(today.uppercased())
                .font(.system(size: metrics.caption, weight: .semibold))
                .tracking(metrics.caption * 0.18)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Nook")
                .font(Theme.font(writingFontRaw, size: metrics.title).weight(.bold))
                .foregroundStyle(Theme.bodyText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle()
                .fill(accent.opacity(0.35))
                .frame(maxWidth: .infinity)
                .frame(height: max(1, metrics.caption * 0.07))
        }
    }
}
