//
//  EditorView.swift
//  Wander
//
//  One entry, set as a page: a serif title, a small-caps dateline, the rule,
//  then the prose. The measure is capped so a wide window makes margins, not
//  longer lines.
//

import SwiftUI
import WanderCore

struct EditorView: View {
    @ObservedObject var store: JournalStore
    @Binding var typeSize: Double
    @Binding var leading: Double
    let focusMode: Bool
    let typewriter: Bool
    var ornamentCaption: String = ""
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var focusToken = 0

    var body: some View {
        Group {
            if store.selectedEntry == nil {
                blank
            } else {
                page
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The ornament sits on the page, above its paper and below the
            // words — behind the whole window it was hidden by every column.
            ZStack {
                theme.paper.color
                // The rail is index furniture; everything else belongs on the page.
                if theme.ornament != .rail {
                    ThemeOrnament(theme: theme, caption: ornamentCaption)
                }
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rule(tone: theme.ink)
            ProseEditor(text: $store.draftBody,
                        style: ProseStyle(theme: theme,
                                          scheme: scheme,
                                          size: typeSize,
                                          leading: leading,
                                          typewriter: typewriter,
                                          dimInactive: focusMode),
                        focusToken: focusToken,
                        onEdit: store.edited)
                .padding(.top, 12)
            Rule(tone: theme.rule)
            status
        }
        .frame(maxWidth: theme.measure, alignment: theme.centred ? .center : .leading)
        .padding(.horizontal, theme.pageCard ? 30 : 40)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background {
            if theme.pageCard {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                        .fill(theme.green.color)
                        .offset(x: 9, y: 9)
                    RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                        .fill(theme.surface.color)
                    RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                        .stroke(theme.ink.color, lineWidth: theme.border)
                }
            }
        }
        .padding(theme.pageCard ? 20 : 0)
        .frame(maxWidth: .infinity)
        .onChange(of: store.draftTitle) { store.edited() }
        .onChange(of: store.selection) { focusToken += 1 }
        .onAppear { focusToken += 1 }
    }

    private var header: some View {
        VStack(alignment: theme.centred ? .center : .leading, spacing: 9) {
            if theme.kicker, !kickerText.isEmpty {
                SmallCaps(kickerText, tone: theme.accentInk)
            }
            TextField("", text: $store.draftTitle,
                      prompt: Text(theme.displayUppercase ? "UNTITLED" : "Untitled")
                        .font(theme.display(theme.titleSize))
                        .foregroundColor(theme.muted.opacity(0.5).color),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.display(theme.titleSize))
                .tracking(theme.displayTracking)
                .textCase(theme.displayUppercase ? .uppercase : nil)
                .multilineTextAlignment(theme.centred ? .center : .leading)
                .foregroundStyle(theme.ink.color)
                .onSubmit { focusToken += 1 }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button {
                    store.reschedulingEntry = store.selectedEntry
                } label: {
                    SmallCaps(dateline)
                }
                .buttonStyle(.plain)
                .help("Change the date and time")
                Spacer()
                if let entry = store.selectedEntry {
                    if store.isUnfiled(entry) {
                        QuietButton(title: "File", tone: theme.accent) {
                            store.toggleFiling(entry)
                        }
                        .help("Move this draft into journal/\(entry.date)")
                    }
                    QuietButton(title: entry.isStarred ? "\u{2731} Starred" : "Star",
                                tone: theme.accent) {
                        store.toggleStar(entry)
                    }
                }
            }
        }
        .padding(.bottom, 11)
    }

    private var status: some View {
        HStack(spacing: 14) {
            SmallCaps(counts)
            Spacer()
            SmallCaps(saveLabel, tone: saveTone)
        }
        .padding(.top, 9)
    }

    /// The magazine kicker: the day, and the first tag if the entry carries one.
    private var kickerText: String {
        guard let entry = store.selectedEntry, let date = entry.createdDate else { return "" }
        let day = Formats.longDay.string(from: date).components(separatedBy: ",").first ?? ""
        if let tag = entry.tags.first { return "\(day) · \(tag)" }
        return day
    }

    private var dateline: String {
        guard let entry = store.selectedEntry, let date = entry.createdDate else { return "" }
        var parts = [Formats.longDay.string(from: date), Formats.clock.string(from: date)]
        let tags = entry.tags
        if !tags.isEmpty { parts.append(tags.prefix(4).joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    private var counts: String {
        let words = Counts.words(store.draftBody)
        let characters = Counts.characters(store.draftBody)
        let minutes = Counts.readingMinutes(store.draftBody)
        var parts = ["\(words) \(words == 1 ? "word" : "words")", "\(characters) characters"]
        if minutes > 0 { parts.append("\(minutes) min read") }
        return parts.joined(separator: " · ")
    }

    private var saveLabel: String {
        switch store.saveState {
        case .idle: return store.selectedEntry?.source == nil ? "Unsaved draft" : "Saved"
        case .editing: return "Writing\u{2026}"
        case .saved(let at): return "Saved \(Formats.clock.string(from: at))"
        case .failed(let message): return "Not saved — \(message)"
        }
    }

    private var saveTone: Tone {
        if case .failed = store.saveState { return theme.accent }
        return theme.muted
    }

    private var blank: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nothing open")
                .font(theme.display(34))
                .foregroundStyle(theme.ink.color)
            Marginalia(text: "Press \u{2318}N to start an entry. It begins in "
                       + "\(store.baseURL.lastPathComponent)/inbox.md, and \u{2318}J files it into "
                       + "journal/YYYY/MM/DD.md — plain markdown either way, the same files jnl "
                       + "and Nook read.")
                .frame(maxWidth: 380, alignment: .leading)
            AccentBlock(title: "New entry") { store.newEntry() }
                .frame(width: 160)
        }
        .frame(maxWidth: theme.measure, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
