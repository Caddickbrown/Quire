//
//  ThemeSwiper.swift
//  wander (iOS)
//
//  The theme page on a phone: one theme per screen, swiped through like a
//  canvas, each drawn full size in its own colours, faces and furniture rather
//  than as a thumbnail. What you swipe to is what the app becomes.
//

#if os(iOS)
import SwiftUI
import WanderCore

struct ThemeSwiper: View {
    @Binding var themeID: String
    @Binding var typeSize: Double
    @Binding var leading: Double
    @Binding var appearance: Appearance
    @Environment(\.theme) private var host
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private var themes: [Theme] { Theme.all }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $index) {
                ForEach(Array(themes.enumerated()), id: \.offset) { position, entry in
                    ThemeSpread(theme: Theme.resolve(entry.id, previewScheme),
                                size: typeSize, leading: leading)
                        .tag(position)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .bottom)

            controls
        }
        .background(host.paper.color.ignoresSafeArea())
        .onAppear { index = themes.firstIndex { $0.id == themeID } ?? 0 }
    }

    private var current: Theme { themes[min(index, themes.count - 1)] }

    /// The spreads are drawn in the appearance the picker is set to, so
    /// switching Light/Dark here shows what you would actually get.
    private var previewScheme: ColorScheme {
        appearance.colorScheme ?? scheme
    }

    /// The only chrome over the spread: which one this is, whether it wants
    /// light or dark, and the one button that commits.
    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(themes.indices, id: \.self) { position in
                    Capsule()
                        .fill(position == index ? host.accent.color : host.muted.opacity(0.35).color)
                        .frame(width: position == index ? 16 : 5, height: 5)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SchemeDot(hint: current.recommended, host: host)
                Text(current.name)
                    .font(host.ui(17, weight: .medium))
                    .foregroundStyle(host.ink.color)
                if current.id == themeID { SmallCaps("In use", tone: host.accent) }
                Spacer(minLength: 0)
                paperPicker
            }

            Text(current.note)
                .font(host.ui(12))
                .foregroundStyle(host.muted.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    SmallCaps("Close")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay {
                            RoundedRectangle(cornerRadius: host.corner, style: .continuous)
                                .stroke(host.rule.color, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)

                Button { apply(current) } label: {
                    SmallCaps(current.id == themeID ? "In use" : "Use this one",
                              tone: host.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(host.accent.color)
                        .clipShape(RoundedRectangle(cornerRadius: host.corner, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(current.id == themeID)
                .opacity(current.id == themeID ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rule(tone: host.rule) }
    }

    /// Light, dark or auto, right here — a theme is half its appearance, and
    /// deciding between them means seeing both.
    private var paperPicker: some View {
        HStack(spacing: 0) {
            ForEach(Appearance.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { appearance = option }
                } label: {
                    SmallCaps(option.label,
                              tone: option == appearance ? host.paper : host.muted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(option == appearance ? host.accent.color : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: host.corner, style: .continuous)
                .stroke(host.rule.color, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: host.corner, style: .continuous))
    }

    private func apply(_ entry: Theme) {
        // Type size and leading stay as the reader set them.
        themeID = entry.id
        dismiss()
    }
}

/// A whole screen of a theme: masthead, a few index rows, the page, the
/// figures. Not the live journal — a fixed passage, so every theme is judged
/// on the same words.
private struct ThemeSpread: View {
    let theme: Theme
    let size: Double
    let leading: Double

    var body: some View {
        VStack(spacing: 0) {
            masthead
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                theme.paper.color
                if theme.ornament != .rail {
                    ThemeOrnament(theme: theme, caption: "08")
                }
            }
        }
    }

    @ViewBuilder
    private var masthead: some View {
        switch theme.mastheadStyle {
        case .band:
            row.padding(.horizontal, 18).padding(.top, 60).padding(.bottom, 14)
                .background(theme.ink.color)
        case .centred:
            VStack(spacing: 6) {
                wordmark
                pages
                Rule(weight: max(1, theme.mastheadRule), tone: theme.rule)
            }
            .padding(.horizontal, 18).padding(.top, 60).padding(.bottom, 8)
        case .double:
            VStack(spacing: 0) {
                wordmark.padding(.bottom, 8)
                Rule(weight: 3, tone: theme.ink)
                Rule(tone: theme.ink).padding(.top, 3)
                pages.padding(.top, 7)
            }
            .padding(.horizontal, 18).padding(.top, 60).padding(.bottom, 6)
        case .none:
            row.padding(.horizontal, 18).padding(.top, 60).padding(.bottom, 10)
        case .rule:
            VStack(spacing: 0) {
                row.padding(.bottom, 8)
                Rule(weight: theme.mastheadRule, tone: theme.ink)
            }
            .padding(.horizontal, 18).padding(.top, 60).padding(.bottom, 8)
        }
    }

    private var onBand: Bool { theme.mastheadStyle == .band }

    private var wordmark: some View {
        Text("wander")
            .font(theme.display(24 * min(1.15, theme.displayScale + 0.15)))
            .tracking(theme.displayTracking)
            .textCase(theme.displayUppercase ? .uppercase : nil)
            .foregroundStyle(onBand ? theme.paper.color : theme.ink.color)
    }

    private var pages: some View {
        HStack(spacing: 12) {
            SmallCaps("Journal", tone: onBand ? theme.accentOnBand : theme.accentInk)
            SmallCaps("Inbox 1", tone: onBand ? theme.paper.opacity(0.7) : theme.muted)
            SmallCaps("Starred", tone: onBand ? theme.paper.opacity(0.7) : theme.muted)
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            wordmark
            pages
            Spacer(minLength: 0)
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            if theme.ornament == .rail {
                ThemeOrnament(theme: theme).frame(width: 46)
            }
            VStack(alignment: theme.centred ? .center : .leading, spacing: 0) {
                if theme.kicker {
                    SmallCaps("Tuesday · @morning", tone: theme.accentInk)
                        .padding(.bottom, 7)
                }
                Text("The long way round the reservoir")
                    .font(theme.display(min(30, theme.titleSize * 0.78)))
                    .tracking(theme.displayTracking)
                    .foregroundStyle(theme.ink.color)
                    .multilineTextAlignment(theme.centred ? .center : .leading)
                SmallCaps("8 September · 08:12 · 122 words")
                    .padding(.top, 8)
                if theme.mastheadRule > 0 || theme.rowStyle == .rule {
                    Rule(tone: theme.ink).padding(.top, 9)
                }
                Text("Left before seven and took the long way round the reservoir, which adds "
                     + "twenty minutes and, this morning, was worth every one of them. Low and "
                     + "flat off the water, the kind that makes the far bank look printed "
                     + "rather than grown.")
                    .font(theme.prose(size * 0.92))
                    .lineSpacing(size * leading * 0.8)
                    .foregroundStyle(theme.prose.color)
                    .multilineTextAlignment(theme.centred ? .center : .leading)
                    .padding(.top, 14)

                entries.padding(.top, 20)
                figures.padding(.top, 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
        }
    }

    private var entries: some View {
        VStack(alignment: .leading, spacing: theme.rowStyle == .card ? 8 : 0) {
            ForEach(Array(["Sunday, and the fence again", "Half a page still counts"].enumerated()),
                    id: \.offset) { position, title in
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(theme.rowTitle(14.5))
                        .foregroundStyle(rowInk(position).color)
                    SmallCaps(position == 0 ? "7 sep · 58 words" : "6 sep · 42 words",
                              tone: rowInk(position).opacity(0.7))
                }
                .padding(.vertical, 9)
                .padding(.horizontal, theme.rowStyle == .plain ? 0 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rowFill(position).color)
                .overlay(alignment: .bottom) {
                    if theme.rowStyle == .rule { Rule(tone: theme.ruleFaint) }
                }
                .overlay {
                    if theme.rowStyle == .card {
                        RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                            .stroke(theme.rule.color, lineWidth: theme.border)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.rowStyle == .card ? theme.corner : 0,
                                            style: .continuous))
            }
        }
    }

    private func rowFill(_ position: Int) -> Tone {
        guard theme.rowStyle == .card else { return theme.paper.opacity(0) }
        if theme.rowColours { return position == 0 ? theme.tint : theme.surface }
        return theme.surface
    }

    private func rowInk(_ position: Int) -> Tone {
        rowFill(position).alpha == 0 ? theme.ink : rowFill(position).readable(theme.paper, theme.ink)
    }

    private var figures: some View {
        HStack(spacing: 10) {
            figure("Words", "122", 0)
            figure("Days", "4", 1)
            figure("Month", "8", 2)
        }
    }

    private func figure(_ label: String, _ value: String, _ position: Int) -> some View {
        let fills = theme.figureFills
        let fill = fills[position % fills.count]
        let onFill = theme.figureBlocks ? fill.readable(theme.paper, theme.ink) : theme.ink
        return VStack(alignment: .leading, spacing: 2) {
            SmallCaps(label, tone: theme.figureBlocks ? onFill.opacity(0.75) : theme.muted)
            Text(value)
                .font(theme.display(28 * min(1.2, theme.displayScale)))
                .foregroundStyle(onFill.color)
                .monospacedDigit()
        }
        .padding(theme.figureBlocks ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.figureBlocks ? fill.color : Color.clear)
        .overlay {
            if theme.figureBlocks && fill.hex == theme.surface.hex {
                RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                    .stroke(theme.rule.color, lineWidth: theme.border)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.corner, style: .continuous))
    }
}

/// Light, dark, or half of each.
private struct SchemeDot: View {
    let hint: Theme.SchemeHint
    let host: Theme

    private let light = Color(.sRGB, red: 0.98, green: 0.98, blue: 0.97, opacity: 1)
    private let dark = Color(.sRGB, red: 0.09, green: 0.09, blue: 0.09, opacity: 1)

    var body: some View {
        ZStack {
            switch hint {
            case .light: Circle().fill(light)
            case .dark: Circle().fill(dark)
            case .both:
                Circle().fill(light)
                Circle().trim(from: 0, to: 0.5).fill(dark).rotationEffect(.degrees(90))
            }
            Circle().stroke(host.muted.opacity(0.6).color, lineWidth: 1)
        }
        .frame(width: 13, height: 13)
    }
}
#endif
