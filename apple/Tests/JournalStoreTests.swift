//
//  JournalStoreTests.swift
//  QuireTests
//
//  File-level tests for JournalStore's read-modify-write paths, against a real
//  temporary journal folder — the Swift counterpart to the `store::tests`
//  module in linux/src-tauri/src/store.rs, and deliberately the same cases
//  where the two ports share behaviour.
//
//  These run hostless, like the rest of the bundle: `init(testingBase:)` hands
//  the store a base directory outright, so nothing here can resolve to iCloud
//  or to the journal of whoever is running the tests.
//

import XCTest

@MainActor
final class JournalStoreTests: XCTestCase {

    /// A throwaway journal folder. These exercise the file ops, so they need a
    /// real base directory — never the user's.
    private func makeStore() -> (store: JournalStore, base: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("quire-test-\(UUID().uuidString)", isDirectory: true)
        return (JournalStore(testingBase: base), base)
    }

    private func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func inbox(_ base: URL) -> URL { base.appendingPathComponent("inbox.md") }
    private func day(_ base: URL, _ date: String) -> URL {
        let p = date.split(separator: "-")
        return base.appendingPathComponent("journal/\(p[0])/\(p[1])/\(p[2]).md")
    }
    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: D1 — an unreadable file is not an empty one

    func testReadForRewriteSeparatesMissingFromUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quire-rfr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let absent = dir.appendingPathComponent("absent.md")
        XCTAssertEqual(try JournalStore.readForRewrite(absent), "", "absent reads as empty")

