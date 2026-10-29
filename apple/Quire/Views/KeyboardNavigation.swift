//
//  KeyboardNavigation.swift
//  Quire
//
//  Arrow-key navigation over an entry list, shared by the Inbox and by
//  EntryTwoPane (Journal, Starred, a day, a split journal). It exists for the
//  second screen — with the device dimmed and a keyboard attached you need to
//  drive the app without looking at it — but it isn't conditional on one being
//  connected: the same keys are worth having on an iPad with a keyboard, and a
//  selection that only existed while a monitor was plugged in would be a second
//  selection model to keep in step with the real one.
//
//  The host view owns the index (so it can highlight and scroll to the row) and
//  hands it here as a binding; this adds the key handling and mirrors the
//  selection to the external display.
//
//  ## Why the two platforms take different routes
//
//  macOS uses SwiftUI's `onKeyPress`, which needs the view focused — fine there,
//  where a list takes keyboard focus as a matter of course.
//
//  iOS can't use it. `onKeyPress` also requires focus, and on iOS a *non-text*
//  view only ever receives keyboard focus when the user has switched on
//  Accessibility ▸ Keyboards ▸ Full Keyboard Access. With it off — i.e. for
//  almost everyone — a `focusable()` list is never focused and not one key event
//  arrives. So iOS goes through `UIKeyCommand` instead, declared on the app
//  delegate: a `UIResponder` app delegate sits at the end of the responder
//  chain, so its commands fire for keys nothing else claimed. That ordering is
//  also what keeps typing safe — a focused text field is *earlier* in the chain,
//  so it takes the arrows and `?` for itself and they never reach us.
//
//  Because those commands are global, they need to know which list is on screen:
//  `KeyCommandRouter` holds a stack of handlers that lists push while visible.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Hints

/// Whether the external display draws its keyboard hint bar. Toggled with `?`,
/// and remembered — once you know the keys the prompt is just clutter.
enum ShortcutHints {
    static let key = "showShortcutHints"

    static func toggle() {
        let defaults = UserDefaults.standard
        // Registered nowhere, so absent means on.
        let current = defaults.object(forKey: key) as? Bool ?? true
        defaults.set(!current, forKey: key)
    }
}

/// One key prompt: the glyph and what it does.
struct ShortcutHint: Identifiable, Equatable {
    let key: String
    let label: String
    var id: String { key + label }
}

// MARK: - Router

/// What the currently-visible list wants done with the navigation keys.
struct QuireKeyHandlers {
    var moveUp: () -> Void
    var moveDown: () -> Void
    var open: () -> Void
    var clear: () -> Void
    /// The TUI's single letters (`n`, `i`, `f`, `e`…): true if handled.
    var key: (String) -> Bool = { _ in false }
    /// Control chords while writing (`^j` file, `^s` save, `^t`, `^f`, `^p`, `^d`).
    /// They are only declared to the system while a handler wants them, so the
    /// text system's own Emacs-style bindings are untouched everywhere else.
    var wantsChords = false
    var chord: (String) -> Bool = { _ in false }
}

/// Routes the app-wide key commands to whichever list is on screen. A stack
/// rather than a single slot: pushing an entry over a list leaves the list
/// registered underneath, so popping back doesn't lose the keys.
@MainActor final class KeyCommandRouter {
    static let shared = KeyCommandRouter()

    /// `active` false: a list with no rows. It keeps its place in the stack, so
    /// when its first row arrives it doesn't float above whatever was pushed
    /// over it since (the composer), but it handles nothing meanwhile.
    private var stack: [(id: UUID, handlers: QuireKeyHandlers, active: Bool)] = []

    /// Push a list's handlers, or refresh an already-registered list's in place.
    /// In place matters: a list re-registers whenever its rows change, which a
    /// store reload does even while it sits under a pushed view — removing and
    /// re-appending would float that hidden list back to the top of the stack
    /// and hand it the arrow keys.
    func register(_ id: UUID, _ handlers: QuireKeyHandlers) {
        if let i = stack.firstIndex(where: { $0.id == id }) {
            stack[i].handlers = handlers
            stack[i].active = true
        } else {
            stack.append((id, handlers, true))
        }
    }

