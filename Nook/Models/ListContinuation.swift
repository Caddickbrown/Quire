//
//  ListContinuation.swift
//  Nook
//
//  What pressing ↩ at the end of a list line should do — continue the list
//  with the next prefix, end it by stripping an empty item's prefix, or
//  nothing. Pure (Foundation-only) so both platform text views share one set
//  of rules and `make check` / NookTests can exercise them. Lives here rather
//  than in WritingTextEditor precisely so it stays testable.
//

import Foundation

enum ListContinuation {
    enum Action: Equatable {
        case none                          // default newline
        case continueList(prefix: String)  // newline + this prefix
        case endList(prefixLength: Int)    // line is only its prefix: strip it
    }

    private static let checkbox = try! NSRegularExpression(pattern: #"^(\s*)([-*+] \[[ xX]\] )(.*)$"#)
    private static let bullet   = try! NSRegularExpression(pattern: #"^(\s*)([-*+] )(.*)$"#)
    private static let ordered  = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)] )(.*)$"#)

    /// What pressing Return at the end of `line` should do.
    static func action(for line: String) -> Action {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = checkbox.firstMatch(in: line, range: full) {
            let indent = ns.substring(with: m.range(at: 1))
            let marker = ns.substring(with: m.range(at: 2))
            let rest = ns.substring(with: m.range(at: 3))
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                return .endList(prefixLength: (indent + marker).utf16.count)
            }
            // A fresh, unchecked box regardless of the current one's state.
            let bullet = marker.prefix(2)   // "- " / "* " / "+ "
            return .continueList(prefix: indent + bullet + "[ ] ")
        }
        if let m = ordered.firstMatch(in: line, range: full) {
            let indent = ns.substring(with: m.range(at: 1))
            let number = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let sep = ns.substring(with: m.range(at: 3))
            let rest = ns.substring(with: m.range(at: 4))
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                return .endList(prefixLength: (indent + "\(number)" + sep).utf16.count)
            }
            return .continueList(prefix: indent + "\(number + 1)" + sep)
        }
        if let m = bullet.firstMatch(in: line, range: full) {
            let indent = ns.substring(with: m.range(at: 1))
            let marker = ns.substring(with: m.range(at: 2))
            let rest = ns.substring(with: m.range(at: 3))
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                return .endList(prefixLength: (indent + marker).utf16.count)
            }
            return .continueList(prefix: indent + marker)
        }
        return .none
    }
}
