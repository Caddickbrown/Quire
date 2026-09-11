//
//  Components.swift
//  Wander
//
//  The vocabulary the whole interface is built from: small-caps labels, hairline
//  rules, the label/value field row, one solid accent block, and italic serif
//  marginalia. Nothing here knows about journals.
//

import SwiftUI
import WanderCore

/// 10.5pt semibold, uppercase, widely tracked — every label in the app.
struct SmallCaps: View {
    let text: String
    var tone: Tone?
    @Environment(\.theme) private var theme

    init(_ text: String, tone: Tone? = nil) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(theme.labelText(text))
            .font(theme.label())
            .tracking(theme.labelTracking)
            .foregroundStyle((tone ?? theme.muted).color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

/// Horizontal hairline. `weight: 2` with the ink tone is the masthead rule.
struct Rule: View {
    var weight: CGFloat = 1
    var tone: Tone?
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill((tone ?? theme.rule).color)
            .frame(height: weight)
    }
}

/// Vertical hairline — the column dividers.
struct VRule: View {
    var tone: Tone?
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill((tone ?? theme.rule).color)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

/// A ruled label/value line: label left in muted, value right in ink, hairline
/// underneath. The unit the parameter columns are made of.
struct FieldRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(theme.ui(13))
                    .foregroundStyle(theme.muted.color)
                Spacer(minLength: 6)
                value()
            }
            .padding(.vertical, 5)
            Rule()
        }
    }
}

extension FieldRow where Value == FieldValue {
    init(_ label: String, _ text: String, tint: Tone? = nil) {
        self.label = label
        self.value = { FieldValue(text: text, tint: tint) }
    }
}

struct FieldValue: View {
    let text: String
    var tint: Tone?
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.ui(13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle((tint ?? theme.ink).color)
            .lineLimit(1)
    }
}

/// The one solid block of colour on the page.
struct AccentBlock: View {
    let title: String
    var filled: Bool = true
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(theme.labelText(title))
                .font(theme.label(12.5))
                .tracking(theme.labelTracking * 0.4)
                .foregroundStyle(filled ? theme.paper.color : theme.accent.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Group {
                        if filled {
                            (hovering ? theme.accentDeep : theme.accent).color
                        } else {
                            (hovering ? theme.rule.opacity(0.6) : theme.rule.opacity(0)).color
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: theme.corner, style: .continuous))
                )
                .overlay {
                    if !filled {
                        RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                            .stroke(theme.rule.color, lineWidth: max(1, theme.border - 1))
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Italic serif note in the margin — the aside, never the argument.
struct Marginalia: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.proseItalic(12.5))
            .lineSpacing(3.5)
            .foregroundStyle(theme.muted.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small text-only control that reads as part of the page, not a button.
struct QuietButton: View {
    let title: String
    var tone: Tone?
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SmallCaps(title, tone: hovering ? (tone ?? theme.accentInk) : theme.muted)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Section heading inside a column: small caps over a little air.
struct SectionLabel: View {
    let text: String
    var body: some View {
        SmallCaps(text)
            .padding(.bottom, 7)
    }
}

/// A field value you can click — same weight as a plain value, accented on
/// hover so it reads as editable without becoming a button.
struct ValueButton: View {
    let text: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(theme.ui(13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle((hovering ? theme.accent : theme.ink).color)
                .underline(hovering, color: theme.accent.opacity(0.4).color)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A masthead page switch: accent while it is the page being read, grey
/// otherwise, ink on hover.
struct PageTab: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SmallCaps(title, tone: active ? theme.accentInk : (hovering ? theme.ink : theme.muted))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Shared timing, so every column opens and closes at the same pace.
enum Motion {
    static let column: Animation = .easeInOut(duration: 0.22)
    static let columnDuration: Duration = .milliseconds(220)
}

/// A column that slides rather than appears: the content keeps its width and the
/// frame around it closes, so the panel travels off its own edge instead of
/// reflowing as it goes.
///
/// It is also unmounted once it has gone. A closed column is still a view, and
/// SwiftUI rebuilds it on every change it watches — which for the panels means
/// on every keystroke, to redraw counts nobody can see. It is put back the
/// moment the column opens, and taken away only after the close has finished
/// travelling, so the slide is unaffected.
struct SlidingColumn<Content: View>: View {
    let open: Bool
    let width: CGFloat
    /// The side the hairline sits on.
    let rule: HorizontalEdge
    @ViewBuilder var content: () -> Content
    @State private var mounted: Bool

    init(open: Bool, width: CGFloat, ruleOn rule: HorizontalEdge,
         @ViewBuilder content: @escaping () -> Content) {
        self.open = open
        self.width = width
        self.rule = rule
        self.content = content
        _mounted = State(initialValue: open)
    }

    var body: some View {
        HStack(spacing: 0) {
            if rule == .leading { VRule() }
            Group {
                if mounted { content() }
            }
            .frame(width: width)
            if rule == .trailing { VRule() }
        }
        .frame(width: open ? width + 1 : 0,
               alignment: rule == .trailing ? .trailing : .leading)
        .clipped()
        .opacity(open ? 1 : 0)
        .onChange(of: open) { _, isOpen in
            guard !isOpen else { return mounted = true }
            Task {
                try? await Task.sleep(for: Motion.columnDuration)
                if !open { mounted = false }
            }
        }
    }
}
