//
//  NookWidget.swift
//  NookWidget
//
//  WidgetKit extension for Nook. Three sizes:
//
//  Small  — current streak + inbox count. Taps → Write screen.
//  Medium — streak, days, entries, words, drafts + "New Draft" button.
//  Large  — same as medium, plus word-count context and best streak.
//
//  Stats come from NookSnapshot written to the shared App Group by the
//  main app after every reload. No direct file access from the widget.
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline

struct NookEntry: TimelineEntry {
    let date: Date
    let snap: NookSnapshot
}

struct NookProvider: TimelineProvider {
    func placeholder(in context: Context) -> NookEntry {
        NookEntry(date: Date(), snap: NookSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (NookEntry) -> Void) {
        completion(NookEntry(date: Date(), snap: NookSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NookEntry>) -> Void) {
        let snap  = NookSnapshot.load()
        let entry = NookEntry(date: Date(), snap: snap)
        // Refresh every 30 minutes — widgets can't push updates,
        // so the main app writes the snapshot and we pick it up here.
        let next  = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Accent colour helper

private func accentColor(for raw: String) -> Color {
    switch raw {
    case "indigo": return Color(red:  92/255, green:  92/255, blue: 214/255)
    case "purple": return Color(red: 148/255, green:  92/255, blue: 214/255)
    case "pink":   return Color(red: 224/255, green:  86/255, blue: 140/255)
    case "red":    return Color(red: 224/255, green:  74/255, blue:  74/255)
    case "orange": return Color(red: 240/255, green: 140/255, blue:  56/255)
    case "teal":   return Color(red:  36/255, green: 170/255, blue: 168/255)
    case "green":  return Color(red:  52/255, green: 168/255, blue: 108/255)
    default:       return Color(red:  28/255, green: 126/255, blue: 214/255) // blue
    }
}

// MARK: - Shared sub-views

/// One stat cell: big number + small label.
private struct StatCell: View {
    let value: String
    let label: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.custom("Lato-Bold", size: 22))
                .foregroundColor(accent)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.custom("Lato-Regular", size: 10))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }
}

/// Flame streak display — big number with a small flame glyph.
private struct StreakBadge: View {
    let streak: Int
    let accent: Color
    let large: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(streak)")
                .font(.custom("Lato-Bold", size: large ? 42 : 32))
                .foregroundColor(accent)
            Image(systemName: "flame.fill")
                .font(.system(size: large ? 18 : 14))
                .foregroundColor(accent.opacity(0.7))
        }
    }
}

// MARK: - Small widget

private struct SmallWidgetView: View {
    let entry: NookEntry
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { accentColor(for: entry.snap.accentRaw) }
    private var bg: Color { scheme == .dark ? Color(white: 0.10) : Color(white: 0.97) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            bg
            VStack(alignment: .leading, spacing: 8) {
                // Top: nook wordmark
                Text("nook")
                    .font(.custom("Lato-Regular", size: 11))
                    .foregroundColor(.secondary)
                    .textCase(.lowercase)
                    .tracking(1)

                Spacer()

                // Streak — the hero stat
                StreakBadge(streak: entry.snap.currentStreak, accent: accent, large: false)
                Text("day streak")
                    .font(.custom("Lato-Regular", size: 10))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()

                // Inbox drafts
                HStack(spacing: 4) {
                    Image(systemName: "tray")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("\(entry.snap.inboxDrafts) draft\(entry.snap.inboxDrafts == 1 ? "" : "s")")
                        .font(.custom("Lato-Regular", size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
        }
        .widgetURL(URL(string: "nook://write"))
    }
}

// MARK: - Medium widget

private struct MediumWidgetView: View {
    let entry: NookEntry
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { accentColor(for: entry.snap.accentRaw) }
    private var bg: Color { scheme == .dark ? Color(white: 0.10) : Color(white: 0.97) }

    var body: some View {
        ZStack {
            bg
            HStack(spacing: 0) {
                // Left: streak hero
                VStack(alignment: .leading, spacing: 4) {
                    Text("nook")
                        .font(.custom("Lato-Regular", size: 11))
                        .foregroundColor(.secondary)
                        .tracking(1)
                    Spacer()
                    StreakBadge(streak: entry.snap.currentStreak, accent: accent, large: true)
                    Text("day streak")
                        .font(.custom("Lato-Regular", size: 10))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    // New draft deep-link
                    Link(destination: URL(string: "nook://write")!) {
                        Label("New Draft", systemImage: "square.and.pencil")
                            .font(.custom("Lato-Regular", size: 12))
                            .foregroundColor(accent)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Divider
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 1)
                    .padding(.vertical, 14)

                // Right: stats grid
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        StatCell(value: "\(entry.snap.totalDays)", label: "Days", accent: accent)
                        StatCell(value: "\(entry.snap.totalEntries)", label: "Entries", accent: accent)
                    }
                    HStack(spacing: 16) {
                        StatCell(value: formatWords(entry.snap.totalWords), label: "Words", accent: accent)
                        StatCell(value: "\(entry.snap.inboxDrafts)", label: "Drafts", accent: accent)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func formatWords(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000.0) : "\(n)"
    }
}

// MARK: - Large widget

private struct LargeWidgetView: View {
    let entry: NookEntry
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { accentColor(for: entry.snap.accentRaw) }
    private var bg: Color { scheme == .dark ? Color(white: 0.10) : Color(white: 0.97) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("nook")
                        .font(.custom("Lato-Regular", size: 12))
                        .foregroundColor(.secondary)
                        .tracking(1)
                    Spacer()
                    Link(destination: URL(string: "nook://write")!) {
                        Label("New Draft", systemImage: "square.and.pencil")
                            .font(.custom("Lato-Regular", size: 12))
                            .foregroundColor(accent)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider().opacity(0.2)

                // Streak hero
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        StreakBadge(streak: entry.snap.currentStreak, accent: accent, large: true)
                        Text("day streak")
                            .font(.custom("Lato-Regular", size: 11))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(entry.snap.bestStreak)")
                            .font(.custom("Lato-Bold", size: 28))
                            .foregroundColor(accent.opacity(0.5))
                        Text("best streak")
                            .font(.custom("Lato-Regular", size: 10))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                Divider().opacity(0.2)

                // Stats grid
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 16
                ) {
                    StatCell(value: "\(entry.snap.totalDays)",    label: "Days",    accent: accent)
                    StatCell(value: "\(entry.snap.totalEntries)", label: "Entries", accent: accent)
                    StatCell(value: formatWords(entry.snap.totalWords), label: "Words", accent: accent)
                    StatCell(value: "\(entry.snap.inboxDrafts)",  label: "Drafts",  accent: accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                Spacer()
            }
        }
        .widgetURL(URL(string: "nook://write"))
    }

    private func formatWords(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000.0) : "\(n)"
    }
}

// MARK: - Widget definition

struct NookWidget: Widget {
    let kind = "NookWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NookProvider()) { entry in
            NookWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Nook")
        .description("Your writing streak and journal stats at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NookWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NookEntry

    var body: some View {
        switch family {
        case .systemSmall:  SmallWidgetView(entry: entry)
        case .systemLarge:  LargeWidgetView(entry: entry)
        default:            MediumWidgetView(entry: entry)
        }
    }
}
