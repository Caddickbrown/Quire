//
//  Theme.swift
//  Wander
//
//  A theme is a palette, a set of faces and a handful of chrome switches. All
//  thirteen are defined once, in `Resources/themes.json`, and read from there by
//  this app, by the icon generator and by the Tauri build — so a theme is
//  described in one place and looks the same in three.
//

import SwiftUI
import WanderCore

#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformFontWeight = NSFont.Weight
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformFontWeight = UIFont.Weight
#endif

struct Tone: Equatable {
    let hex: UInt32
    var alpha: CGFloat = 1

    init(hex: UInt32, alpha: CGFloat = 1) {
        self.hex = hex
        self.alpha = alpha
    }

    init(_ string: String) {
        let digits = string.hasPrefix("#") ? String(string.dropFirst()) : string
        self.hex = UInt32(digits, radix: 16) ?? 0
        self.alpha = 1
    }

    var color: Color {
        Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: Double(alpha))
    }

    /// NSColor or UIColor — the prose editor is a platform text view either way.
    var platform: PlatformColor {
        #if canImport(AppKit)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
        #endif
    }

    func opacity(_ a: CGFloat) -> Tone { Tone(hex: hex, alpha: a) }

    /// Perceived lightness, 0–1. Used to decide what can be read on top.
    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// Whichever of two tones actually contrasts with this one. Measured, not
    /// assumed: in a dark theme `ink` is near-white, so picking it as "the dark
    /// one" put white text on a white block.
    func readable(_ first: Tone, _ second: Tone) -> Tone {
        abs(first.luminance - luminance) >= abs(second.luminance - luminance) ? first : second
    }

    /// Contrast ratio against another tone, on the usual 1–21 scale.
    func contrast(with other: Tone) -> CGFloat {
        let a = luminance + 0.05, b = other.luminance + 0.05
        return max(a, b) / min(a, b)
    }

    /// The first candidate that can actually be read on this tone, else the one
    /// that comes closest. Acid yellow is a fine fill and terrible text on
    /// white; this is what tells them apart.
    func legible(_ candidates: [Tone], minimum: CGFloat = 3.2) -> Tone {
        candidates.first { contrast(with: $0) >= minimum }
            ?? candidates.max { contrast(with: $0) < contrast(with: $1) }
            ?? candidates[0]
    }

    private var r: CGFloat { CGFloat((hex >> 16) & 0xFF) / 255 }
    private var g: CGFloat { CGFloat((hex >> 8) & 0xFF) / 255 }
    private var b: CGFloat { CGFloat(hex & 0xFF) / 255 }
}

// MARK: - The theme

struct Theme: Equatable, Identifiable {
    let id: String
    let name: String
    let note: String

    // Palette
    let paper: Tone        // the page itself
    let panel: Tone        // index and side columns
    let surface: Tone      // a raised sheet: the selected row
    let ink: Tone          // headings, values, the caret
    let prose: Tone        // body text
    let muted: Tone        // labels, meta, marginalia
    let rule: Tone         // hairline between fields and rows
    let ruleFaint: Tone    // dividers inside a group
    let accent: Tone
    let accentDeep: Tone
    let tint: Tone         // a theme's third colour, where it has one
    let green: Tone        // the streak

    // Type
    let proseFace: FaceSpec
    let proseWeight: Font.Weight
    let proseSize: CGFloat
    let displayFace: FaceSpec
    let displayWeight: Font.Weight
    let displayScale: CGFloat      // multiplies the entry title's 30pt
    let displayUppercase: Bool
    let displayTracking: CGFloat
    let labelFace: FaceSpec
    let labelWeight: Font.Weight
    let labelSize: CGFloat
    let labelTracking: CGFloat
    let labelUppercase: Bool

    // Chrome
    /// Which appearance a theme was drawn for. Advice, not a rule — every
    /// theme has both palettes.
    enum SchemeHint: String { case light, dark, both

        var label: String {
            switch self {
            case .light: return "Light"
            case .dark: return "Dark"
            case .both: return "Light or dark"
            }
        }
    }

    enum RowStyle: String { case rule, plain, card, block, indent }
    enum Ornament: String { case none, wash, letterbox, wedge, ghost, confetti, rail }
    /// How the masthead is set: a hairline under it, a solid band behind it, a
    /// centred wordmark, a newspaper's heavy-plus-hairline, or nothing.
    enum MastheadStyle: String { case rule, band, centred, double, none }
    /// The stats column as ruled rows, or as the big display numerals most of
    /// these looks used on the board.
    enum StatsStyle: String { case rows, figures }

    let mastheadRule: CGFloat
    let mastheadStyle: MastheadStyle
    let statsStyle: StatsStyle
    /// A small-caps line above the entry title, the way a magazine sets one.
    let kicker: Bool
    let rowStyle: RowStyle
    let corner: CGFloat
    let border: CGFloat
    let filledButtons: Bool
    let ornament: Ornament
    let centred: Bool
    let statsTrace: Bool
    let measure: CGFloat
    let lineHeight: CGFloat
    /// Stats figures drawn as filled blocks rather than plain numerals.
    let figureBlocks: Bool
    /// The page sits on a bordered card with a hard offset shadow.
    let pageCard: Bool
    /// Index rows cycle the theme's colours instead of sharing one fill.
    let rowColours: Bool
    let recommended: SchemeHint

