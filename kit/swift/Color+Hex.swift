// Colours from hex, the one way. Values belong to the app; prefer the palette
// generated from design/tokens.json over calling these from a screen.

import SwiftUI

extension Color {
    /// `Color(hex: 0x1F7A4A)` — sRGB, 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }

    /// `Color(hexString: "#1F7A4A")`, with or without the `#`. Nil if it isn't six hex digits —
    /// for values that arrive as data (a project's colour), never for the app's own palette.
    init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
