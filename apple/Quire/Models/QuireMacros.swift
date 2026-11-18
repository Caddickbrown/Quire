import Foundation

/// The Macros (Settings → Macros, and ⌘K's rows for them), done. Kept out of
/// the iOS-only menu so the tests can run them against a real store.
@MainActor enum QuireMacros {
    /// Settings → Macros, run from the menu. What happened, in words.
    static func run(_ macro: QuireMacro, store: JournalStore) async -> String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? "1 \(one)" : "\(count) \(many)" }
        switch macro {
        case .cleanUp:
            let r = store.cleanup()
            return "Cleaned up: moved \(r.moved), formatted \(r.formatted), reordered \(r.reordered), removed \(r.deduped) duplicate(s), extracted \(r.extracted) to split journals."
        case .sortInbox:
            store.sortInbox()
            return "The Inbox is in date order."
        case .fileAll:
            return "Filed \(n(await store.fileAllDraftsAsync(), "draft", "drafts"))."
        case .transfer:
            return "Filed \(n(await store.fileTransferAsync(), "entry", "entries")) from transfer.md."
        case .conflicts:
            return "Merged \(n(await store.mergeConflictCopiesAsync(), "entry", "entries")) from conflict copies."
        case .mergeExSplit:
            let r = await store.mergeExSplitJournalsAsync()
            return "Merged \(n(r.entries, "entry", "entries")) from \(n(r.journals, "journal", "journals"))."
        case .compressMedia:
            let r = await store.compressExistingMedia()
            let total = r.images + r.videos + r.audios
            var said = total == 0 ? "No new media to compress."
                : "Compressed \(r.images) photo(s), \(r.videos) video(s), \(r.audios) audio — saved \(ByteCountFormatter.string(fromByteCount: Int64(r.bytesSaved), countStyle: .file))."
            if r.converted > 0 { said = "Converted \(r.converted) HEIC photo(s) to JPEG. " + said }
            if r.failed > 0 { said += " \(r.failed) couldn't be compressed just now, and will be tried again." }
            return said
        case .transcribeAll:
            let r = await store.transcribeAllMemos()
            return r.done == 0 && r.failed == 0 ? "No untranscribed voice notes."
                : "Transcribed \(n(r.done, "voice note", "voice notes"))\(r.failed > 0 ? "; \(r.failed) failed" : "")."
        case .clearOrphans:
            let count = await store.orphanAssetsAsync().count
            guard count > 0 else { return "No orphan media: every file is in use." }
            let cleared = await store.deleteOrphanAssetsAsync()
            return "Cleared \(n(cleared, "unused file", "unused files")). Copies are kept in .quire/media-cleanup/ for 30 days."
        }
    }
}
