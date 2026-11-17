// A colour that resolves light or dark at draw time, on iOS and macOS alike.

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    /// `Color(light: 0xF4F6F8, dark: 0x0D1512)`.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(kitRGB: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(kitRGB: isDark ? dark : light)
        })
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(kitRGB rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(kitRGB rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}
#endif
