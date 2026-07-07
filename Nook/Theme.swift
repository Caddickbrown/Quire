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

    /// Resolve the user's chosen writing font at a size.
    static func font(_ raw: String, size: CGFloat) -> Font {
        (WritingFont(rawValue: raw) ?? .lato).font(size)
    }

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

/// How dates are shown throughout the app (chosen in Settings).
enum DateStyle: String, CaseIterable, Identifiable {
    case weekday   // Mon, 10 May
    case medium    // 10 May 2026
    case long      // Monday, 10 May 2026
    case iso       // 2026-05-10
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekday: return "Mon, 10 May"
        case .medium:  return "10 May 2026"
        case .long:    return "Monday, 10 May 2026"
        case .iso:     return "2026-05-10"
        }
    }

    var format: String {
        switch self {
        case .weekday: return "EEE, d MMM"
        case .medium:  return "d MMM yyyy"
        case .long:    return "EEEE, d MMMM yyyy"
        case .iso:     return "yyyy-MM-dd"
        }
    }
}

extension Theme {
    private static let isoParser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let displayFormatter = DateFormatter()

    /// Format an ISO "YYYY-MM-DD" date string in the user's chosen style.
    static func displayDate(_ isoDate: String, style raw: String) -> String {
        let style = DateStyle(rawValue: raw) ?? .weekday
        guard let d = isoParser.date(from: isoDate) else { return isoDate }
        displayFormatter.locale = .current
        displayFormatter.dateFormat = style.format
        return displayFormatter.string(from: d)
    }
}

/// The writing font the user can choose in Settings. Serif/Mono use SwiftUI's
/// system designs so they resolve identically on iOS and macOS; Lato is bundled.
enum WritingFont: String, CaseIterable, Identifiable {
    case lato, system, serif, mono
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lato:   return "Lato"
        case .system: return "System"
        case .serif:  return "Serif"
        case .mono:   return "Mono"
        }
    }

    func font(_ size: CGFloat) -> Font {
        switch self {
        case .lato:   return .custom("Lato-Regular", size: size)
        case .system: return .system(size: size)
        case .serif:  return .system(size: size, design: .serif)
        case .mono:   return .system(size: size, design: .monospaced)
        }
    }
}
