//
//  QuireTheme.swift
//  Quire
//
//  Quire's look, set like a book: rules and margins instead of boxes. The
//  colours come from the repo's one themes.json (shared with the Linux app and
//  the terminal); the type is Newsreader for anything that reads as writing,
//  IBM Plex Sans for the apparatus around it, Plex Mono for times and counts.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One look from themes.json. Tokens carry the Linux CSS's names.
struct QuireTheme: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let dark: Bool
    let page: String
    let ground: String
    let chrome: String
    let card: String
    let ink: String
    let muted: String
    let faint: String
    let line: String
    let line2: String
    let accent: String
    let accentSoft: String
    let accentInk: String
    let onAccent: String
    let headWeight: Double
    let ruleH: CGFloat
    /// Only the Marathon family uses these: a fill colour, the text on it, and a warning colour.
    let signal: String?
    let onSignal: String?
    let flag: String?

    enum CodingKeys: String, CodingKey {
        case id, name, dark, page, ground, chrome, card, ink, muted, faint, line, line2, accent
        case accentSoft = "accent_soft", accentInk = "accent_ink", onAccent = "on_accent"
        case headWeight = "head_weight", ruleH = "rule_h"
        case signal, onSignal = "on_signal", flag
    }

    static let storageKey = "quireTheme"
    /// "auto" follows the system appearance: Almanac by day, Cinema by night.
    static let auto = "auto"

    static let all: [QuireTheme] = {
        struct Catalog: Decodable { let themes: [QuireTheme] }
        guard let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              !catalog.themes.isEmpty else { return [fallback] }
        return catalog.themes
    }()

    /// Used only if the bundled catalogue can't be read.
    private static let fallback = QuireTheme(
        id: "almanac", name: "Almanac", dark: false, page: "#F7F1E4", ground: "#F5F0E6",
        chrome: "#EFE8DB", card: "#FFFDF8", ink: "#1F1A14", muted: "#6B6257", faint: "#8A8073",
        line: "#E3DACB", line2: "#EFE8DB", accent: "#8E2F1C", accentSoft: "#F1E0D6",
        accentInk: "#6E2414", onAccent: "#FFFDF8", headWeight: 500, ruleH: 2,
        signal: nil, onSignal: nil, flag: nil)

    static func resolve(_ id: String, scheme: ColorScheme) -> QuireTheme {
        if id != auto, let theme = all.first(where: { $0.id == id }) { return theme }
        let wanted = scheme == .dark ? "cinema" : "almanac"
        return all.first { $0.id == wanted } ?? all[0]
    }

    /// The same font is used by the native editor and its monitor mirror.
    var editorFontName: String { isMarathon ? "ArchivoRoman-Regular" : "Newsreader16pt-Regular" }
    var accentInkColor: Color { Color(hex: accentInk) }

    var pageColor: Color { Color(hex: page) }
    var groundColor: Color { Color(hex: ground) }
    var chromeColor: Color { Color(hex: chrome) }
    var inkColor: Color { Color(hex: ink) }
    var mutedColor: Color { Color(hex: muted) }
    var faintColor: Color { Color(hex: faint) }
    var lineColor: Color { Color(hex: line) }
    var line2Color: Color { Color(hex: line2) }
    var accentColor: Color { Color(hex: accent) }
    var onAccentColor: Color { Color(hex: onAccent) }
    var accentSoftColor: Color { Color(hex: accentSoft) }
    var colorScheme: ColorScheme { dark ? .dark : .light }

    /// Marathon is a look, not a palette: wide heavy type, mono readouts, square
    /// edges, numbered chrome and a signal colour. Everything that differs
    /// asks this.
    var isMarathon: Bool { id.hasPrefix("marathon") }
    var signalColor: Color { Color(hex: signal ?? accent) }
    var onSignalColor: Color { Color(hex: onSignal ?? onAccent) }
    var flagColor: Color { Color(hex: flag ?? accent) }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255)
    }
}

private struct QuireThemeKey: EnvironmentKey {
    static let defaultValue = QuireTheme.resolve(QuireTheme.auto, scheme: .light)
}

extension EnvironmentValues {
    var quire: QuireTheme {
        get { self[QuireThemeKey.self] }
        set { self[QuireThemeKey.self] = newValue }
    }
}

/// Puts the chosen theme in the environment and paints the page. The system
/// appearance is forced to the theme's own, so system controls (the keyboard,
/// the share sheet) agree with it.
struct QuireThemed<Content: View>: View {
    @AppStorage(QuireTheme.storageKey) private var themeID = QuireTheme.auto
    @Environment(\.colorScheme) private var systemScheme
    @ViewBuilder var content: Content

