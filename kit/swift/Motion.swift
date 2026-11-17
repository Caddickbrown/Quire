// Animation that respects Reduce Motion. See kit/specs/MOTION.md.
//
//   KitMotion.perform(.spring) { expanded.toggle() }    // instead of withAnimation
//   view.kitAnimation(.easeOut, value: selection)        // instead of .animation(_:value:)
//
// Under Reduce Motion the change still happens; it just doesn't move.

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum KitMotion {
    /// The system's Reduce Motion setting, read at call time.
    static var reduceMotion: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #elseif canImport(AppKit)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return false
        #endif
    }

    /// `withAnimation`, or no animation under Reduce Motion.
    @discardableResult
    static func perform<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(reduceMotion ? nil : animation, body)
    }
}

extension View {
    /// `.animation(_:value:)`, or none under Reduce Motion.
    func kitAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(KitAnimation(animation: animation, value: value))
    }
}

private struct KitAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(accessibilityReduceMotion ? nil : animation, value: value)
    }
}