    /// Keep `id`'s place but pass every key to what's beneath it.
    func deactivate(_ id: UUID) {
        if let i = stack.firstIndex(where: { $0.id == id }) {
            stack[i].active = false
        } else {
            stack.append((id, QuireKeyHandlers(moveUp: {}, moveDown: {}, open: {}, clear: {}), false))
        }
    }

    func unregister(_ id: UUID) {
        stack.removeAll { $0.id == id }
    }

    /// Nothing acts while App Lock is up: the journal is hidden, so are its keys.
    private var top: QuireKeyHandlers? {
        guard !AppLockManager.shared.showsVeil else { return nil }
        return stack.last(where: { $0.active })?.handlers
    }

    @discardableResult func moveUp()   -> Bool { run { $0.moveUp() } }
    @discardableResult func moveDown() -> Bool { run { $0.moveDown() } }
    @discardableResult func open()      -> Bool { run { $0.open() } }
    @discardableResult func clear()     -> Bool { run { $0.clear() } }

    /// What Esc does when nothing is selected: back to Today (set by the root).
    var onBack: (() -> Void)?

    /// Whether the visible page wants the control chords declared.
    var wantsChords: Bool { top?.wantsChords ?? false }

    /// The composer's control chords: file, save, time, focus, prompt, discard.
    static let chords = ["j", "s", "t", "f", "p", "d"]

    @discardableResult func chord(_ k: String) -> Bool {
        guard let top, top.wantsChords else { return false }
        return top.chord(k)
    }

    /// A letter: the visible list gets first refusal, then whatever is
    /// registered beneath it (the app's own tab keys).
    @discardableResult func key(_ k: String) -> Bool {
        guard !AppLockManager.shared.showsVeil else { return false }
        for entry in stack.reversed() where entry.active && entry.handlers.key(k) { return true }
        return false
    }

    private func run(_ body: (QuireKeyHandlers) -> Void) -> Bool {
        guard let top else { return false }
        body(top)
        return true
    }
}

// MARK: - First-responder catcher (iOS)

#if os(iOS)
/// Declares the navigation key commands right next to the list, and takes first
/// responder while the list is on screen.
///
/// The app delegate declares the same commands as a backstop, but it sits at the
/// very end of the responder chain — anything in between (SwiftUI's hosting
/// controller, a scroll view) that claims the arrows would swallow them first.
/// This sits at the *start* of the chain instead, so the keys are seen before
/// anything can eat them. UIKit dispatches a command to the first responder in
/// the chain that declares it, so having both places declare them dispatches
/// once, never twice.
///
/// Tapping a text field makes *it* first responder, which is exactly what keeps
/// typing intact: the arrows, Return and `?` go to the field and never reach us.
struct KeyCommandCatcher: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyCommandController { KeyCommandController() }
    func updateUIViewController(_ controller: KeyCommandController, context: Context) {}
}