    static func == (lhs: Theme, rhs: Theme) -> Bool {
        lhs.id == rhs.id && lhs.paper.hex == rhs.paper.hex && lhs.ink.hex == rhs.ink.hex
    }

    // MARK: Fonts

    func prose(_ size: CGFloat) -> Font { proseFace.font(size, weight: proseWeight) }
    func proseItalic(_ size: CGFloat) -> Font { proseFace.font(size, weight: proseWeight, italic: true) }
    func display(_ size: CGFloat) -> Font { displayFace.font(size, weight: displayWeight) }
    func label(_ size: CGFloat? = nil) -> Font {
        labelFace.font(size ?? labelSize, weight: labelWeight)
    }

    /// The title as this theme sets it, in points.
    var titleSize: CGFloat { 30 * displayScale }

    /// Interface text that isn't a label: field values, the search field, row
    /// meta. Always the label family, never uppercased.
    func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        labelFace.font(size, weight: weight)
    }

    /// An index row's title — the display face, at a weight that survives being
    /// small in themes whose display weight is heavy.
    func rowTitle(_ size: CGFloat) -> Font {
        let weight: Font.Weight
        switch displayWeight {
        case .heavy, .bold: weight = .semibold
        case .light: weight = .light
        default: weight = .regular
        }
        return displayFace.font(size, weight: weight)
    }

    /// SwiftUI weights and platform weights are different types; the editor
    /// needs the platform one.
    var proseWeightPlatform: PlatformFontWeight {
        switch proseWeight {
        case .light, .thin, .ultraLight: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold, .heavy, .black: return .bold
        default: return .regular
        }
    }

    /// The accent, where it is being used as text rather than as a fill: a
    /// theme whose accent is acid yellow needs something else on a pale ground.
    var accentInk: Tone { paper.legible([accent, ink, accentDeep, tint]) }

    /// The accent as it must read on the ink band of a `band` masthead.
    var accentOnBand: Tone { ink.legible([accent, tint, green, paper]) }

    /// Distinct fills for the stats blocks. Several themes point two or three
    /// of their colours at the same value — Brutalist's accent, ink and green
    /// are all one white in the dark — so the list is deduplicated and padded
    /// with the surface rather than repeating a block.
    var figureFills: [Tone] {
        var chosen: [Tone] = []
        for tone in [accent, tint, green, ink] where !chosen.contains(where: { $0.hex == tone.hex }) {
            chosen.append(tone)
        }
        while chosen.count < 3 { chosen.append(surface) }
        return chosen
    }

    /// Code spans, wherever a theme doesn't already set prose in a mono face.
    var monoFace: FaceSpec {
        proseFace.shape == .mono ? proseFace : FaceSpec("IBM Plex Mono", shape: .mono)
    }

    func labelText(_ text: String) -> String {
        labelUppercase ? text.uppercased() : text
    }

    // MARK: Catalogue

    static let all: [Theme] = ThemeFile.load()

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? all.first ?? .fallback
    }

    static func resolve(_ id: String, _ scheme: ColorScheme) -> Theme {
        ThemeFile.resolve(id: id, dark: scheme == .dark)
    }

    /// Used only if the theme file is missing from the bundle — the app should
    /// still open, in something legible.
    static let fallback = Theme(
        id: "almanac", name: "Almanac", note: "",
        paper: Tone("#F6F2EA"), panel: Tone("#F1ECE1"), surface: Tone("#FBF8F2"),
        ink: Tone("#171310"), prose: Tone("#453D33"), muted: Tone("#8A7F6D"),
        rule: Tone("#DDD5C7"), ruleFaint: Tone("#E6DED0"),
        accent: Tone("#9C3220"), accentDeep: Tone("#7A2416"),
        tint: Tone("#6B8CA8"), green: Tone("#2F5D4A"),
        proseFace: FaceSpec("Newsreader", shape: .serif), proseWeight: .regular, proseSize: 17.5,
        displayFace: FaceSpec("Newsreader", shape: .serif), displayWeight: .semibold,
        displayScale: 1, displayUppercase: false, displayTracking: 0,
        labelFace: FaceSpec("IBM Plex Sans", shape: .sans), labelWeight: .semibold,
        labelSize: 10.5, labelTracking: 1.15, labelUppercase: true,
        mastheadRule: 2, mastheadStyle: .rule, statsStyle: .rows, kicker: false,
        rowStyle: .rule, corner: 0, border: 1, filledButtons: true,
        ornament: .none, centred: false, statsTrace: false, measure: 760, lineHeight: 1.42,
        figureBlocks: false, pageCard: false, rowColours: false, recommended: .both)
}

// MARK: - Reading themes.json

enum ThemeFile {
    private struct Document: Decodable { let themes: [Entry] }

