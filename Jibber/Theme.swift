//
//  Theme.swift
//  Jibber
//
//  Shared, cross-platform styling ported from freewrite's writing aesthetic:
//  Lato as the default writing font, a gentle 1.5× line rhythm, and off-black /
//  off-white body text that's easier on the eyes than pure black/white.
//

import SwiftUI

enum Theme {
    /// Font sizes cycled in the composer (freewrite parity).
    static let fontSizes: [CGFloat] = [16, 18, 20, 22, 24, 26]
    static let defaultFontSize: CGFloat = 18

    /// The bundled writing font. Falls back to the system font if unavailable.
    static let writingFont = "Lato-Regular"

    /// Body text colour — dark gray in light mode, off-white in dark mode.
    static func bodyText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.90, green: 0.90, blue: 0.90)
            : Color(red: 0.20, green: 0.20, blue: 0.20)
    }

    static func placeholder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.gray.opacity(0.8) : Color.gray
    }

    /// Extra spacing to add between lines to reach ~1.5× line height.
    /// freewrite computes this from exact font metrics (NSFont); this platform-
    /// independent approximation (natural leading ≈ size) is close enough.
    static func lineSpacing(for size: CGFloat) -> CGFloat {
        size * 0.5
    }

    static let placeholderPrompts = [
        "Begin writing",
        "Pick a thought and go",
        "Start with your hands today",
        "What's on your mind?",
        "Just say it",
    ]
}