final class KeyCommandController: UIViewController {
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let arrows = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow,   modifierFlags: [], action: #selector(moveUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(moveDown)),
        ]
        // Otherwise the enclosing scroll view scrolls instead of moving the row.
        for command in arrows { command.wantsPriorityOverSystemBehavior = true }
        // The terminal app's letters, and the composer's control chords while it is
        // open. Declared here as well as on the app delegate: the delegate is not
        // reliably in the responder chain under SwiftUI's lifecycle, this is.
        let letters = ["n", "i", "j", "k", "l", "/", "r", "f", "e", "t", "d", "u", "p", ",", "*"]
            .map { UIKeyCommand(input: $0, modifierFlags: [], action: #selector(letter(_:))) }
        let chords: [UIKeyCommand] = KeyCommandRouter.shared.wantsChords
            ? ["j", "s", "t", "f", "p", "d"].map {
                let c = UIKeyCommand(input: $0, modifierFlags: .control, action: #selector(chord(_:)))
                c.wantsPriorityOverSystemBehavior = true
                return c
            } : []
        let display: [UIKeyCommand] = ExternalDisplayModel.shared.isConnected ? [
            UIKeyCommand(input: "=", modifierFlags: [.command, .alternate], action: #selector(displayLarger)),
            UIKeyCommand(input: "+", modifierFlags: [.command, .alternate], action: #selector(displayLarger)),
            UIKeyCommand(input: "-", modifierFlags: [.command, .alternate], action: #selector(displaySmaller)),
            UIKeyCommand(input: "t", modifierFlags: [.command, .alternate], action: #selector(displayTheme)),
            UIKeyCommand(input: "p", modifierFlags: [.command, .alternate], action: #selector(displayPause)),
            UIKeyCommand(input: "h", modifierFlags: [.command, .alternate], action: #selector(toggleHints)),
        ] : []
        return arrows + letters + chords + display + [
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(openSelection)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(clearSelection)),
            UIKeyCommand(input: "?", modifierFlags: [], action: #selector(toggleHints)),
        ]
    }

    @objc private func letter(_ command: UIKeyCommand) {
        if let input = command.input { KeyCommandRouter.shared.key(input) }
    }
    @objc private func chord(_ command: UIKeyCommand) {
        if let input = command.input { KeyCommandRouter.shared.chord(input) }
    }
    @objc private func displayLarger() { ExternalDisplayModel.shared.adjustTextSize(1) }
    @objc private func displaySmaller() { ExternalDisplayModel.shared.adjustTextSize(-1) }
    @objc private func displayTheme() { ExternalDisplayModel.shared.cycleTheme() }
    @objc private func displayPause() { ExternalDisplayModel.shared.togglePause() }

    private var reclaim: Timer?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // A push or a sheet taking down another catcher leaves the window with no
        // first responder, and then no key reaches the app. Take it back, but only
        // when nothing (a text field) holds it.
        reclaim?.invalidate()
        reclaim = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, let window = self.view.window, !self.isFirstResponder else { return }
            // Anything that isn't taking typed text may give the keys up, but not
            // another catcher: two visible ones would trade it back and forth.
            let holder = window.firstResponder
            if !(holder is UIKeyInput), !(holder is KeyCommandController) { self.becomeFirstResponder() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        reclaim?.invalidate()
        reclaim = nil
    }

    /// Reclaim the keys after a text field (search, an editor) hands them back.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.window != nil, !isFirstResponder else { return }
        // Only if nothing else wants them — never yank focus out of a field.
        if view.window?.firstResponder == nil { becomeFirstResponder() }
    }

    @objc private func moveUp()   { KeyCommandRouter.shared.moveUp() }
    @objc private func moveDown() { KeyCommandRouter.shared.moveDown() }
    @objc private func openSelection()  { KeyCommandRouter.shared.open() }
    @objc private func clearSelection() { KeyCommandRouter.shared.clear() }
    @objc private func toggleHints()    { ShortcutHints.toggle() }
}

private extension UIWindow {
    /// The current first responder in this window, if any.
    var firstResponder: UIResponder? {
        guard let responder = Self.currentFirstResponder() else { return nil }
        return responder
    }

    static func currentFirstResponder() -> UIResponder? {
        captured = nil
        UIApplication.shared.sendAction(#selector(UIResponder.quire_captureFirstResponder),
                                        to: nil, from: nil, for: nil)
        return captured
    }

    static var captured: UIResponder? {
        get { UIResponder.quire_capturedResponder }
        set { UIResponder.quire_capturedResponder = newValue }
    }
}

extension UIResponder {
    fileprivate static var quire_capturedResponder: UIResponder?

    @objc fileprivate func quire_captureFirstResponder() {
        UIResponder.quire_capturedResponder = self
    }
}
#endif

// MARK: - Row highlight

extension View {
    /// Tint the row the keyboard selection is on. Applied conditionally, and
    /// deliberately: handing every *other* row a `Color.clear` background would
    /// strip the inset-grouped card iOS draws them on.
    @ViewBuilder
    func keyboardSelectedRow(_ selected: Bool, accent: Color) -> some View {
        if selected {
            listRowBackground(accent.opacity(0.18))
        } else {
            self
        }
    }
}

// MARK: - List navigation

extension View {
    /// Arrow-key selection over `entries`. `index` is the host's selection, so
    /// the list can highlight and scroll to it; `onOpen` fires on Return.
    func entryListNavigation(entries: [Entry],
                             index: Binding<Int?>,
                             listTitle: String,
                             onOpen: @escaping (Entry) -> Void) -> some View {
        modifier(EntryListNavigation(entries: entries,
                                     index: index,
                                     listTitle: listTitle,
                                     onOpen: onOpen))
    }
}

private struct EntryListNavigation: ViewModifier {
    let entries: [Entry]
    @Binding var index: Int?
    let listTitle: String
    let onOpen: (Entry) -> Void

    /// Identifies this list to the router for the lifetime of the view.
    @State private var routerID = UUID()
    #if os(macOS)
    @FocusState private var focused: Bool
    #endif

    func body(content: Content) -> some View {
        base(content)
            .onAppear { register(); publish() }
            .onChange(of: index) { _, _ in register(); publish() }
            // Entry has no cheap identity of its own (a fresh UUID per parse),
            // so watch the timestamps — they're what actually names a row.
            .onChange(of: entries.map(\.ts)) { _, _ in
                if let i = index, i >= entries.count {
                    index = entries.isEmpty ? nil : entries.count - 1
                }
                register()
                publish()
            }
            .onDisappear {
                KeyCommandRouter.shared.unregister(routerID)
                ExternalDisplayModel.shared.clearBrowse(listTitle: listTitle)
            }
    }

    @ViewBuilder
    private func base(_ content: Content) -> some View {
        #if os(macOS)
        content
            .focusable()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(.downArrow) { move(by: 1); return .handled }
            .onKeyPress(.upArrow) { move(by: -1); return .handled }
            .onKeyPress(.return) { openSelected(); return .handled }
            .onKeyPress(.escape) { clearSelection(); return .handled }
            .onKeyPress(KeyEquivalent("?")) { ShortcutHints.toggle(); return .handled }
        #else
        // No focusable()/onKeyPress on iOS — see the note at the top of the
        // file. UIKeyCommands drive this through the router instead; the
        // catcher puts them at the near end of the responder chain.
        content
            .background(KeyCommandCatcher().frame(width: 0, height: 0).allowsHitTesting(false))
        #endif
    }

    /// Re-registered whenever the selection or the list changes, so the closures
    /// the router holds always close over current values.
    private func register() {
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp:   { move(by: -1) },
            moveDown: { move(by: 1) },
            open:     { openSelected() },
            clear:    { clearSelection() }
        ))
    }

    // MARK: Actions

    private func move(by delta: Int) {
        guard !entries.isEmpty else { return }
        // First press adopts the top (or bottom) rather than jumping to row 2.
        guard let current = index else {
            index = delta > 0 ? 0 : entries.count - 1
            return
        }
        index = min(max(current + delta, 0), entries.count - 1)
    }

    private func openSelected() {
        guard let i = index, entries.indices.contains(i) else { return }
        onOpen(entries[i])
    }

    private func clearSelection() {
        index = nil
    }

    // MARK: External display

    private func publish() {
        guard let i = index, entries.indices.contains(i) else {
            ExternalDisplayModel.shared.clearBrowse(listTitle: listTitle)
            return
        }
        ExternalDisplayModel.shared.present(
            .browsing(listTitle: listTitle,
                      rows: ExternalRow.rows(from: entries),
                      selected: i)
        )
    }
}

