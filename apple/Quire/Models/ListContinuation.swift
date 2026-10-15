// Native editor adapter for Quire Rust list continuation; offsets use UTF-16.
// Compiled with generated UniFFI bindings and the Rust XCFramework.

import Foundation

enum ListContinuation {
    enum Action: Equatable {
        case none                          // default newline
        case continueList(prefix: String)  // newline + this prefix
        case endList(prefixLength: Int)    // line is only its prefix: strip it
    }

    static func action(for line: String) -> Action {
        switch continueList(line: line) {
        case .none: return .none
        case .continue(let prefix): return .continueList(prefix: prefix)
        case .end(let length): return .endList(prefixLength: Int(length))
        }
    }
}
