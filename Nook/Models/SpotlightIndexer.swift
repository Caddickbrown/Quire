//
//  SpotlightIndexer.swift
//  Nook
//
//  Opt-in Core Spotlight indexing (Settings → Privacy), so entries turn up in
//  system search. Tapping a result deep-links back via an NSUserActivity the
//  app resolves to the entry. Off by default — journal text in system search
//  is a choice, not a given.
//
//  Reindexes are full rebuilds of the "nook-entry" domain, debounced off the
//  store's rebuild signal so typing doesn't thrash the index.
//

import Foundation
#if canImport(CoreSpotlight)
@preconcurrency import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
enum SpotlightIndexer {
    static let enabledKey = "spotlightIndexing"
    nonisolated private static let domain = "nook-entry"
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

    /// Debounced full reindex from prebuilt sources. `source` is only
    /// evaluated when indexing is enabled, so the off state costs nothing.
    /// When the setting is off this clears the index instead.
    static func scheduleReindex(source: () -> [IndexableEntry]) {
        pending?.cancel()
        guard UserDefaults.standard.bool(forKey: enabledKey) else {
            pending = nil
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
            return
        }
        let entries = source()
        pending = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { reindexNow(entries: entries) }.value
        }
    }

    /// Rebuild the whole domain off-main from the prepared entries.
    nonisolated private static func reindexNow(entries: [IndexableEntry]) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let items = entries.map { e in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = e.title
            attrs.contentDescription = e.body
            attrs.keywords = e.keywords
            attrs.contentCreationDate = f.date(from: e.ts)
            return CSSearchableItem(uniqueIdentifier: e.id,
                                    domainIdentifier: domain,
                                    attributeSet: attrs)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items, completionHandler: nil)
        }
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
