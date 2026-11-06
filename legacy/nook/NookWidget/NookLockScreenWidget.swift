//
//  NookLockScreenWidget.swift
//  NookWidget
//
//  A Lock Screen accessory widget that is just a button: tap it to open Nook's
//  composer on a new entry. No stats, no timeline data — the whole surface is a
//  `nook://write` deep link.
//
//  Accessory families are iOS-only (macOS has no Lock Screen), so the whole file
//  is compiled out on macOS.
//

#if os(iOS)
import WidgetKit
import SwiftUI

// MARK: - Timeline

/// The widget shows no data, so one entry that never needs refreshing is enough.
struct NookNewEntryEntry: TimelineEntry {
    let date: Date
}

struct NookNewEntryProvider: TimelineProvider {
    func placeholder(in context: Context) -> NookNewEntryEntry {
        NookNewEntryEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (NookNewEntryEntry) -> Void) {
        completion(NookNewEntryEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NookNewEntryEntry>) -> Void) {
        completion(Timeline(entries: [NookNewEntryEntry(date: Date())], policy: .never))
    }
}

// MARK: - Views

/// Lock Screen widgets render monochrome (vibrant/accented), so these views set
/// no colours of their own and let the system tint them.
private struct NewEntryAccessoryView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 22))
            }
        case .accessoryInline:
            // Inline sits beside the clock: one line, symbol + text, no styling.
            Label("New Draft", systemImage: "square.and.pencil")
        default:
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15))
                Text("New Draft")
                    .font(.custom("Lato-Regular", size: 15))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Widget definition

struct NookNewEntryWidget: Widget {
    let kind = "NookNewEntryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NookNewEntryProvider()) { _ in
            NewEntryAccessoryView()
                .widgetURL(URL(string: "nook://write"))
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("New Draft")
        .description("A button that opens Nook ready to write.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
#endif
