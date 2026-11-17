// Esc and ⌘. on iOS. iOS's text system handles the Esc key alone and never turns ⌘.
// into it, so ⌘. works only where it's declared, and an iPad's keyboard often has
// no Esc. A hidden SwiftUI shortcut has no priority over the text system, so it
// can't be relied on from a field. `KitFieldEscape` declares both, with priority
// and without repeat, on every text field and text view, SwiftUI's included, and
// on the window, for anything with nothing focused. The app says what a press does.

import Foundation

/// The keys that mean Esc.
struct EscapeChord: Equatable {
    let input: String
    let command: Bool

    static let escape = EscapeChord(input: "\u{1B}", command: false)
    static let commandPeriod = EscapeChord(input: ".", command: true)

    /// What a text field or the window should declare. Mid-composition both belong
    /// to the input method. In an alert Esc presses Cancel by itself, which a
    /// keyboard with no Esc can't do, so ⌘. is declared there if `alertHears`: only
    /// for an app whose press knows an alert is up, and won't move what's behind it.
    static func declared(composing: Bool, inAlert: Bool, alertHears: Bool) -> [EscapeChord] {
        if composing { return [] }
        if inAlert { return alertHears ? [commandPeriod] : [] }
        return [escape, commandPeriod]
    }
}

#if os(iOS)
import ObjectiveC
import UIKit

@MainActor enum KitFieldEscape {
    private typealias Getter = @convention(c) (AnyObject, Selector) -> NSArray?

    /// Once, at launch. `action` is a `UIResponder` method: UIKit runs the first
    /// match along the chain, so anything nearer that declares these keys wins and
    /// a press never counts twice. `standAside` hands both keys back, as with a
    /// monitor attached that hears them first.
    static func install(action: Selector, alertHears: @escaping @MainActor () -> Bool = { false },
                        standAside: @escaping @MainActor () -> Bool = { false }) {
        for type: AnyClass in [UITextField.self, UITextView.self, UIWindow.self] {
            wrap(type, action, alertHears, standAside)
        }
    }

    private static func command(_ chord: EscapeChord, _ action: Selector) -> UIKeyCommand {
        let c = UIKeyCommand(input: chord == .escape ? UIKeyCommand.inputEscape : chord.input,
                             modifierFlags: chord.command ? .command : [], action: action)
        c.wantsPriorityOverSystemBehavior = true
        // A held key is one press: it mustn't run on through what's behind.
        c.repeatBehavior = .nonRepeatable
        return c
    }

    private static func wrap(_ type: AnyClass, _ action: Selector, _ alertHears: @escaping @MainActor () -> Bool,
                             _ standAside: @escaping @MainActor () -> Bool) {
        let selector = #selector(getter: UIResponder.keyCommands)
        guard let method = class_getInstanceMethod(type, selector) else { return }
        // The class's own if it has one, or else what it inherits.
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (AnyObject) -> NSArray? = { responder in
            let own = original(responder, selector) as? [UIKeyCommand] ?? []
            return MainActor.assumeIsolated {
                if standAside() { return own }
                // The window asks whoever has the cursor: it's further down the
                // chain, and mustn't take the key from an input method.
                let input = responder as? UITextInput ?? firstResponder() as? UITextInput
                let chords = EscapeChord.declared(composing: input?.markedTextRange != nil,
                                                  inAlert: frontPresented() is UIAlertController,
                                                  alertHears: alertHears())
                return own + chords.map { command($0, action) }
            } as NSArray
        }
        // Added to the class when it only inherits one, so UIResponder's stays as it is.
        class_replaceMethod(type, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    fileprivate static var found: UIResponder?

    /// There's no asking UIKit who has it, so an action sent to nobody in
    /// particular goes to whoever does, and it reports itself.
    private static func firstResponder() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.kitReportFirstResponder), to: nil, from: nil, for: nil)
        defer { found = nil }
        return found
    }

    private static func frontPresented() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

private extension UIResponder {
    @objc func kitReportFirstResponder() {
        MainActor.assumeIsolated { KitFieldEscape.found = self }
    }
}
#endif
