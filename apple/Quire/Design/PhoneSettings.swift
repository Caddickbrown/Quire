//
//  PhoneSettings.swift
//  Quire
//
//  The settings you reach for: folder, theme, writing. Each is a label and
//  words to pick between; the page you are on is underlined in the accent. The
//  long tail (backups, imports, security, media) is one tap away.
//

#if os(iOS)

import SwiftUI

struct PhoneSettings: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q
    @Environment(\.dismiss) private var dismiss
    @AppStorage(QuireTheme.storageKey) private var themeID = QuireTheme.auto
    @AppStorage(PromptDeck.enabledKey) private var prompts = false
    @AppStorage("wordGoalEnabled") private var goalOn = false
    @AppStorage("wordGoal") private var goal = 750

    private static let pages: [(group: SettingsGroup, title: String, detail: String)] = [
        (.folder, "Folder and backups", "Where the journal lives; backups, restore"),
        (.maintenance, "Import and export", "Day One, markdown, transfer.md; export; clean-up; tags"),
        (.looks, "Writing and display", "Type, dates, calendar, writing aids, goal"),
        (.reminders, "Reminders", "A daily line; \u{201C}From your journal\u{201D} each week"),
        (.privacy, "Privacy", "Face ID lock, Spotlight"),
        (.media, "Media", "Data Saver for photos, video and voice"),
        (.journal, "Split tags and templates", "Tags that file to their own journal; templates"),
        (.display, "External display", "Mirror the page to a monitor"),
        (.help, "Help", "Shortcuts, how to, what\u{2019}s new"),
    ]

    /// `QUIRE_SETTINGS_PAGE=folder` (and so on) opens that page at once (screenshots).
    @State private var path: [SettingsGroup] = {
        ProcessInfo.processInfo.environment["QUIRE_SETTINGS_PAGE"].flatMap(SettingsGroup.init(rawValue:)).map { [$0] } ?? []
    }()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack {
                        Spacer()
                        QLink(title: "Done") { dismiss() }
                    }
                    QTitle(kicker: "Quire", title: "Settings", size: 40)
                    section("Folder") {
                        Text(store.storagePath).font(q.mono(14)).foregroundStyle(q.inkColor)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Plain markdown in the jnl layout, plus Quire's .quire/ and assets/.")
                            .font(q.ui(13)).foregroundStyle(q.mutedColor)
                    }
                    section("Theme") {
                        ThemePicker(selected: themeID) { themeID = $0 }
                    }
                    section("Writing") {
                        toggle("Prompts on an empty page", $prompts)
                        toggle("Daily word goal", $goalOn)
                        if goalOn {
                            FlowChoices(options: [100, 250, 500, 750, 1000].map { (String($0), String($0)) },
                                        selected: String(goal)) { goal = Int($0) ?? goal }
                        }
                    }
                    section("More") {
                        ForEach(Self.pages, id: \.group) { page in
                            NavigationLink(value: page.group) {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(page.title).font(q.writing(20)).foregroundStyle(q.inkColor)
                                        Text(page.detail).font(q.ui(13)).foregroundStyle(q.mutedColor)
                                    }
                                    Spacer()
                                    Text("→").foregroundStyle(q.accentColor)
                                }
                                .frame(minHeight: 52).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) { QRule() }
                        }
                    }
                }
                .padding(.horizontal, 26).padding(.top, 12).padding(.bottom, 40)
            }
            .background(q.pageColor.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SettingsGroup.self) { group in
                PhoneSettingsPage(group: group, title: Self.pages.first { $0.group == group }?.title ?? "")
                    .environmentObject(store)
            }
        }
        .tint(q.accentColor)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            QRule()
            QLabel(title).padding(.top, 4)
            content()
        }
    }

    private func toggle(_ label: String, _ value: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(q.ui(15)).foregroundStyle(q.mutedColor)
            Spacer()
            HStack(spacing: 8) {
                choice("On", value.wrappedValue) { value.wrappedValue = true }
                Text("/").foregroundStyle(q.faintColor)
                choice("Off", !value.wrappedValue) { value.wrappedValue = false }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func choice(_ title: String, _ on: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(q.ui(15, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? q.accentColor : q.mutedColor).underline(on, color: q.accentColor)
                .frame(minWidth: 30, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Words to pick between, wrapping onto a second line when they must.
private struct FlowChoices: View {
    @Environment(\.quire) private var q
    let options: [(id: String, name: String)]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        // A wrapping row, built from the fewest lines that fit.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 20) {
                    ForEach(row, id: \.id) { option in
                        Button { pick(option.id) } label: {
                            Text(option.name)
                                .font(q.writing(19))
                                .foregroundStyle(option.id == selected ? q.accentColor : q.inkColor)
                                .underline(option.id == selected, color: q.accentColor)
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option.id == selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    /// About 24 characters to a line at this size.
    private var rows: [[(id: String, name: String)]] {
        var out: [[(id: String, name: String)]] = [[]]
        var width = 0
        for option in options {
            let w = option.name.count + 3
            if width + w > 26, !out[out.count - 1].isEmpty { out.append([]); width = 0 }
            out[out.count - 1].append(option); width += w
        }
        return out
    }
}


/// One page of the earlier settings, under Quire's own header: a way back, the
/// page's name, and the sections themselves in the theme's rows.
struct PhoneSettingsPage: View {
    @Environment(\.quire) private var q
    @Environment(\.dismiss) private var dismiss
    let group: SettingsGroup
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                QLink(title: "‹ Settings") { dismiss() }
                Spacer()
            }
            .padding(.horizontal, 22).padding(.top, 8)
            QTitle(kicker: "Settings", title: title, size: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26).padding(.top, 6).padding(.bottom, 8)
            SettingsView(group: group)
        }
        .background(q.pageColor.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Themes as two groups, light and dark, each a row with a swatch of its own
/// paper, ink, accent and type. "Auto" follows the phone's appearance.
private struct ThemePicker: View {
    @Environment(\.quire) private var q
    let selected: String
    let pick: (String) -> Void

    private static let blurb: [String: String] = [
        "almanac": "Warm paper, terracotta, a book's serif",
        "broadsheet": "Newsprint: black on white, heavy rules",
        "linen": "Cool grey paper, a quiet blue",
        "cinema": "Warm dark, a low ember accent",
        "night": "Cool dark, a muted green accent",
        "marathon": "Black, signal lime, wide type and readouts",
        "marathon-day": "Pale concrete, lime blocks, wide type",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row(id: QuireTheme.auto, name: "Auto", detail: "Follows your phone: Almanac by day, Cinema at night", swatch: nil)
            group("Light", QuireTheme.all.filter { !$0.dark })
            group("Dark", QuireTheme.all.filter { $0.dark })
        }
    }

    private func group(_ title: String, _ themes: [QuireTheme]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            QLabel(title).padding(.bottom, 6)
            ForEach(themes) { theme in
                row(id: theme.id, name: theme.name, detail: Self.blurb[theme.id] ?? "", swatch: theme)
            }
        }
    }

    private func row(id: String, name: String, detail: String, swatch: QuireTheme?) -> some View {
        let on = id == selected
        return Button { pick(id) } label: {
            HStack(spacing: 14) {
                if let t = swatch {
                    ZStack(alignment: .bottomLeading) {
                        Rectangle().fill(t.pageColor)
                        Text("Aa").font(t.display(15)).foregroundStyle(t.inkColor)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Rectangle().fill(t.signalColor).frame(height: 4)
                    }
                    .frame(width: 40, height: 40)
                    .overlay(Rectangle().stroke(on ? q.accentColor : q.lineColor, lineWidth: on ? 2 : 1))
                } else {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 20))
                        .foregroundStyle(q.mutedColor).frame(width: 40, height: 40)
                        .overlay(Rectangle().stroke(on ? q.accentColor : q.lineColor, lineWidth: on ? 2 : 1))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(q.writing(19)).foregroundStyle(on ? q.accentColor : q.inkColor)
                    if !detail.isEmpty { Text(detail).font(q.ui(13)).foregroundStyle(q.mutedColor) }
                }
                Spacer()
                if on { Text("✓").font(q.ui(16, weight: .semibold)).foregroundStyle(q.accentColor) }
            }
            .padding(.vertical, 8).frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { QRule() }
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(detail.isEmpty ? name : "\(name), \(detail)")
    }
}

#endif
