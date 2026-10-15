import SwiftUI

/// External-display looks use the same source as Linux and the terminal.
struct ExternalTheme: Decodable, Identifiable {
    static let key = "externalDisplayTheme"
    let id: String
    let name: String
    let dark: Bool
    let page: String
    let ink: String
    let muted: String
    let faint: String
    let accent: String
    let line: String
    let writing_font: String
    let rule_h: CGFloat
    let head_weight: Double

    static let all: [ExternalTheme] = {
        struct Catalog: Decodable { let themes: [ExternalTheme] }
        guard let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return catalog.themes
    }()
    static func selected(_ id: String) -> ExternalTheme? { all.first { $0.id == id } ?? all.first }
    var fontRaw: String { writing_font.contains("Mono") ? "mono" : "serif" }
    var headingWeight: Font.Weight { head_weight >= 700 ? .bold : head_weight >= 600 ? .semibold : head_weight >= 500 ? .medium : .regular }
    var paper: Color { Self.color(page) }
    var text: Color { Self.color(ink) }
    var secondary: Color { Self.color(muted) }
    var placeholder: Color { Self.color(faint) }
    var highlight: Color { Self.color(accent) }
    var rule: Color { Self.color(line) }
    private static func color(_ hex: String) -> Color {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
private struct ExternalThemeKey: EnvironmentKey { static let defaultValue: ExternalTheme? = nil }
extension EnvironmentValues {
    var externalTheme: ExternalTheme? {
        get { self[ExternalThemeKey.self] }
        set { self[ExternalThemeKey.self] = newValue }
    }
}
