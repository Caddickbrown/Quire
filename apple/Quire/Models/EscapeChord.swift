import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The keys that mean Esc. iOS's text system knows the Esc key alone and never
/// turns ⌘. into it, so ⌘. works only where it's declared, and an iPad's keyboard
/// often has no Esc. From MiniOffice.
struct EscapeChord: Equatable {
    let input: String
    let command: Bool

    static let escape = EscapeChord(input: "\u{1B}", command: false)
    static let commandPeriod = EscapeChord(input: ".", command: true)

    /// Mid-composition both belong to the input method.
    static func declared(composing: Bool) -> [EscapeChord] {
        composing ? [] : [escape, commandPeriod]
    }
}

#if canImport(UIKit)
extension EscapeChord {
    /// With priority over the text system, and a held key is one press: it mustn't
    /// run on through what's behind.
    func keyCommand(action: Selector) -> UIKeyCommand {
        let c = UIKeyCommand(input: self == .escape ? UIKeyCommand.inputEscape : input,
                             modifierFlags: command ? .command : [], action: action)
        c.wantsPriorityOverSystemBehavior = true
        c.repeatBehavior = .nonRepeatable
        return c
    }
}
#endif
