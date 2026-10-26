//
//  YearReview.swift
//  Nook
//
//  The annual retrospective behind Stats → Year in Review: words, streaks,
//  top tags, the busiest day — all computed from the corpus off the main
//  actor. Presentation (and the shareable card) lives in YearReviewView.
//

import Foundation

struct YearReview: Sendable, Equatable {
    var year = ""
    var entries = 0
    var words = 0
    var daysWritten = 0
    var longestStreak = 0
    var topTags: [(tag: String, count: Int)] = []
    var busiestDay = ""          // ISO date
    var busiestDayWords = 0
    var photoCount = 0
    var videoCount = 0
    var audioCount = 0
    var starred = 0
    var firstLine = ""           // first words written that year
    /// Words per ISO date — feeds the year heat strip.
    var dailyWords: [String: Int] = [:]

    static func == (a: YearReview, b: YearReview) -> Bool {
        a.year == b.year && a.entries == b.entries && a.words == b.words
    }
}

extension JournalStore {
    /// Years that have at least one filed entry, newest first.
    func yearsWithEntries() -> [String] {
        Array(Set(archiveDays.map(\.year))).sorted(by: >)
    }

    /// Build the review for one year, off-main (reads every day file of that year).
    func yearReview(for year: String) async -> YearReview {
        guard let base = baseURL else { return YearReview(year: year) }
        return await Task.detached(priority: .userInitiated) {
            Self.computeYearReview(base: base, year: year)
        }.value
    }

    nonisolated static func computeYearReview(base: URL, year: String) -> YearReview {
        let fm = FileManager.default
        var review = YearReview(year: year)
        let yearDir = base.appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent(year, isDirectory: true)
        var files: [URL] = []
        if let en = fm.enumerator(at: yearDir, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.pathExtension == "md" { files.append(u) }
        }
        files.sort { staticFileToDate($0) < staticFileToDate($1) }

        let ymd = DateFormatter()
        ymd.dateFormat = "yyyy-MM-dd"
        ymd.locale = Locale(identifier: "en_US_POSIX")

        var tagMap: [String: Int] = [:]
        var dates: [Date] = []
        for url in files {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let entries = JournalParser.parseEntries(content)
            guard !entries.isEmpty else { continue }
            let date = staticFileToDate(url)
            let dayWords = entries.reduce(0) { $0 + $1.wordCount }
            review.daysWritten += 1
            review.entries += entries.count
            review.words += dayWords
            if dayWords > review.busiestDayWords {
                review.busiestDayWords = dayWords
                review.busiestDay = date
            }
            review.dailyWords[date] = dayWords
            if review.firstLine.isEmpty, let first = entries.first {
                review.firstLine = first.preview
            }
            review.starred += entries.filter(\.isStarred).count
            for t in JournalParser.splitTags(content) { tagMap[t, default: 0] += 1 }
            for path in MediaLinks.paths(in: content) {
                switch MediaKind(path: path) {
                case .image: review.photoCount += 1
                case .video: review.videoCount += 1
                case .audio: review.audioCount += 1
                }
            }
            if let d = ymd.date(from: date) { dates.append(d) }
        }

        review.topTags = tagMap.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
            .prefix(5).map { $0 }

        let cal = Calendar.current
        var run = 0
        for (i, d) in dates.enumerated() {
            if i > 0, let next = cal.date(byAdding: .day, value: 1, to: dates[i - 1]),
               cal.isDate(next, inSameDayAs: d) { run += 1 } else { run = 1 }
            review.longestStreak = max(review.longestStreak, run)
        }
        return review
    }
}

// MARK: - Trends (words and tags over the months)

/// The Trends sheet's data: words per month and the top tags' monthly counts,
/// over a trailing window. Computed off-main from the day files.
struct TrendsData: Sendable, Equatable {
    /// "YYYY-MM", oldest first — the shared x-axis.
    var months: [String] = []
    var monthWords: [String: Int] = [:]
    /// Top tags (by total in the window) → month → count.
    var topTags: [(tag: String, byMonth: [String: Int])] = []

    static func == (a: TrendsData, b: TrendsData) -> Bool {
        a.months == b.months && a.monthWords == b.monthWords
            && a.topTags.map(\.tag) == b.topTags.map(\.tag)
    }
}

extension JournalStore {
    /// Words and tag counts for the trailing `monthsBack` months.
    func trends(monthsBack: Int = 12) async -> TrendsData {
        guard let base = baseURL else { return TrendsData() }
        return await Task.detached(priority: .userInitiated) {
            Self.computeTrends(base: base, monthsBack: monthsBack)
        }.value
    }

    nonisolated static func computeTrends(base: URL, monthsBack: Int) -> TrendsData {
        let fm = FileManager.default
        var data = TrendsData()

        // The window's months, oldest first.
        let cal = Calendar.current
        let ym = DateFormatter()
        ym.dateFormat = "yyyy-MM"
        ym.locale = Locale(identifier: "en_US_POSIX")
        var months: [String] = []
        for back in stride(from: monthsBack - 1, through: 0, by: -1) {
            if let d = cal.date(byAdding: .month, value: -back, to: Date()) {
                months.append(ym.string(from: d))
            }
        }
        data.months = months
        let window = Set(months)

        var tagTotals: [String: Int] = [:]
        var tagMonthly: [String: [String: Int]] = [:]
        let journalDir = base.appendingPathComponent("journal", isDirectory: true)
        if let en = fm.enumerator(at: journalDir, includingPropertiesForKeys: nil) {
            for case let url as URL in en where url.pathExtension == "md" {
                let month = String(staticFileToDate(url).prefix(7))
                guard window.contains(month),
                      let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let words = content.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
                data.monthWords[month, default: 0] += words
                for tag in JournalParser.splitTags(content) {
                    tagTotals[tag, default: 0] += 1
                    tagMonthly[tag, default: [:]][month, default: 0] += 1
                }
            }
        }
        data.topTags = tagTotals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5)
            .map { (tag: $0.key, byMonth: tagMonthly[$0.key] ?? [:]) }
        return data
    }
}