    private struct Entry: Decodable {
        let id: String
        let name: String
        let note: String
        let type: TypeSpec
        let chrome: ChromeSpec
        let light: [String: String]
        let dark: [String: String]
        let scheme: String?
    }

    private struct TypeSpec: Decodable {
        let prose: FaceEntry
        let display: FaceEntry
        let label: FaceEntry
    }

    private struct FaceEntry: Decodable {
        let families: [String]
        let shape: String
        let weight: String
        var size: CGFloat?
        var scale: CGFloat?
        var tracking: CGFloat?
        var uppercase: Bool?
    }

    private struct ChromeSpec: Decodable {
        let mastheadRule: CGFloat
        let mastheadStyle: String?
        let statsStyle: String?
        let kicker: Bool?
        let rowStyle: String
        let corner: CGFloat
        let border: CGFloat
        let filledButtons: Bool
        let ornament: String
        let centred: Bool
        let statsTrace: Bool
        let measure: CGFloat
        let lineHeight: CGFloat
        let figureBlocks: Bool?
        let pageCard: Bool?
        let rowColours: Bool?
    }

    private static let document: Document? = {
        guard let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Document.self, from: data)
    }()

    static func load() -> [Theme] {
        guard let document else { return [Theme.fallback] }
        return document.themes.map { theme(from: $0, dark: false) }
    }

    /// Built themes, by id and appearance. A SwiftUI body reads `theme` a dozen
    /// times over, and each read used to search the decoded file and rebuild the
    /// whole struct — twelve colours parsed out of their hex strings included.
    private static var built: [String: Theme] = [:]

    static func resolve(id: String, dark: Bool) -> Theme {
        let key = dark ? id + ".dark" : id + ".light"
        if let ready = built[key] { return ready }
        guard let entry = document?.themes.first(where: { $0.id == id })
                ?? document?.themes.first else { return .fallback }
        let made = theme(from: entry, dark: dark)
        built[key] = made
        return made
    }

    private static func theme(from entry: Entry, dark: Bool) -> Theme {
        let p = dark ? entry.dark : entry.light
        func tone(_ key: String, _ fallback: String) -> Tone { Tone(p[key] ?? fallback) }

        return Theme(
            id: entry.id, name: entry.name, note: entry.note,
            paper: tone("paper", "#F6F2EA"), panel: tone("panel", "#F1ECE1"),
            surface: tone("surface", "#FBF8F2"), ink: tone("ink", "#171310"),
            prose: tone("prose", "#453D33"), muted: tone("muted", "#8A7F6D"),
            rule: tone("rule", "#DDD5C7"), ruleFaint: tone("ruleFaint", "#E6DED0"),
            accent: tone("accent", "#9C3220"), accentDeep: tone("accentDeep", "#7A2416"),
            tint: tone("tint", "#6B8CA8"), green: tone("green", "#2F5D4A"),
            proseFace: face(entry.type.prose), proseWeight: weight(entry.type.prose.weight),
            proseSize: entry.type.prose.size ?? 17.5,
            displayFace: face(entry.type.display), displayWeight: weight(entry.type.display.weight),
            displayScale: entry.type.display.scale ?? 1,
            displayUppercase: entry.type.display.uppercase ?? false,
            displayTracking: entry.type.display.tracking ?? 0,
            labelFace: face(entry.type.label), labelWeight: weight(entry.type.label.weight),
            labelSize: entry.type.label.size ?? 10.5,
            labelTracking: entry.type.label.tracking ?? 1.15,
            labelUppercase: entry.type.label.uppercase ?? true,
            mastheadRule: entry.chrome.mastheadRule,
            mastheadStyle: Theme.MastheadStyle(rawValue: entry.chrome.mastheadStyle ?? "rule") ?? .rule,
            statsStyle: Theme.StatsStyle(rawValue: entry.chrome.statsStyle ?? "rows") ?? .rows,
            kicker: entry.chrome.kicker ?? false,
            rowStyle: Theme.RowStyle(rawValue: entry.chrome.rowStyle) ?? .rule,
            corner: entry.chrome.corner, border: entry.chrome.border,
            filledButtons: entry.chrome.filledButtons,
            ornament: Theme.Ornament(rawValue: entry.chrome.ornament) ?? Theme.Ornament.none,
            centred: entry.chrome.centred, statsTrace: entry.chrome.statsTrace,
            measure: entry.chrome.measure, lineHeight: entry.chrome.lineHeight,
            figureBlocks: entry.chrome.figureBlocks ?? false,
            pageCard: entry.chrome.pageCard ?? false,
            rowColours: entry.chrome.rowColours ?? false,
            recommended: Theme.SchemeHint(rawValue: entry.scheme ?? "both") ?? .both)
    }

    private static func face(_ entry: FaceEntry) -> FaceSpec {
        FaceSpec(entry.families, shape: shape(entry.shape))
    }

    private static func shape(_ name: String) -> FaceSpec.Shape {
        switch name {
        case "serif": return .serif
        case "mono": return .mono
        case "rounded": return .rounded
        default: return .sans
        }
    }

    private static func weight(_ name: String) -> Font.Weight {
        switch name {
        case "light": return .light
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        default: return .regular
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.fallback
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
