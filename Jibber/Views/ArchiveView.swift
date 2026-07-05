//
//  ArchiveView.swift
//  Jibber
//
//  Browse filed entries (jnl `browse`): days grouped by year, drilling into a
//  day's entries. Newest first throughout.
//

import SwiftUI

struct ArchiveView: View {
    @EnvironmentObject private var store: JournalStore

    /// Group "YYYY-MM-DD" dates by year, each year's dates newest-first.
    private var groupedByYear: [(year: String, dates: [String])] {
        let groups = Dictionary(grouping: store.archiveDates) { String($0.prefix(4)) }
        return groups.keys.sorted(by: >).map { year in
            (year, (groups[year] ?? []).sorted(by: >))
        }
    }

    var body: some View {
        Group {
            if store.archiveDates.isEmpty {
                ContentUnavailableView(
                    "No entries yet",
                    systemImage: "archivebox",
                    description: Text("File drafts from your inbox and they'll show up here.")
                )
            } else {
                List {
                    ForEach(groupedByYear, id: \.year) { group in
                        Section(group.year) {
                            ForEach(group.dates, id: \.self) { date in
                                NavigationLink {
                                    DayView(date: date)
                                } label: {
                                    DayRow(date: date, count: store.entries(for: date).count)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Archive")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct DayRow: View {
    let date: String
    let count: Int

    var body: some View {
        HStack {
            Text(Self.displayDate(date))
            Spacer()
            Text("\(count) \(count == 1 ? "entry" : "entries")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "2026-05-10" → "Mon, 10 May".
    static func displayDate(_ date: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let d = parser.date(from: date) else { return date }
        let out = DateFormatter()
        out.dateFormat = "EEE, d MMM"
        return out.string(from: d)
    }
}

/// One day's filed entries.
struct DayView: View {
    @EnvironmentObject private var store: JournalStore
    let date: String

    var body: some View {
        List {
            ForEach(store.entries(for: date)) { entry in
                NavigationLink {
                    EntryDetailView(entry: entry, source: .archive(date: date))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.header)
                            .font(.subheadline.weight(.medium))
                        if !entry.body.isEmpty {
                            Text(entry.body)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(DayRow.displayDate(date))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
