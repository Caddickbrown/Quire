//
//  TrendsView.swift
//  Nook
//
//  Stats → Trends: the corpus's shape over time — a GitHub-style year heat
//  strip (words per day), words per month, and the top tags' monthly counts.
//  All data comes from the off-main passes in YearReview.swift; nothing new is
//  stored. The heat strip is shared with Year in Review and its shareable card.
//

import SwiftUI
import Charts

/// One year as a week-column grid, each day shaded by words written. Drawn
/// with Canvas — 366 rounded rects is nothing, and it keeps layout exact.
struct HeatStripView: View {
    @Environment(\.accent) private var accent
    let year: String
    let dailyWords: [String: Int]
    var cellSize: CGFloat = 9
    var gap: CGFloat = 2

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// (day offset from Jan 1, words) for every day of the year, plus the
    /// weekday column offset of Jan 1.
    private var layout: (leadOffset: Int, dayCount: Int, start: Date)? {
        guard let start = Self.iso.date(from: "\(year)-01-01") else { return nil }
        let cal = Calendar.current
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        let days = cal.range(of: .day, in: .year, for: start)?.count
            ?? (cal.date(byAdding: .year, value: 1, to: start).map {
                cal.dateComponents([.day], from: start, to: $0).day ?? 365
            } ?? 365)
        return (lead, days, start)
    }

    var body: some View {
        if let layout {
            let columns = Int(ceil(Double(layout.leadOffset + layout.dayCount) / 7.0))
            let width = CGFloat(columns) * (cellSize + gap) - gap
            let height = 7 * (cellSize + gap) - gap
            let peak = max(dailyWords.values.max() ?? 1, 1)
            Canvas { context, _ in
                let cal = Calendar.current
                for day in 0..<layout.dayCount {
                    guard let date = cal.date(byAdding: .day, value: day, to: layout.start) else { continue }
                    let slot = layout.leadOffset + day
                    let rect = CGRect(
                        x: CGFloat(slot / 7) * (cellSize + gap),
                        y: CGFloat(slot % 7) * (cellSize + gap),
                        width: cellSize, height: cellSize)
                    let words = dailyWords[Self.iso.string(from: date)] ?? 0
                    let shade: Color = words == 0
                        ? Color.secondary.opacity(0.14)
                        // sqrt so a light day still visibly registers next to
                        // a marathon one.
                        : accent.opacity(0.25 + 0.75 * sqrt(Double(words) / Double(peak)))
                    context.fill(Path(roundedRect: rect, cornerRadius: cellSize * 0.22), with: .color(shade))
                }
            }
            .frame(width: width, height: height)
            .accessibilityLabel("\(year): days shaded by words written")
        }
    }
}

/// The Trends sheet.
struct TrendsView: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent

    @State private var data = TrendsData()
    @State private var heatYear = ""
    @State private var heatWords: [String: Int] = [:]
    @State private var loaded = false

    private static let monthLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        f.locale = .current
        return f
    }()
    private static let ymParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func label(_ ym: String) -> String {
        Self.ymParser.date(from: ym).map { Self.monthLabel.string(from: $0) } ?? ym
    }

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView("Reading the year…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        Section("\(heatYear), day by day") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HeatStripView(year: heatYear, dailyWords: heatWords)
                                    .padding(.vertical, 6)
                            }
                        }
                        Section("Words per month") {
                            Chart(data.months, id: \.self) { month in
                                BarMark(
                                    x: .value("Month", label(month)),
                                    y: .value("Words", data.monthWords[month] ?? 0)
                                )
                                .foregroundStyle(accent)
                                .cornerRadius(3)
                            }
                            .chartXAxis {
                                AxisMarks { value in
                                    AxisValueLabel {
                                        if let s = value.as(String.self) { Text(s).font(.caption2) }
                                    }
                                }
                            }
                            .frame(height: 160)
                            .padding(.vertical, 6)
                        }
                        if !data.topTags.isEmpty {
                            Section("Top tags by month") {
                                Chart {
                                    ForEach(data.topTags, id: \.tag) { series in
                                        ForEach(data.months, id: \.self) { month in
                                            LineMark(
                                                x: .value("Month", label(month)),
                                                y: .value("Entries", series.byMonth[month] ?? 0)
                                            )
                                            .foregroundStyle(by: .value("Tag", series.tag))
                                            .symbol(by: .value("Tag", series.tag))
                                        }
                                    }
                                }
                                .chartXAxis {
                                    AxisMarks { value in
                                        AxisValueLabel {
                                            if let s = value.as(String.self) { Text(s).font(.caption2) }
                                        }
                                    }
                                }
                                .frame(height: 200)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle("Trends")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Button("Done") { dismiss() } }
        }
        .task {
            let year = String(JournalStore.nowDate().prefix(4))
            heatYear = year
            async let trends = store.trends()
            async let review = store.yearReview(for: year)
            data = await trends
            heatWords = await review.dailyWords
            loaded = true
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }
}
