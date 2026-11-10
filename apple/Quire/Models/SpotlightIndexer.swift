//
//  SpotlightIndexer.swift
//  Quire
//
//  Opt-in Core Spotlight indexing (Settings → Privacy), so entries turn up in
//  system search. Tapping a result deep-links back via an NSUserActivity the
//  app resolves to the entry. Off by default — journal text in system search
//  is a choice, not a given.
//
//  The first reindex after launch rebuilds the "quire-entry" domain; later ones
//  send only what changed. Debounced off the store's rebuild signal so typing
//  doesn't thrash the index.
//

import Foundation
#if canImport(CoreSpotlight)
@preconcurrency import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
enum SpotlightIndexer {
    static let enabledKey = "spotlightIndexing"
    nonisolated private static let domain = "quire-entry"
    private static var pending: Task<Void, Never>?

    /// Result identifier: "inbox|<ts>" or "archive|<date>|<ts>".
    static func identifier(for entry: Entry, source: EntrySource) -> String {
        switch source {
        case .inbox:              return "inbox|\(entry.ts)"
        case .archive(let date):  return "archive|\(date)|\(entry.ts)"
        case .journal(let name):  return "journal|\(name)|\(entry.ts)"
        }
    }

    /// One entry as the index needs it — a Sendable value, so the store can
    /// hand its cached corpus straight to the detached index pass instead of
    /// that pass re-reading the whole journal from disk (a third full corpus
    /// read per rebuild, on big journals the difference between snappy and slow).
    struct IndexableEntry: Sendable {
        let id: String
        let title: String
        let body: String
        let keywords: [String]
        let ts: String
    }

    /// What this process last put in the index: each item's id and a digest of
    /// what was indexed for it. Nil until the first pass, which rebuilds the
    /// whole domain (the index may hold anything from an earlier run).
    private static var lastIndexed: [String: Int]?

    private static func digest(_ e: IndexableEntry) -> Int {
        var h = Hasher()
        h.combine(e.title); h.combine(e.body); h.combine(e.keywords); h.combine(e.ts)
        return h.finalize()
    }

    /// Debounced reindex from prebuilt sources. `source` is only evaluated
    /// when indexing is enabled, so the off state costs nothing. When the
    /// setting is off this clears the index instead.
    ///
    /// The first pass after launch replaces the domain; later ones send only
    /// what changed (and remove what went), where every rebuild used to delete
    /// and re-add every entry in the journal.
    static func scheduleReindex(source: () -> [IndexableEntry]) {
        pending?.cancel()
        guard UserDefaults.standard.bool(forKey: enabledKey) else {
            pending = nil
            lastIndexed = nil
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
            return
        }
        let entries = source()
        pending = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            var current: [String: Int] = [:]
            for e in entries { current[e.id] = digest(e) }
            guard let previous = lastIndexed else {
                lastIndexed = current
                await Task.detached(priority: .utility) { reindexNow(entries: entries) }.value
                return
            }
            let changed = entries.filter { previous[$0.id] != current[$0.id] }
            let removed = previous.keys.filter { current[$0] == nil }
            lastIndexed = current
            guard !changed.isEmpty || !removed.isEmpty else { return }
            await Task.detached(priority: .utility) { update(changed: changed, removed: Array(removed)) }.value
        }
    }

    nonisolated private static func searchableItems(for entries: [IndexableEntry]) -> [CSSearchableItem] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return entries.map { e in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = e.title
            attrs.contentDescription = e.body
            attrs.keywords = e.keywords
            attrs.contentCreationDate = f.date(from: e.ts)
            return CSSearchableItem(uniqueIdentifier: e.id,
                                    domainIdentifier: domain,
                                    attributeSet: attrs)
        }
    }

    /// Rebuild the whole domain off-main from the prepared entries.
    nonisolated private static func reindexNow(entries: [IndexableEntry]) {
        let items = searchableItems(for: entries)
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items, completionHandler: nil)
        }
    }

    /// Index what changed (an item indexed again under its id replaces the
    /// old one) and drop what is no longer in the journal.
    nonisolated private static func update(changed: [IndexableEntry], removed: [String]) {
        let index = CSSearchableIndex.default()
        if !removed.isEmpty { index.deleteSearchableItems(withIdentifiers: removed, completionHandler: nil) }
        if !changed.isEmpty { index.indexSearchableItems(searchableItems(for: changed), completionHandler: nil) }
    }

    /// Resolve a tapped Spotlight result back to (entry, source), or nil if the
    /// entry has moved or been deleted since indexing.
    static func resolve(identifier: String, store: JournalStore) -> (Entry, EntrySource)? {
        let parts = identifier.split(separator: "|").map(String.init)
        /// "ts" or "ts#n" → the nth entry with that timestamp.
        func pick(_ token: String, in entries: [Entry]) -> Entry? {
            let pieces = token.split(separator: "#", maxSplits: 1).map(String.init)
            let ts = pieces[0]
            let n = pieces.count == 2 ? (Int(pieces[1]) ?? 0) : 0
            let matches = entries.filter { $0.ts == ts }
            return n < matches.count ? matches[n] : matches.first
        }
        switch parts.first {
        case "inbox" where parts.count == 2:
            if let e = pick(parts[1], in: store.inboxDrafts) { return (e, .inbox) }
        case "archive" where parts.count == 3:
            if let e = pick(parts[2], in: store.entries(for: parts[1])) {
                return (e, .archive(date: parts[1]))
            }
        case "journal" where parts.count == 3:
            if let e = pick(parts[2], in: store.entries(inJournal: parts[1])) {
                return (e, .journal(name: parts[1]))
            }
        default: break
        }
        return nil
    }
}
#endif