    var body: some View {
        // `QUIRE_THEME=marathon` in the launch environment forces a look (screenshots).
        let id = ProcessInfo.processInfo.environment["QUIRE_THEME"] ?? themeID
        let theme = QuireTheme.resolve(id, scheme: systemScheme)
        content
            .environment(\.quire, theme)
            .tint(theme.accentColor)
            .foregroundStyle(theme.inkColor)
            .background(theme.pageColor.ignoresSafeArea())
            .preferredColorScheme(id == QuireTheme.auto ? nil : theme.colorScheme)
    }
}

// MARK: - Type

/// Newsreader reads as writing, Plex Sans as apparatus, Plex Mono as a figure.
/// Each weight is a named instance of the bundled variable font, asked for by
/// its PostScript name; all of them scale with Dynamic Type.
enum QuireFont {
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let name: String
        switch (weight, italic) {
        case (.bold, false), (.heavy, false), (.black, false): name = "NewsreaderRoman-Bold"
        case (.semibold, false): name = "NewsreaderRoman-SemiBold"
        case (.medium, false): name = "NewsreaderRoman-Medium"
        case (.light, false), (.thin, false), (.ultraLight, false): name = "NewsreaderRoman-Light"
        case (_, false): name = "Newsreader16pt-Regular"
        case (.bold, true), (.heavy, true), (.black, true): name = "NewsreaderItalic-Bold"
        case (.semibold, true): name = "NewsreaderItalic-SemiBold"
        case (.medium, true): name = "NewsreaderItalic-Medium"
        case (_, true): name = "Newsreader16pt-Italic"
        }
        return .custom(name, size: size)
    }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "IBMPlexSans-Bold"
        case .semibold: name = "IBMPlexSans-SemiBold"
        case .medium: name = "IBMPlexSans-Medium"
        case .light, .thin, .ultraLight: name = "IBMPlexSans-Light"
        default: name = "IBMPlexSans-Regular"
        }
        return .custom(name, size: size)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "IBMPlexMono-Regular" : "IBMPlexMono-Medium", size: size)
    }
}

extension QuireFont {
    /// Archivo is a variable font with width and weight axes; Marathon's display
    /// face is its 125% width at weight 800.
    static func archivo(_ size: CGFloat, weight: CGFloat = 400, width: CGFloat = 100) -> Font {
        #if canImport(UIKit)
        let wght = NSNumber(value: 2003265652), wdth = NSNumber(value: 2003072104)   // 'wght', 'wdth'
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: "ArchivoRoman-Regular",
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: weight, wdth: width],
        ])
        let font = UIFontMetrics.default.scaledFont(for: UIFont(descriptor: descriptor, size: size))
        return Font(font)
        #else
        return .system(size: size, weight: weight >= 700 ? .heavy : weight >= 500 ? .medium : .regular)
        #endif
    }
    static func dmMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular || weight == .light ? "DMMono-Regular" : "DMMono-Medium", size: size)
    }
}

/// The type of a theme: what reads as writing, as apparatus, as a readout.
extension QuireTheme {
    /// Writing and list titles: Newsreader, or Archivo in Marathon.
    func writing(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        guard isMarathon else { return QuireFont.serif(size, weight: weight, italic: italic) }
        return QuireFont.archivo(size, weight: Self.axis(weight))
    }
    /// Big titles and figures: Newsreader, or Archivo Expanded Extra-Bold.
    func display(_ size: CGFloat) -> Font {
        if isMarathon { return QuireFont.archivo(size, weight: 800, width: 125) }
        return QuireFont.serif(size, weight: headWeight >= 650 ? .bold : headWeight >= 600 ? .semibold : headWeight >= 500 ? .medium : .regular)
    }
    /// Words around the writing: Plex Sans, or Archivo in Marathon.
    func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        isMarathon ? QuireFont.archivo(size, weight: Self.axis(weight)) : QuireFont.sans(size, weight: weight)
    }
    /// Small tracked labels and readouts: Plex Sans, or DM Mono in Marathon.
    func label(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        isMarathon ? QuireFont.dmMono(size, weight: weight) : QuireFont.sans(size, weight: weight)
    }
    /// Times, counts, paths.
    func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        isMarathon ? QuireFont.dmMono(size, weight: weight) : QuireFont.mono(size, weight: weight)
    }
    /// Text that Marathon sets in capitals (titles, labels); others keep its case.
    func caps(_ text: String) -> String { isMarathon ? text.uppercased() : text }
    /// Letter-spacing for labels, in points.
    func tracking(_ size: CGFloat) -> CGFloat { isMarathon ? size * 0.16 : size * 0.15 }

    private static func axis(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight: return 200
        case .thin: return 100
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }
}

// MARK: - Building blocks

