//
//  ThemesSheet.swift
//  Wander
//
//  The theme page: every theme drawn in its own colours and its own faces, so
//  the choice is made by looking rather than by reading a name. Picking one
//  changes the look only: type size and leading are the reader's, and stay
//  where the Options steppers left them.
//

import SwiftUI
import WanderCore

struct ThemesSheet: View {
    @Binding var themeID: String
    @Binding var typeSize: Double
    @Binding var leading: Double
    @Binding var appearance: Appearance
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 236, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule(weight: max(1, theme.mastheadRule), tone: theme.ink)
                .padding(.horizontal, 24)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Theme.all) { entry in
                        ThemeCard(theme: Theme.resolve(entry.id, previewScheme),
                                  leading: leading,
                                  chosen: entry.id == themeID) {
                            pick(entry)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .background(theme.paper.color)
    }

    /// The cards are drawn in whichever appearance the picker is set to, so
    /// deciding between light and dark means seeing it.
    private var previewScheme: ColorScheme {
        appearance.colorScheme ?? scheme
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("Themes")
                .font(theme.display(24))
                .foregroundStyle(theme.ink.color)
            SmallCaps("\(Theme.all.count) looks · one journal")
            Spacer()
            paperPicker
            // A sheet can't be dismissed by clicking away from it, so the way
            // out has to be visible — and Escape has to work.
            Button { dismiss() } label: {
                SmallCaps("Done", tone: theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                            .stroke(theme.rule.color, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    /// Auto, light or dark — a theme is half its appearance.
    private var paperPicker: some View {
        HStack(spacing: 0) {
            ForEach(Appearance.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { appearance = option }
                } label: {
                    SmallCaps(option.label, tone: option == appearance ? theme.paper : theme.muted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(option == appearance ? theme.accent.color : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                .stroke(theme.rule.color, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.corner, style: .continuous))
    }

    private func pick(_ entry: Theme) {
        // Type size and leading are the reader's settings, not the look's: a
        // theme change leaves them exactly where they were.
        withAnimation(.easeOut(duration: 0.18)) { themeID = entry.id }
        // Choosing is the end of the errand: close, and let them see it.
        dismiss()
    }
}

/// One theme, drawn in itself: masthead, rule, title, two lines of prose, the
/// accent block. Small enough to sit twelve to a screen, complete enough to
/// decide from.
private struct ThemeCard: View {
    let theme: Theme
    let leading: Double
    let chosen: Bool
    let action: () -> Void
    @Environment(\.theme) private var host
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                caption
            }
            .background(host.surface.color)
            .overlay {
                RoundedRectangle(cornerRadius: host.corner, style: .continuous)
                    .stroke(chosen ? host.accent.color : host.rule.color,
                            lineWidth: chosen ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: host.corner, style: .continuous))
            .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var preview: some View {
        VStack(alignment: theme.centred ? .center : .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("wander")
                    .font(theme.display(13))
                    .tracking(theme.displayTracking)
                    .textCase(theme.displayUppercase ? .uppercase : nil)
                    .foregroundStyle(theme.ink.color)
                Text(theme.labelText("journal"))
                    .font(theme.label(7.5))
                    .tracking(theme.labelTracking * 0.7)
                    .foregroundStyle(theme.accent.color)
                Spacer(minLength: 0)
            }
            if theme.mastheadRule > 0 {
                Rectangle().fill(theme.ink.color)
                    .frame(height: min(theme.mastheadRule, 3))
                    .padding(.top, 5)
            } else {
                Spacer().frame(height: 6)
            }

            Text("The long way round")
                .font(theme.display(min(21, 15 * theme.displayScale)))
                .tracking(theme.displayTracking)
                .textCase(theme.displayUppercase ? .uppercase : nil)
                .foregroundStyle(theme.ink.color)
                .lineLimit(2)
                .multilineTextAlignment(theme.centred ? .center : .leading)
                .padding(.top, 12)

            Text(theme.labelText("8 sep · 122 words"))
                .font(theme.label(7))
                .tracking(theme.labelTracking * 0.7)
                .foregroundStyle(theme.muted.color)
                .padding(.top, 5)

            Text("Left before seven and took the long way round the reservoir, which adds twenty minutes.")
                .font(theme.prose(9.5))
                .lineSpacing(9.5 * leading * 0.7)
                .foregroundStyle(theme.prose.color)
                .multilineTextAlignment(theme.centred ? .center : .leading)
                .padding(.top, 9)

            HStack(spacing: 6) {
                Text(theme.labelText("new entry"))
                    .font(theme.label(7))
                    .tracking(theme.labelTracking * 0.7)
                    .foregroundStyle(theme.filledButtons ? theme.paper.color : theme.accent.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background {
                        if theme.filledButtons {
                            RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                                .fill(theme.accent.color)
                        } else {
                            RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                                .stroke(theme.rule.color, lineWidth: 1)
                        }
                    }
                Circle().fill(theme.tint.color).frame(width: 7, height: 7)
                Circle().fill(theme.green.color).frame(width: 7, height: 7)
                Spacer(minLength: 0)
            }
            .padding(.top, 11)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(theme.paper.color)
        .background(ThemeOrnament(theme: theme, caption: "08"))
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                SchemeDot(hint: theme.recommended, theme: theme, host: host)
                Text(theme.name)
                    .font(host.ui(13, weight: .medium))
                    .foregroundStyle(host.ink.color)
                if chosen { SmallCaps("In use", tone: host.accent) }
                Spacer(minLength: 0)
            }
            Text(theme.note)
                .font(host.ui(11))
                .foregroundStyle(host.muted.color)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rule(tone: host.rule) }
    }
}


/// The appearance a theme was drawn for: a light circle, a dark circle, or one
/// half of each. Advice — every theme still carries both palettes.
private struct SchemeDot: View {
    let hint: Theme.SchemeHint
    let theme: Theme
    let host: Theme

    private let light = Color(.sRGB, red: 0.98, green: 0.98, blue: 0.97, opacity: 1)
    private let dark = Color(.sRGB, red: 0.09, green: 0.09, blue: 0.09, opacity: 1)

    var body: some View {
        ZStack {
            switch hint {
            case .light:
                Circle().fill(light)
            case .dark:
                Circle().fill(dark)
            case .both:
                Circle().fill(light)
                Circle()
                    .trim(from: 0, to: 0.5)
                    .fill(dark)
                    .rotationEffect(.degrees(90))
            }
            Circle().stroke(host.muted.opacity(0.6).color, lineWidth: 1)
        }
        .frame(width: 11, height: 11)
        .help("Best in \(hint.label.lowercased())")
    }
}
