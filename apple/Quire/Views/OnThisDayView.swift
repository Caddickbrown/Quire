//
//  OnThisDayView.swift
//  Quire
//
//  "On this day" — the banner at the top of the Journal (shown only when this
//  calendar day has entries in past years) and the sheet listing them, newest
//  year first.
//

import SwiftUI

/// The tappable teaser above the Journal list.
struct OnThisDayBanner: View {
    @Environment(\.accent) private var accent
    let years: Int          // how many past years have entries today
    let count: Int          // total entries across them
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("On this day")
                        .font(.callout.weight(.semibold))
                    Text("\(count) entr\(count == 1 ? "y" : "ies") from \(years) past year\(years == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The sheet: this calendar day across the years.
struct OnThisDaySheet: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue

    let days: [(date: String, entries: [Entry])]

    var body: some View {
        NavigationStack {
            List {
                ForEach(days, id: \.date) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            NavigationLink {
                                EntryDetailView(entry: entry, source: .archive(date: day.date))
                            } label: {
                                EntryPreviewRow(entry: entry, showTime: true)
                            }
                        }
                    } header: {
                        header(for: day.date)
                    }
                }
            }
            .navigationTitle("On This Day")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func header(for date: String) -> Text {
        let thisYear = Int(JournalStore.nowDate().prefix(4)) ?? 0
        let year = Int(date.prefix(4)) ?? thisYear
        let ago = thisYear - year
        return Text("\(Theme.sectionDate(date, style: dateStyleRaw)) — \(ago) year\(ago == 1 ? "" : "s") ago")
    }
}
