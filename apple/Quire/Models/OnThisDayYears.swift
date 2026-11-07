import Foundation

/// "On this day", a group to a year: the year said once, its entries under it.
enum OnThisDayYears {
    struct Dated<Item> {
        let date: String
        let item: Item
    }

    struct Year<Item>: Identifiable {
        let year: String
        let ago: String
        let items: [Dated<Item>]
        /// Left out by a limit.
        let hidden: Int

        var id: String { year }
    }

    /// Newest year first. `perYear` keeps the first few of each, counting the rest.
    static func group<Item>(_ days: [(date: String, entries: [Item])], thisYear: String, perYear: Int? = nil) -> [Year<Item>] {
        var byYear: [String: [Dated<Item>]] = [:]
        for day in days.sorted(by: { $0.date > $1.date }) {
            byYear[String(day.date.prefix(4)), default: []] += day.entries.map { Dated(date: day.date, item: $0) }
        }
        return byYear.filter { !$0.value.isEmpty }.keys.sorted(by: >).map { year in
            let all = byYear[year] ?? []
            let shown = perYear.map { Array(all.prefix($0)) } ?? all
            return Year(year: year, ago: ago(year, from: thisYear), items: shown, hidden: all.count - shown.count)
        }
    }

    private static func ago(_ year: String, from thisYear: String) -> String {
        let years = (Int(thisYear) ?? 0) - (Int(year) ?? 0)
        return years == 1 ? "A year ago" : "\(years) years ago"
    }
}
