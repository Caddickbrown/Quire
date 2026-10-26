//
//  QuireLockScreenWidget.swift
//  QuireWidget
//
//  Lock Screen accessories. They render monochrome — the system tints them —
//  so they set no colours of their own, only the app's type and the mark.
//
//  New Draft (QuireNewEntryWidget) — a way in: the mark, or "Begin a new
//  entry" over today's prompt. Opens the composer.
//  Today (QuireTodayAccessory) — the day at a glance: a ring of today's words
//  against the goal (the streak when the goal is off), the figures, or one
//  inline line beside the date. Opens Today.
//
//  Accessory families are iOS-only (macOS has no Lock Screen), so the whole file
//  is compiled out on macOS.
//

#if os(iOS)
import WidgetKit
import SwiftUI

// MARK: - New Draft

private struct NewEntryAccessoryView: View {
    let day: WidgetDay
    @Environment(\.widgetFamily) private var family
    @Environment(\.quire) private var q

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                WidgetMark(color: .primary, size: 22, square: q.isMarathon)
            }
            .accessibilityLabel("New entry")
        case .accessoryInline:
            // Inline sits beside the date: one line, symbol + text, no styling.
            Label("Begin a new entry", systemImage: "square.and.pencil")
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(q.caps("Begin a new entry →")).font(q.isMarathon ? q.display(13) : q.writing(17))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(day.prompt).font(q.writing(12, italic: true)).opacity(0.8).lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct QuireNewEntryWidget: Widget {
    // The kind is kept from the first version, so placed widgets carry over.
    let kind = "QuireNewEntryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuireProvider()) { entry in
            QuireWidgetPage(snap: entry.snap, paintsPage: false) {
                NewEntryAccessoryView(day: WidgetDay(entry: entry))
            }
            .widgetURL(URL(string: "quire://write"))
        }
        .configurationDisplayName("New Draft")
        .description("Opens Quire ready to write, with today's prompt.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Today

private struct TodayAccessoryView: View {
    let day: WidgetDay
    @Environment(\.widgetFamily) private var family
    @Environment(\.quire) private var q

    var body: some View {
        switch family {
        case .accessoryCircular:
            if day.goal > 0 {
                Gauge(value: day.goalFraction) {
                    Text("Words")
                } currentValueLabel: {
                    WidgetMark(color: .primary, size: 18, square: q.isMarathon)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .accessibilityLabel("\(day.words) of \(day.goal) words today")
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 1) {
                        Text("\(day.streak)").font(q.display(24)).lineLimit(1).minimumScaleFactor(0.5)
                        Text("DAYS").tracking(1.2).font(q.label(8, weight: .semibold))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.streak) day streak")
            }
        case .accessoryInline:
            Text(inline)
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(day.goal > 0 ? "QUIRE · \(day.words)/\(day.goal)" : "QUIRE · \(day.words) WORDS")
                    .font(q.mono(10)).opacity(0.8)
                Text(q.caps(day.streak == 1 ? "1-day streak" : "\(day.streak)-day streak"))
                    .font(q.isMarathon ? q.display(13) : q.writing(17)).lineLimit(1)
                Text(day.drafts == 0 ? "Inbox clear" : day.drafts == 1 ? "1 draft waiting" : "\(day.drafts) drafts waiting")
                    .font(q.ui(12)).opacity(0.8).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private var inline: String {
        let streak = "\(day.streak)-day streak"
        switch day.drafts {
        case 0: return streak
        case 1: return "1 draft · " + streak
        default: return "\(day.drafts) drafts · " + streak
        }
    }
}

struct QuireTodayAccessory: Widget {
    let kind = "QuireTodayAccessory"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuireProvider()) { entry in
            QuireWidgetPage(snap: entry.snap, paintsPage: false) {
                TodayAccessoryView(day: WidgetDay(entry: entry))
            }
            .widgetURL(URL(string: "quire://today"))
        }
        .configurationDisplayName("Today")
        .description("Today's words against your goal, your streak and your drafts.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
#endif
