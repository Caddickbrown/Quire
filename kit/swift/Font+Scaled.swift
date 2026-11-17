// Custom fonts that follow the reader's text size.
//
// `Font.custom(_:size:relativeTo:)` already scales; what this adds is a
// fallback that keeps the weight when the face isn't registered (a typo in
// Info.plist, a missing file), and a way to ask whether it was.

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Font {
    /// `Font.scaled("Inter-SemiBold", size: 17, weight: .semibold, relativeTo: .headline)`.
    static func scaled(_ name: String, size: CGFloat, weight: Font.Weight = .regular,
                       relativeTo style: Font.TextStyle = .body) -> Font {
        let font = Font.custom(name, size: size, relativeTo: style)
        // An unregistered name falls back to the system face, still scaling, but at regular weight.
        return isRegistered(name) ? font : font.weight(weight)
    }

    /// True when the named face loaded. Worth surfacing somewhere quiet (settings,
    /// diagnostics): a silent substitution can go unnoticed for a long time.
    static func isRegistered(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIFont(name: name, size: 12) != nil
        #elseif canImport(AppKit)
        return NSFont(name: name, size: 12) != nil
        #else
        return false
        #endif
    }
}
