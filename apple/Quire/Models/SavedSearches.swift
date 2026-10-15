//
//  SavedSearches.swift
//  Quire
//
//  Pinned search queries — smart folders built on the SearchQuery grammar.
//  Stored as `<base>/.quire/searches.json` so they sync across devices with the
//  journal and stay hand-editable; jnl ignores the `.quire/` folder entirely.
//

import Foundation

struct SavedSearch: Codable, Identifiable, Hashable {
    var name: String
    var query: String
    var id: String { name }
}

extension JournalStore {
    func savedSearches() -> [SavedSearch] {
        guard let core else { return [] }
        return (try? core.call("searches")) ?? []
    }
    func addSavedSearch(name: String, query: String) {
        var list = savedSearches().filter { $0.name != name }
        list.append(SavedSearch(name: name, query: query))
        writeSavedSearches(list)
    }
    func removeSavedSearch(named name: String) {
        writeSavedSearches(savedSearches().filter { $0.name != name })
    }
    private func writeSavedSearches(_ list: [SavedSearch]) {
        guard let core else { return }
        do {
            let _: Bool = try core.call("save_searches", ["searches": list.map { ["name": $0.name, "query": $0.query] }])
            reload()
        } catch { lastWriteError = journalErrorMessage(error) }
    }
}
