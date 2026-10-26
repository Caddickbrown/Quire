//
//  SavedSearches.swift
//  Nook
//
//  Pinned search queries — smart folders built on the SearchQuery grammar.
//  Stored as `<base>/.nook/searches.json` so they sync across devices with the
//  journal and stay hand-editable; jnl ignores the `.nook/` folder entirely.
//

import Foundation

struct SavedSearch: Codable, Identifiable, Hashable {
    var name: String
    var query: String
    var id: String { name }
}

extension JournalStore {
    private var savedSearchesURL: URL? {
        baseURL?.appendingPathComponent(".nook", isDirectory: true)
            .appendingPathComponent("searches.json")
    }

    /// All pinned searches, in saved order.
    func savedSearches() -> [SavedSearch] {
        guard let url = savedSearchesURL,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return [] }
        return list
    }

    /// Add or replace (by name) a pinned search.
    func addSavedSearch(name: String, query: String) {
        var list = savedSearches().filter { $0.name != name }
        list.append(SavedSearch(name: name, query: query))
        writeSavedSearches(list)
    }

    func removeSavedSearch(named name: String) {
        writeSavedSearches(savedSearches().filter { $0.name != name })
    }

    private func writeSavedSearches(_ list: [SavedSearch]) {
        guard let url = savedSearchesURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if list.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(list) { try? data.write(to: url, options: .atomic) }
        }
        // Sidebar and Search observe `revision`; bump it so the pins refresh.
        reload()
    }
}
