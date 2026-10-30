//
//  ExternalDisplayView.swift
//  Quire
//
//  Second-screen support. Plug an iPhone or iPad into a monitor and iOS mirrors
//  the app by default; declaring an external-display scene (see the scene
//  manifest in Quire/iOS/Info.plist, which points at
//  `ExternalDisplaySceneDelegate` below) opts out of mirroring and hands Quire
//  its own window on the monitor instead. Two things follow from that:
//
//  * the device panel becomes independent of the monitor, so dimming it no
//    longer dims what everyone else is looking at — which is what makes the
//    "Dim device screen" setting worth having, and
//  * the monitor can show something better suited to being read from across a
//    room than a phone UI blown up.
//
//  The external window follows what you're doing: composing (or editing an
//  entry) mirrors the editor on the monitor as you type — same styling, and a
//  caret that tracks the phone's, so the monitor scrolls to where you are
//  rather than to the end — reading an entry lays it out with its media
//  inline, and with neither on screen it rests on an idle screen.
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
    case browsing(listTitle: String, rows: [ExternalRow], selected: Int, offset: Int = 0, total: Int? = nil)
    /// The composer's live text, republished as you type. `caret` is the
    /// editor's caret (a UTF-16 offset), nil while the body isn't focused;
    /// `inTitle` is set while the title field has the cursor instead.
    case composing(title: String, date: Date, text: String, caret: Int?, inTitle: Bool = false)
    /// An existing entry open in its editor — the same live mirror as the
    /// composer, with the entry editor's own key hints.
    case editing(title: String, date: Date, text: String, caret: Int?, isStarred: Bool, isDraft: Bool = false, inTitle: Bool = false)
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
    /// "08:12", and the start of the entry, for the preview beside the list.
    let time: String
    let body: String

    static let maxRows = 300

    static func rows(from entries: [Entry]) -> [ExternalRow] {
        entries.prefix(maxRows).map {
            ExternalRow(id: $0.id,
                        date: $0.date,
                        title: $0.preview,
                        starred: $0.isStarred,
                        time: String($0.ts.dropFirst(11).prefix(5)),
                        body: String($0.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500)))
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

    @Published private(set) var isPaused = false
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

    #if os(iOS)
    /// How the monitor lays out the live entry's body, so ↑/↓ on the phone
    /// move by the monitor's lines rather than the phone's (`PastingTextView`).
    /// Set by whichever monitor page shows the body: given the body text, it
    /// returns a text view holding it, broken into lines as the monitor breaks it.
    var bodyLayout: ((String) -> UITextView?)?
    #endif

    /// The latest content regardless of whether anything is plugged in.
    /// `content` only tracks it while a display is attached — otherwise every
    /// keystroke in the composer would publish to nobody.
    private var latest: ExternalDisplayContent = .idle

    private var pageOwner: UUID?
    private var pendingUnderlay: ExternalDisplayContent?

    /// Lists can refresh beneath a presented page; they must not replace it.
    func present(_ new: ExternalDisplayContent, owner: UUID? = nil) {
        if let owner { pageOwner = owner }
        else if pageOwner != nil {
            switch new {
            case .browsing, .idle: pendingUnderlay = new; return
            default: break
            }
        }
        latest = new
        // Nothing goes to the monitor while the app lock is up. The veil only
        // covers the device — the monitor is a window of its own, and left to
        // itself it would keep showing the entry that was open when the phone
        // was put down. `latest` is still kept, so unlocking restores it.
        guard !AppLockManager.shared.showsVeil, !isPaused else { return }
        if isConnected { content = new }
    }

    func releasePage(owner: UUID) {
        guard pageOwner == owner else { return }
        pageOwner = nil
        let next = pendingUnderlay ?? .idle
        pendingUnderlay = nil
        present(next)
    }

    /// The app lock engaged or lifted (called by AppLockManager): the monitor
    /// falls back to the idle stats screen while covered, and picks up where it
    /// left off once the app is unlocked.
    func applyLockState(locked: Bool) {
        updateIdleTimer()
        guard isConnected else { return }
        content = locked || isPaused ? .idle : latest
    }

    /// Fall back to the idle screen, but only if `shown` is still what's up
    /// there. On a push the outgoing view's `onDisappear` can land *after* the
    /// incoming view has already claimed the screen, which would otherwise
    /// blank a display that just started showing something.
    func clear(ifShowing shown: ExternalDisplayContent) {
        if pendingUnderlay == shown { pendingUnderlay = nil }
        guard latest == shown else { return }
        present(.idle)
    }

    /// An entry page leaving: back to idle only if the monitor still shows that
    /// kind of page (being read, or being written when `writing`). A list that
    /// has already come back underneath and published itself stays up.
    func clearEntry(writing: Bool) {
        switch latest {
        case .reading: if !writing { present(.idle) }
        case .composing, .editing: if writing { present(.idle) }
        default: break
        }
    }

    func togglePause() {
        guard isConnected else { return }
        isPaused.toggle()
        updateIdleTimer()
        content = isPaused || AppLockManager.shared.showsVeil ? .idle : latest
    }
    func adjustTextSize(_ delta: Int) {
        guard isConnected else { return }
        let all = ExternalTextSize.allCases
        let current = UserDefaults.standard.string(forKey: ExternalTextSize.key) ?? ExternalTextSize.regular.rawValue
        let index = all.firstIndex { $0.rawValue == current } ?? 1
        UserDefaults.standard.set(all[min(all.count - 1, max(0, index + delta))].rawValue, forKey: ExternalTextSize.key)
    }
    func cycleTheme() {
        guard isConnected else { return }
        let ids = ExternalTheme.monitorIDs
        let current = UserDefaults.standard.string(forKey: ExternalTheme.key) ?? ExternalTheme.followPhone
        let index = ids.firstIndex(of: current) ?? 0
        UserDefaults.standard.set(ids[(index + 1) % ids.count], forKey: ExternalTheme.key)
    }

    /// Drop back to stats when a list loses its selection or goes away — but
    /// only from *that* list's browse screen, so a list disappearing behind a
    /// pushed entry doesn't yank the entry off the monitor.
    func clearBrowse(listTitle: String) {
        if case .browsing(let title, _, _, _, _) = latest, title == listTitle {
            present(.idle)
        }
    }

    #if !os(iOS)
    func updateIdleTimer() {}
    #endif

    #if os(iOS)

    /// Staying awake is independent of dimming the phone panel.
    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isConnected && !isPaused
            && !AppLockManager.shared.showsVeil && UIApplication.shared.applicationState == .active
    }

    /// The user's brightness before we touched it, so unplugging puts it back
    /// exactly. Nil whenever we haven't dimmed.
    private var brightnessToRestore: CGFloat?
    private var terminationObserver: NSObjectProtocol?

    func displayDidConnect() {
        isConnected = true
        updateIdleTimer()
        // Not `latest` while the app is locked or veiled: a phone plugged in
        // from the lock screen would otherwise put the open entry straight
        // up on the monitor. `applyLockState` restores it on unlock.
        content = AppLockManager.shared.showsVeil || isPaused ? .idle : latest
        applyAutoDim()
    }

    /// `QUIRE_DESK` screenshots: behave as if a display were attached.
    func previewConnected() {
        isConnected = true
        content = latest
    }

    func displayDidDisconnect() {
        ExternalSettingsModel.shared.close()
        isConnected = false
        updateIdleTimer()
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

/// How big the monitor's type is (`Settings → External display → Text size`).
/// One scale for everything on that screen — a desk monitor and a TV across
/// the room want different sizes, and the panel's height alone can't tell
/// which it is driving.
enum ExternalTextSize: String, CaseIterable, Identifiable {
    case small, regular, large
    var id: String { rawValue }
    static let key = "externalDisplayTextSize"

    var label: String {
        switch self {
        case .small:   return "Small"
        case .regular: return "Regular"
        case .large:   return "Large"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small:   return 0.8
        case .regular: return 1
        case .large:   return 1.25
        }
    }
}

/// Type sized for the monitor rather than the phone. The app's own text-size
/// preference is calibrated for arm's length (and Dynamic Type scales it
/// again), so everything here scales off the panel's own height instead —
/// sized for a desk monitor by default, with `ExternalTextSize` to push it
/// up for a screen read from across a room.
struct ExternalDisplayMetrics {
    let text: CGFloat
    let title: CGFloat
    let caption: CGFloat
    let padding: CGFloat
    let gap: CGFloat

    init(size: CGSize, scale: CGFloat = 1) {
        let height = max(size.height, 320)
        // ~35pt on a 1080p panel at Regular; it was ~50, which was built for
        // a TV and read as a billboard on a desk.
        text    = min(48, max(16, height * 0.032 * scale))
        title   = text * 1.45
        caption = max(13, text * 0.52)
        // TVs overscan and monitors have bezels; keep well inside both.
        padding = max(28, min(size.width, size.height) * 0.06)
        gap     = text * 0.9
    }
}