/// A small label: "ON THIS DAY". Marathon sets it in tracked mono with a square
/// bullet, as a readout.
struct QLabel: View {
    @Environment(\.quire) private var q
    let text: String
    var trailing: String? = nil

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            if q.isMarathon { Text("■").foregroundStyle(q.signalColor) }
            Text(text.uppercased()).tracking(q.tracking(size))
            if let trailing {
                Spacer()
                Text(q.caps(trailing)).tracking(q.isMarathon ? 1.2 : 1.0)
            }
        }
        .font(q.label(size, weight: q.isMarathon ? .regular : .semibold))
        .foregroundStyle(q.mutedColor)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var size: CGFloat { q.isMarathon ? 10.5 : 11 }
}

/// A hairline in the theme's line colour.
struct QRule: View {
    @Environment(\.quire) private var q
    var body: some View {
        Rectangle().fill(q.lineColor).frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A text-only action: coloured words, no chrome, a 44pt target.
struct QLink: View {
    @Environment(\.quire) private var q
    let title: String
    var emphasised = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(q.caps(title))
                .tracking(q.isMarathon ? 1.2 : 0)
                .font(q.isMarathon ? q.label(12, weight: emphasised ? .medium : .regular)
                                   : q.ui(14, weight: emphasised ? .semibold : .regular))
                .foregroundStyle(emphasised ? q.accentColor : q.inkColor)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Marks and textures

/// The Quire mark: three nested sheets on one spine, the tail making a Q.
struct QMark: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn in the logo's own box (x 22–84, y 18–88), then fitted.
        let scale = min(rect.width / 62, rect.height / 70)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 22) * scale, y: rect.minY + (y - 18) * scale)
        }
        var path = Path()
        path.move(to: p(36, 24)); path.addCurve(to: p(36, 76), control1: p(76, 24), control2: p(76, 76))
        path.move(to: p(36, 34)); path.addCurve(to: p(36, 66), control1: p(64, 34), control2: p(64, 66))
        path.move(to: p(36, 44)); path.addCurve(to: p(36, 56), control1: p(52, 44), control2: p(52, 56))
        path.move(to: p(36, 24)); path.addLine(to: p(36, 76))
        path.move(to: p(58, 66)); path.addLine(to: p(76, 82))
        return path
    }
}

/// The short rule under a title: a solid bar, or in Marathon a segmented one.
struct QTitleRule: View {
    @Environment(\.quire) private var q
    var body: some View {
        if q.isMarathon {
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { _ in Rectangle().fill(q.signalColor).frame(width: 14, height: 6) }
            }
            .accessibilityHidden(true)
        } else {
            Rectangle().fill(q.accentColor).frame(width: 56, height: q.ruleH)
                .accessibilityHidden(true)
        }
    }
}

/// A rectangle with its top-right corner cut off.
struct QChamfer: Shape {
    var cut: CGFloat = 22
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A field of dots that thins out toward one corner.
struct QDotField: View {
    let color: Color
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 2
            while y < size.height {
                var x: CGFloat = 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.2, height: 2.2)), with: .color(color))
                    x += 5
                }
                y += 5
            }
        }
        .mask(LinearGradient(colors: [.black, .black.opacity(0.5), .clear],
                             startPoint: .topTrailing, endPoint: .bottomLeading))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Diagonal bands, like hazard tape.
struct QHazard: View {
    let color: Color
    var body: some View {
        Canvas { context, size in
            var x = -size.height
            while x < size.width {
                var band = Path()
                band.move(to: CGPoint(x: x, y: size.height))
                band.addLine(to: CGPoint(x: x + 6, y: size.height))
                band.addLine(to: CGPoint(x: x + 6 + size.height, y: 0))
                band.addLine(to: CGPoint(x: x + size.height, y: 0))
                band.closeSubpath()
                context.fill(band, with: .color(color))
                x += 12
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Settings skin

extension View {
    /// The settings form on the page: flat rows ruled with hairlines, in the
    /// theme's type and colours (iPhone only; the grouped look stays on Mac).
    func qFormSkin() -> some View { modifier(QFormSkin()) }
    /// The theme's page colour behind a section's rows (iPhone only).
    func qRowBackground() -> some View { modifier(QRowBackground()) }
}

private struct QRowBackground: ViewModifier {
    @Environment(\.quire) private var q
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listRowBackground(q.pageColor)
        #else
        content
        #endif
    }
}

/// The settings container: a flat plain list on iPhone (a Form forces rounded
/// grouped cards there), the usual Form on Mac.
struct QSettingsContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(iOS)
        List { content }.listStyle(.plain)
        #else
        Form { content }
        #endif
    }
}

private struct QFormSkin: ViewModifier {
    @Environment(\.quire) private var q
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .scrollContentBackground(.hidden)
            .background(q.pageColor.ignoresSafeArea())
            .listRowSeparatorTint(q.lineColor)
            .font(q.ui(16))
            .foregroundStyle(q.inkColor)
            .tint(q.accentColor)
        #else
        content
        #endif
    }
}
