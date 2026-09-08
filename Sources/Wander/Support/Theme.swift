//
//  Theme.swift
//  Wander
//
//  The almanac palette: warm paper, near-black ink, hairline rules and one
//  terracotta accent, with a warm-neutral dark counterpart in the same hue
//  family. Every colour in the app comes from here, in both SwiftUI and
//  AppKit form — the prose editor is an NSTextView and needs NSColor.
//

import SwiftUI
import AppKit
import WanderCore

struct Tone {
    let hex: UInt32
    var alpha: CGFloat = 1

    var color: Color {
        Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: Double(alpha))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    func opacity(_ a: CGFloat) -> Tone { Tone(hex: hex, alpha: a) }

    private var r: CGFloat { CGFloat((hex >> 16) & 0xFF) / 255 }
    private var g: CGFloat { CGFloat((hex >> 8) & 0xFF) / 255 }
    private var b: CGFloat { CGFloat(hex & 0xFF) / 255 }
}

struct Theme {
    /// The page itself.
    let paper: Tone
    /// Sidebar and margin columns — a half-tone off the page.
    let panel: Tone
    /// A raised sheet: the selected row, the search well.
    let surface: Tone

    let ink: Tone       // headings, values, the caret
    let prose: Tone     // body text
    let muted: Tone     // labels, meta, marginalia

    let rule: Tone      // hairline between fields and rows
    let ruleFaint: Tone // graph gridlines, dividers inside a group

    let accent: Tone    // terracotta: the one loud colour
    let accentDeep: Tone
    let blue: Tone
    let green: Tone

    static let light = Theme(
        paper:     Tone(hex: 0xF6F2EA),
        panel:     Tone(hex: 0xF1ECE1),
        surface:   Tone(hex: 0xFBF8F2),
        ink:       Tone(hex: 0x171310),
        prose:     Tone(hex: 0x453D33),
        muted:     Tone(hex: 0x8A7F6D),
        rule:      Tone(hex: 0xDDD5C7),
        ruleFaint: Tone(hex: 0xE6DED0),
        accent:    Tone(hex: 0x9C3220),
        accentDeep: Tone(hex: 0x7A2416),
        blue:      Tone(hex: 0x6B8CA8),
        green:     Tone(hex: 0x2F5D4A)
    )

    static let dark = Theme(
        paper:     Tone(hex: 0x16130F),
        panel:     Tone(hex: 0x1B1713),
        surface:   Tone(hex: 0x221D18),
        ink:       Tone(hex: 0xF2ECE0),
        prose:     Tone(hex: 0xD2C8B7),
        muted:     Tone(hex: 0x93876F),
        rule:      Tone(hex: 0x342D24),
        ruleFaint: Tone(hex: 0x27211A),
        accent:    Tone(hex: 0xCC6A4C),
        accentDeep: Tone(hex: 0xE08B6E),
        blue:      Tone(hex: 0x82A5C0),
        green:     Tone(hex: 0x82A26B)
    )

    static func resolve(_ scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.light
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Type

/// Newsreader and IBM Plex Sans are the design's faces; when they aren't
/// installed the app falls back to New York and SF, which sit in the same
/// places — a transitional serif with a true italic, and a neutral grotesque.
enum Face {
    static let serifName: String? = installed("Newsreader")
    static let sansName: String? = installed("IBM Plex Sans")

    private static func installed(_ family: String) -> String? {
        NSFontManager.shared.availableFontFamilies.contains(family) ? family : nil
    }

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        var font: Font
        if let serifName {
            font = .custom(serifName, fixedSize: size).weight(weight)
        } else {
            font = .system(size: size, weight: weight, design: .serif)
        }
        if italic { font = font.italic() }
        return font
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let sansName {
            return .custom(sansName, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    /// AppKit twin of `serif`, for the prose editor's text storage.
    static func nsSerif(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        var font: NSFont
        if let serifName, let custom = NSFont(name: serifName, size: size) {
            font = custom
        } else {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            font = NSFont(descriptor: descriptor, size: size) ?? base
        }
        if weight != .regular {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    static func nsMono(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
