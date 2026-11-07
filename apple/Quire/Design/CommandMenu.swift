//
//  CommandMenu.swift
//  Quire
//
//  ⌘K with a hardware keyboard. What it lists and what the keys mean live in
//  `CommandPalette` (tested without an app); this is the glue and the drawing.
//  With the monitor showing things the menu is drawn there (in VS Code's own
//  dress in hidden mode, `DeskCode.swift`); otherwise it is drawn over the phone
//  or iPad. Either way the keys go to a text view nobody sees, in a window of its
//  own above sheets and the composer, so nothing beneath hears them: Esc gives
//  the keyboard back to whatever had it.
//

#if os(iOS)

import SwiftUI
import UIKit

@MainActor final class CommandHost: ObservableObject {
    static let shared = CommandHost()
    private init() {}

    @Published private(set) var menu: CommandPalette?
    /// Drawn on the monitor rather than over the phone. Decided when it opens.
    @Published private(set) var onMonitor = false
    /// Does what was chosen; set by `PhoneRoot`, which owns the tabs and sheets.
    var perform: ((CommandAction) -> Void)?

    private let routerID = UUID()
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    /// The field that had the keyboard when the menu came up, given it back by Esc.
    private weak var wasTyping: UIResponder?

    /// ⌘K, from whichever key command heard it. Not behind App Lock, and not over
    /// a question or the date picker, which are answered first.
    func toggle() {
        if menu != nil { close(); return }
        guard !AppLockManager.shared.showsVeil, !DeskConfirm.shared.isOpen, !DeskDatePicker.shared.isOpen,
              let store = ExternalDisplayModel.shared.store, let scene = Self.appScene else { return }
        var counts: [String: Int] = [:]
        for day in store.archiveEntries { counts[day.date, default: 0] += day.entries.count }
        onMonitor = DeskDatePicker.shared.isAvailable
        menu = CommandPalette(CommandSources(counts: counts))
        wasTyping = UIResponder.quireFirstResponder
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: CommandMenuOverlay())
        host.view.backgroundColor = .clear
        let top = UIWindow(windowScene: scene)
        top.rootViewController = host
        top.backgroundColor = .clear
        // Below the App Lock veil, above everything else.
        top.windowLevel = .alert
        top.makeKeyAndVisible()
        window = top
        // Nothing beneath acts, even for a key that reaches the app delegate.
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: {}, moveDown: {}, open: {},
            clear: { [weak self] in self?.close() },
            key: { _ in true }))
    }

    func close() {
        guard menu != nil else { return }
        menu = nil
        KeyCommandRouter.shared.unregister(routerID)
        window?.isHidden = true
        window = nil
        previousKey?.makeKey()
        let field = wasTyping
        wasTyping = nil
        DispatchQueue.main.async { field?.becomeFirstResponder() }
    }

    func press(_ key: CommandPalette.Key) {
        guard let outcome = menu?.press(key) else { return }
        switch outcome {
        case .stay: break
        case .close: close()
        case .run(let action):
            wasTyping = nil
            close()
            // On the next turn, not inside the key's own handling.
            DispatchQueue.main.async { [weak self] in self?.perform?(action) }
        }
    }

    func type(_ text: String) { menu?.type(text) }
    func backspace() { menu?.backspace() }

    private static var appScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

// MARK: - Keys

enum CommandKeys {
    private static func command(_ input: String, _ flags: UIKeyModifierFlags = []) -> UIKeyCommand {
        let c = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(UIResponder.quireCommandKey(_:)))
        // Otherwise a text view takes them for itself.
        c.wantsPriorityOverSystemBehavior = true
        return c
    }

    /// For anything that holds the keyboard: the composer's body, the key catcher.
    static var toggle: UIKeyCommand { command("k", .command) }

    /// Everything the menu listens for, declared on its own field.
    static var open: [UIKeyCommand] {
        [toggle, command(UIKeyCommand.inputEscape), command(".", .command), command("\r"), command("\t"), command("\t", .shift),
         command(UIKeyCommand.inputUpArrow), command(UIKeyCommand.inputDownArrow)]
    }

    static func key(for command: UIKeyCommand) -> CommandPalette.Key? {
        let flags = command.modifierFlags.intersection([.command, .alternate, .shift, .control])
        switch (command.input, flags) {
        case ("k", .command): return .toggle
        case (UIKeyCommand.inputEscape, []), (".", .command): return .esc
        case ("\r", []): return .enter
        case ("\t", []): return .tab
        case ("\t", .shift): return .backTab
        case (UIKeyCommand.inputUpArrow, []): return .up
        case (UIKeyCommand.inputDownArrow, []): return .down
        default: return nil
        }
    }
}

extension UIResponder {
    @objc func quireCommandKey(_ command: UIKeyCommand) {
        guard let key = CommandKeys.key(for: command) else { return }
        MainActor.assumeIsolated {
            if key == .toggle { CommandHost.shared.toggle() } else { CommandHost.shared.press(key) }
        }
    }
}

/// ⌘K for a SwiftUI field, which can't declare key commands of its own.
struct CommandMenuShortcut: View {
    var body: some View {
        Button("Command Menu") { CommandHost.shared.toggle() }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 0, height: 0).opacity(0)
            .accessibilityHidden(true)
    }
}