        // One non-UTF-8 byte, as a hand edit or a jnl write can leave behind.
        let bad = dir.appendingPathComponent("bad.md")
        try Data([0x63, 0x61, 0xE9]).write(to: bad)
        XCTAssertThrowsError(try JournalStore.readForRewrite(bad),
                             "undecodable must throw, not read as \"\"")
    }

    /// The defect that reached main: `returnToInbox` built its append on a read
    /// that couldn't tell an unreadable inbox from an empty one, so the atomic
    /// replace that followed dropped every other draft.
    func testReturnToInboxRefusesToRewriteAnUnreadableInbox() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        write("[2026-05-10 08:00:00] filed\nbody\n", to: day(base, "2026-05-10"))
        try Data("[2026-05-01 07:00:00] draft\nca\u{FFFD}".utf8.dropLast() + [0xE9])
            .write(to: inbox(base))
        let before = try Data(contentsOf: inbox(base))
        store.reload()

        let entry = Entry(date: "2026-05-10", ts: "2026-05-10 08:00:00", suffix: "filed",
                          body: "body", raw: "[2026-05-10 08:00:00] filed\nbody")
        XCTAssertFalse(store.returnToInbox(entry, source: .archive(date: "2026-05-10")))
        XCTAssertEqual(try Data(contentsOf: inbox(base)), before,
                       "the unreadable inbox is left exactly as it was")
        XCTAssertTrue(FileManager.default.fileExists(atPath: day(base, "2026-05-10").path),
                      "and the entry stays where it was")
        XCTAssertNotNil(store.lastWriteError, "the refusal is reported, not silent")
    }

    func testReturnToInboxRoundTripsAFiledEntry() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        write("[2026-05-10 08:00:00] filed\nbody\n", to: day(base, "2026-05-10"))
        write("[2026-05-01 07:00:00] keep\nexisting\n", to: inbox(base))
        store.reload()

        let entry = store.entries(for: "2026-05-10").first!
        XCTAssertTrue(store.returnToInbox(entry, source: .archive(date: "2026-05-10")))

        XCTAssertEqual(store.inboxDrafts.map(\.suffix), ["keep", "filed"],
                       "appended after the drafts already there")
        XCTAssertTrue(store.entries(for: "2026-05-10").isEmpty, "and gone from the day")
        XCTAssertNil(store.lastWriteError)
    }

    // MARK: The inbox read-modify-write cache

    /// Autosave reuses the parse while the file's bytes still match what Quire
    /// last wrote. An edit from jnl or another device changes those bytes, and
    /// must be picked up rather than silently overwritten from the cache.
    func testInboxRewriteNoticesAnExternalEdit() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        write("[2026-05-01 07:00:00] first\none\n", to: inbox(base))
        store.reload()
        XCTAssertEqual(store.inboxDrafts.count, 1)

        // jnl appends a second draft behind the app's back, then the app saves.
        write("[2026-05-01 07:00:00] first\none\n\n[2026-05-02 09:00:00] second\ntwo\n",
              to: inbox(base))
        store.upsertDraft(previous: nil, timestamp: "2026-05-03 10:00:00",
                          title: "third", body: "three")

        XCTAssertEqual(store.inboxDrafts.map(\.suffix), ["first", "second", "third"],
                       "the outside edit survives the rewrite")
        XCTAssertTrue(read(base.appendingPathComponent("inbox/2026/05/02.md")).contains("second"), "and is still on disk in the migrated day file")
    }

    // MARK: E2 — same-second twins

    /// Two entries can share a timestamp, so the store resolves by raw text
    /// first. Editing one twin must not rewrite or delete the other.
    func testSameSecondTwinsAreEditedIndependently() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        write("[2026-05-01 07:00:00] one\nfirst\n\n[2026-05-01 07:00:00] two\nsecond\n",
              to: inbox(base))
        store.reload()
        XCTAssertEqual(store.inboxDrafts.count, 2)

        let second = store.inboxDrafts[1]
        XCTAssertTrue(store.updateDraft(second, newText: "[2026-05-01 07:00:00] two\nedited"))

        XCTAssertEqual(store.inboxDrafts.map(\.suffix), ["one", "two"])
        XCTAssertEqual(store.inboxDrafts.map(\.body), ["first", "edited"],
                       "only the twin that was edited changed")
    }

    func testRemovingOneTwinLeavesTheOther() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        write("[2026-05-01 07:00:00] one\nfirst\n\n[2026-05-01 07:00:00] two\nsecond\n",
              to: inbox(base))
        store.reload()

        store.removeDraft(timestamp: "2026-05-01 07:00:00")
        XCTAssertEqual(store.inboxDrafts.count, 1, "removeDraft takes one draft, not both")
    }

    // MARK: Filing

    func testFilingMovesADraftIntoItsDayFile() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        write("[2026-05-10 08:00:00] a draft\nbody\n", to: inbox(base))
        store.reload()

        let draft = store.inboxDrafts[0]
        XCTAssertEqual(store.fileDraft(draft), "2026-05-10")
        XCTAssertTrue(store.inboxDrafts.isEmpty, "gone from the inbox")
        XCTAssertEqual(store.entries(for: "2026-05-10").map(\.suffix), ["a draft"])
    }
    func testDayLayoutRetimingAndRepeatedAutosaveUseRustReferences() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let ts = "2026-05-10 08:00:00"
        XCTAssertEqual(store.upsertDraft(previous: nil, timestamp: ts, title: "A", body: "one"), ts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("inbox/2026/05/10.md").path))
        let original = store.inboxDrafts[0]
        XCTAssertTrue(store.updateDraft(original, newText: "[2026-05-11 08:00:00] A\ntwo", reindex: false))
        let updated = store.writtenEntry(fallback: original)
        XCTAssertEqual(updated.file, "inbox/2026/05/11.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("inbox/2026/05/10.md").path))
        XCTAssertTrue(store.updateDraft(updated, newText: "[2026-05-11 08:00:00] A\nthree"))
        XCTAssertEqual(store.inboxDrafts[0].body, "three")
        XCTAssertFalse(store.updateDraft(original, newText: "[2026-05-10 08:00:00] stale\nno"))
        XCTAssertEqual(store.inboxDrafts[0].body, "three")
    }

    func testLegacySplitMigrationIsVisibleAndEditableThroughCore() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        write("[2026-05-10 08:00:00] Work\n@work note\n", to: base.appendingPathComponent("work.md"))
        store.reload()
        let values = try CoreJournal(base: base).load()
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].file, "split/work/2026/05/10.md")
        XCTAssertTrue(store.updateJournalEntry(name: "work", original: values[0].entry,
                                               newText: "[2026-05-11 08:00:00] Work\n@work edited"))
        XCTAssertEqual(try CoreJournal(base: base).load()[0].file, "split/work/2026/05/11.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("work.md").path))
    }

    func testAppleVaultRefusesSymlinksOutsideJournal() throws {
        let (store, base) = makeStore()
        _ = store
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("quire-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try AppleVault(base: base).write(rel: "escape/no.md", bytes: Data("no".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("no.md").path))
    }

}