/// Where typing lands while the menu is up: out of sight, always empty, and the
/// letters go to the menu. No on-screen keyboard: ⌘K means there's a real one.
private final class CommandField: UITextView, UITextViewDelegate {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: nil)
        delegate = self
        alpha = 0
        isUserInteractionEnabled = false
        inputView = UIView()
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        autocorrectionType = .no
        spellCheckingType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
    }

    required init?(coder: NSCoder) { fatalError("Built in code.") }

    override var keyCommands: [UIKeyCommand]? { CommandKeys.open }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DispatchQueue.main.async { self.becomeFirstResponder() } }
    }

    override func deleteBackward() {
        MainActor.assumeIsolated { CommandHost.shared.backspace() }
    }

    func textView(_ v: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        MainActor.assumeIsolated {
            if text.isEmpty { CommandHost.shared.backspace() } else { CommandHost.shared.type(text) }
        }
        return false
    }
}

private struct CommandCatcher: UIViewRepresentable {
    func makeUIView(context: Context) -> CommandField { CommandField() }
    func updateUIView(_ view: CommandField, context: Context) {}
    static func dismantleUIView(_ view: CommandField, coordinator: ()) { view.resignFirstResponder() }
}

// MARK: - The screen

/// The menu's own window: the panel over the dimmed page, unless the monitor has
/// it. Tapping the phone closes it either way.
private struct CommandMenuOverlay: View {
    @ObservedObject private var host = CommandHost.shared
    @AppStorage(QuireTheme.storageKey) private var themeID = QuireTheme.auto
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(host.onMonitor ? 0.001 : 0.18).ignoresSafeArea()
                .onTapGesture { host.close() }
                .accessibilityLabel("Close the menu")
            if let menu = host.menu, !host.onMonitor {
                CommandMenuPanel(menu: menu, showsKeys: true)
                    .padding(.horizontal, 16).padding(.top, 24)
            }
            CommandCatcher().frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
        }
        .environment(\.quire, QuireTheme.resolve(themeID, scheme: scheme))
    }
}

/// The menu in Quire's design, the same on the phone and the monitor: `z` scales it.
struct CommandMenuPanel: View {
    @Environment(\.quire) private var q
    let menu: CommandPalette
    var z: CGFloat = 1
    /// The monitor has its hint bar for this.
    var showsKeys = false

    private var rowHeight: CGFloat { 54 * z }

    var body: some View {
        VStack(spacing: 0) {
            field
            Rectangle().fill(q.lineColor).frame(height: 1)
            if menu.rows.isEmpty {
                Text(menu.nothing).font(q.writing(17 * z, italic: true)).foregroundStyle(q.mutedColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18 * z).padding(.vertical, 16 * z)
            } else {
                list
            }
            if showsKeys {
                Rectangle().fill(q.lineColor).frame(height: 1)
                keys
            }
        }
        .frame(maxWidth: 580 * z)
        .background(q.pageColor)
        .overlay(Rectangle().strokeBorder(q.lineColor, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 18 * z, y: 6 * z)
    }

    private var field: some View {
        HStack(spacing: 10 * z) {
            Image(systemName: "magnifyingglass").font(.system(size: 15 * z, weight: .light)).foregroundStyle(q.mutedColor)
            HStack(spacing: 1 * z) {
                if !menu.query.isEmpty {
                    Text(menu.query).font(q.writing(20 * z)).foregroundStyle(q.inkColor).lineLimit(1).truncationMode(.head)
                }
                Text("|").font(q.writing(20 * z)).foregroundStyle(q.accentColor)
                if menu.query.isEmpty {
                    Text(menu.prompt).font(q.writing(20 * z, italic: true)).foregroundStyle(q.faintColor).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18 * z).frame(minHeight: 52 * z)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(menu.rows) { row in
                        CommandMenuRow(row: row, lit: row.id == menu.selected, z: z).frame(height: rowHeight).id(row.id)
                    }
                }
            }
            .frame(maxHeight: rowHeight * CGFloat(menu.rows.count))
            .onChange(of: menu.selected) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private var keys: some View {
        HStack(spacing: 14 * z) {
            ForEach(menu.hints) { hint in
                HStack(spacing: 4 * z) {
                    Text(hint.key).font(q.mono(11 * z, weight: .medium)).foregroundStyle(q.accentColor)
                    Text(q.caps(hint.label)).font(q.label(11 * z)).foregroundStyle(q.mutedColor)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18 * z).padding(.vertical, 8 * z)
    }
}

private struct CommandMenuRow: View {
    @Environment(\.quire) private var q
    let row: CommandRow
    let lit: Bool
    let z: CGFloat

    var body: some View {
        HStack(spacing: 12 * z) {
            Image(systemName: row.symbol).font(.system(size: 16 * z, weight: .light))
                .foregroundStyle(lit ? q.accentColor : q.mutedColor).frame(width: 22 * z)
            VStack(alignment: .leading, spacing: 1 * z) {
                Text(row.title).font(q.writing(19 * z)).foregroundStyle(q.inkColor).lineLimit(1)
                if let detail = row.detail {
                    Text(detail).font(q.ui(12 * z)).foregroundStyle(q.mutedColor).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18 * z)
        .frame(maxHeight: .infinity)
        .background(lit ? q.accentSoftColor : Color.clear)
        .overlay(alignment: .leading) { if lit { Rectangle().fill(q.accentColor).frame(width: max(3, 3 * z)) } }
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

#endif
