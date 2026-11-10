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
import ImageIO

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

    // MARK: Editor identity, retiming and conflict recovery

    func testEditorCanKeepSavingAfterCrossDayRetime() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        write("[2026-05-10 08:00:00] original\nbody\n", to: day(base, "2026-05-10"))
        store.reload()
        let original = try XCTUnwrap(CoreJournal(base: base).load().first?.entry)
        let moved = try XCTUnwrap(store.saveEditorEntry(original, source: .archive(date: original.date),
            text: "[2026-05-11 09:00:00] moved\nbody"))
        XCTAssertEqual(moved.source, .archive(date: "2026-05-11"))
        XCTAssertEqual(moved.entry.file, "journal/2026/05/11.md")
        let edited = try XCTUnwrap(store.saveEditorEntry(moved.entry, source: moved.source,
            text: "[2026-05-11 09:00:00] moved\ncontinued writing"))
        XCTAssertTrue(read(day(base, "2026-05-11")).contains("continued writing"))
        XCTAssertEqual(edited.entry.raw, "[2026-05-11 09:00:00] moved\ncontinued writing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: day(base, "2026-05-10").path))
    }

    func testEditorDraftRetimeKeepsReferenceWithSameSecondTwin() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try XCTUnwrap(store.createEditorDraft(timestamp: "2026-05-10 08:00:00", title: "first", body: "keep"))
        let second = try XCTUnwrap(store.createEditorDraft(timestamp: first.ts, title: "second", body: "edit"))
        XCTAssertNotEqual(first.ts, second.ts)
        let moved = try XCTUnwrap(store.saveEditorEntry(second, source: .inbox,
            text: "[2026-05-10 08:00:00] second\nedit"))
        let next = try XCTUnwrap(store.saveEditorEntry(moved.entry, source: moved.source,
            text: "[2026-05-10 08:00:00] second\nmore"))
        XCTAssertTrue(next.entry.raw.contains("more"))
        XCTAssertEqual(store.inboxDrafts.count, 2)
        XCTAssertTrue(store.inboxDrafts.contains { $0.suffix == "first" && $0.body == "keep" })
    }

    func testConflictRecoveryCreatesDistinctDraftAndPreservesExternalEdit() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let original = try XCTUnwrap(store.createEditorDraft(timestamp: "2026-05-10 08:00:00", title: "original", body: "body"))
        let file = try XCTUnwrap(original.file)
        let external = "[2026-05-10 08:00:00] original\nchanged on another device\n"
        write(external, to: base.appendingPathComponent(file))
        XCTAssertNil(store.saveEditorEntry(original, source: .inbox,
            text: "[2026-05-10 08:00:00] original\nmy unsaved text"))
        XCTAssertNotNil(store.lastWriteError)
        let copy = try XCTUnwrap(store.createEditorDraft(timestamp: original.ts, title: "original", body: "my unsaved text"))
        XCTAssertNotEqual(copy.ts, original.ts)
        XCTAssertTrue(store.inboxDrafts.contains { $0.body == "changed on another device" })
        XCTAssertTrue(store.inboxDrafts.contains { $0.body == "my unsaved text" })
    }

    func testSplitEditorCanKeepSavingAfterRetime() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        write("[2026-05-10 08:00:00] split\nbody\n", to: base.appendingPathComponent("split/work/2026/05/10.md"))
        store.reload()
        let original = try XCTUnwrap(CoreJournal(base: base).load().first?.entry)
        let moved = try XCTUnwrap(store.saveEditorEntry(original, source: .journal(name: "work"),
            text: "[2026-05-11 08:00:00] split\nbody"))
        XCTAssertEqual(moved.source, .journal(name: "work"))
        XCTAssertEqual(moved.entry.file, "split/work/2026/05/11.md")
        XCTAssertNotNil(store.saveEditorEntry(moved.entry, source: moved.source,
            text: "[2026-05-11 08:00:00] split\ncontinued"))
        XCTAssertTrue(read(base.appendingPathComponent("split/work/2026/05/11.md")).contains("continued"))
    }

    func testEditorFailureDoesNotReturnPreviousSuccessfulWrite() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let original = try XCTUnwrap(store.createEditorDraft(timestamp: "2026-05-10 08:00:00", title: "first", body: "body"))
        write("[2026-05-10 08:00:00] replaced\nexternal\n", to: base.appendingPathComponent(try XCTUnwrap(original.file)))
        XCTAssertNil(store.saveEditorEntry(original, source: .inbox, text: "[2026-05-10 08:00:00] first\nlocal"))
        XCTAssertFalse(store.deleteEditorDraft(original))
        XCTAssertTrue(read(base.appendingPathComponent(try XCTUnwrap(original.file))).contains("external"))
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

    func testAppleVaultReplaceIfUnchangedSwapsOnlyWhatItExpected() throws {
        let (store, base) = makeStore()
        _ = store
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = AppleVault(base: base)
        let rel = "journal/2026/05/10.md"
        let one = Data("one".utf8), two = Data("two".utf8)
        XCTAssertTrue(try vault.replaceIfUnchanged(rel: rel, expected: nil, bytes: one), "a new file")
        XCTAssertFalse(try vault.replaceIfUnchanged(rel: rel, expected: nil, bytes: two), "another writer made it first")
        XCTAssertFalse(try vault.replaceIfUnchanged(rel: rel, expected: Data("stale".utf8), bytes: two))
        XCTAssertEqual(try vault.read(rel: rel), one, "a refused swap touches nothing")
        XCTAssertTrue(try vault.replaceIfUnchanged(rel: rel, expected: one, bytes: two))
        XCTAssertEqual(try vault.read(rel: rel), two)
        XCTAssertFalse(try vault.replaceIfUnchanged(rel: rel, expected: one, bytes: nil), "a delete is guarded too")
        XCTAssertTrue(vault.isFile(rel: rel))
        XCTAssertTrue(try vault.replaceIfUnchanged(rel: rel, expected: two, bytes: nil))
        XCTAssertFalse(vault.isFile(rel: rel))
    }

    /// iOS reports a journal folder as /private/var/… or /var/…, and the two
    /// resolve differently while the folder doesn't exist. A missing folder must
    /// say so, not claim the path left the journal, and must not be created by
    /// a write; once the folder is there the same vault must work.
    func testAppleVaultBaseUnderPrivateThatDoesNotExistYet() throws {
        let fm = FileManager.default
        var tmp = fm.temporaryDirectory.standardizedFileURL.path
        if !tmp.hasPrefix("/private/") { tmp = "/private" + tmp }
        let base = URL(fileURLWithPath: tmp).appendingPathComponent("quire-private-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        XCTAssertTrue(base.path.hasPrefix("/private/"))
        XCTAssertFalse(fm.fileExists(atPath: base.path))
        let vault = AppleVault(base: base)
        let rel = "journal/2026/05/10.md"

        func message(_ error: Error) -> String {
            guard case let BridgeError.Failure(message) = error else { return "not a bridge failure: \(error)" }
            return message
        }
        func assertUnreachable(_ body: () throws -> Void) {
            XCTAssertThrowsError(try body()) { error in
                let text = message(error)
                XCTAssertTrue(text.contains("can't be reached"), text)
                XCTAssertFalse(text.contains("Path leaves"), text)
            }
        }
        assertUnreachable { _ = try vault.read(rel: rel) }
        assertUnreachable { try vault.write(rel: rel, bytes: Data("no".utf8)) }
        assertUnreachable { _ = try vault.replaceIfUnchanged(rel: rel, expected: nil, bytes: Data("no".utf8)) }
        XCTAssertFalse(fm.fileExists(atPath: base.path), "a write must not make a missing folder")

        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try vault.write(rel: rel, bytes: Data("yes".utf8))
        XCTAssertEqual(try vault.read(rel: rel), Data("yes".utf8))

        // The guard still holds under the same base.
        let outside = fm.temporaryDirectory.appendingPathComponent("quire-outside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try fm.createSymbolicLink(at: base.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try vault.read(rel: "escape/secret.md")) { error in
            XCTAssertTrue(message(error).contains("Path leaves"), message(error))
        }
    }

    /// Re-resolving the root must not let a real folder be swapped for a link.
    func testAppleVaultRefusesABaseSwappedForASymlink() throws {
        let fm = FileManager.default
        let (store, base) = makeStore()
        _ = store
        defer { try? fm.removeItem(at: base) }
        let outside = fm.temporaryDirectory.appendingPathComponent("quire-outside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.md"))
        let vault = AppleVault(base: base)
        XCTAssertNil(try vault.read(rel: "secret.md"))
        try fm.removeItem(at: base)
        try fm.createSymbolicLink(at: base, withDestinationURL: outside)
        XCTAssertThrowsError(try vault.read(rel: "secret.md"))
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

    /// Reads must be refused too, including when the folder holding the link has
    /// already been checked and remembered as safe.
    func testAppleVaultRefusesToReadThroughSymlinks() throws {
        let (store, base) = makeStore()
        _ = store
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let outside = fm.temporaryDirectory.appendingPathComponent("quire-outside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.md"))

        // A symlinked folder.
        try fm.createSymbolicLink(at: base.appendingPathComponent("escape"), withDestinationURL: outside)
        let vault = AppleVault(base: base)
        XCTAssertThrowsError(try vault.read(rel: "escape/secret.md"))
        XCTAssertThrowsError(try vault.list(rel: "escape"))

        // A symlinked file in a real folder that has already been read from.
        let journal = base.appendingPathComponent("journal/2026/05", isDirectory: true)
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data("real".utf8).write(to: journal.appendingPathComponent("01.md"))
        XCTAssertEqual(try vault.read(rel: "journal/2026/05/01.md"), Data("real".utf8))
        try fm.createSymbolicLink(at: journal.appendingPathComponent("02.md"),
                                  withDestinationURL: outside.appendingPathComponent("secret.md"))
        XCTAssertThrowsError(try vault.read(rel: "journal/2026/05/02.md"))

        // And a missing file is still just missing.
        XCTAssertNil(try vault.read(rel: "journal/2026/05/03.md"))
    }


    // MARK: Restore

    private struct Boom: Error {}

    private func restoreFixture() -> (base: URL, backup: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quire-restore-\(UUID().uuidString)", isDirectory: true)
        let base = root.appendingPathComponent("live"), backup = root.appendingPathComponent("backup")
        for (dir, text) in [(base, "live"), (backup, "backup")] {
            write(text, to: dir.appendingPathComponent("journal/2026/11/06.md"))
            write(text, to: dir.appendingPathComponent("transfer.md"))
        }
        write("live", to: base.appendingPathComponent("only-live.md"))
        write("", to: base.appendingPathComponent(".stfolder/marker"))
        return (base, backup)
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func leftovers(in base: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.hasPrefix(".quire-restore") }
    }

    func testRestoreSwapsTheBackupInAndLeavesHiddenItems() {
        let (base, backup) = restoreFixture()
        let result = JournalStore.replaceTree(base: base, from: backup)
        XCTAssertTrue(result.0, result.1)
        XCTAssertEqual(text(base.appendingPathComponent("journal/2026/11/06.md")), "backup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("only-live.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent(".stfolder/marker").path))
        XCTAssertEqual(leftovers(in: base), [])
    }

    func testRestoreFailingAtAnyStepLeavesTheJournalAsItWas() {
        var moves = 0
        do {
            let (base, backup) = restoreFixture()
            XCTAssertTrue(JournalStore.replaceTree(base: base, from: backup, beforeMove: { _ in moves += 1 }).0)
        }
        XCTAssertGreaterThan(moves, 3)
        for failAt in 0..<moves {
            let (base, backup) = restoreFixture()
            var n = 0
            let result = JournalStore.replaceTree(base: base, from: backup, beforeMove: { _ in
                n += 1
                if n > failAt { throw Boom() }
            })
            XCTAssertFalse(result.0)
            XCTAssertEqual(text(base.appendingPathComponent("journal/2026/11/06.md")), "live")
            XCTAssertEqual(text(base.appendingPathComponent("only-live.md")), "live")
            XCTAssertEqual(leftovers(in: base), [])
        }
    }

    func testRestoreRefusesAFolderThatIsNotABackup() {
        let (base, backup) = restoreFixture()
        try? FileManager.default.removeItem(at: backup.appendingPathComponent("journal"))
        XCTAssertFalse(JournalStore.replaceTree(base: base, from: backup).0)
        XCTAssertEqual(text(base.appendingPathComponent("journal/2026/11/06.md")), "live")
    }

    func testRestoreWithAnICloudPlaceholderChangesNothing() {
        let (base, backup) = restoreFixture()
        write("", to: backup.appendingPathComponent("journal/2026/11/.07.md.icloud"))
        let result = JournalStore.replaceTree(base: base, from: backup)
        XCTAssertFalse(result.0)
        XCTAssertEqual(text(base.appendingPathComponent("journal/2026/11/06.md")), "live")
        XCTAssertEqual(leftovers(in: base), [])
    }

    // MARK: The caches, between a write and its rebuild

    /// The index is built off the main actor; these wait for it to land.
    private func waitForIndex(_ store: JournalStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if store.indexed { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the index never landed", file: file, line: line)
    }

    /// A4: a filed entry saved from the editor, then starred at once from the
    /// list. The list must already hold the write's own entry: with the text
    /// from before the save, the star was refused as "changed on disk".
    func testFiledEntrySaveThenImmediateStarUsesThePatchedEntry() async throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        write("[2026-05-10 08:00:00] one\nbody\n\n[2026-05-10 09:00:00] two\nmore\n", to: day(base, "2026-05-10"))
        store.reload()
        try await waitForIndex(store)

        let original = try XCTUnwrap(store.entries(for: "2026-05-10").first)
        let saved = try XCTUnwrap(store.saveEditorEntry(original, source: .archive(date: "2026-05-10"),
                                                        text: "[2026-05-10 08:00:00] one\nedited"))
        // No rebuild has run (the editor's is held back): the list has it anyway.
        let listed = try XCTUnwrap(store.archiveEntries.first { $0.date == "2026-05-10" }?.entries.first)
        XCTAssertEqual(listed.raw, saved.entry.raw)
        XCTAssertEqual(listed.fileIndex, saved.entry.fileIndex)
        XCTAssertEqual(store.entries(for: "2026-05-10").map(\.body), ["edited", "more"])

        store.toggleStar(listed, source: .archive(date: "2026-05-10"))
        XCTAssertNil(store.lastWriteError)
        XCTAssertTrue(read(day(base, "2026-05-10")).contains("[2026-05-10 08:00:00] one *\nedited"))
        // …and the starred entry is in the list too, with its neighbour as it was.
        let after = try XCTUnwrap(store.archiveEntries.first { $0.date == "2026-05-10" }?.entries)
        XCTAssertEqual(after.map(\.isStarred), [true, false])
        XCTAssertEqual(after.map(\.fileIndex), [0, 1])
    }

    func testEditorRetimeMovesTheEntryBetweenDaysInTheLists() async throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        write("[2026-05-10 08:00:00] one\nbody\n\n[2026-05-10 09:00:00] two\nmore\n", to: day(base, "2026-05-10"))
        store.reload()
        try await waitForIndex(store)

        let original = try XCTUnwrap(store.entries(for: "2026-05-10").first)
        let moved = try XCTUnwrap(store.saveEditorEntry(original, source: .archive(date: "2026-05-10"),
                                                        text: "[2026-05-12 08:00:00] one\nbody"))
        XCTAssertEqual(moved.source, .archive(date: "2026-05-12"))
        XCTAssertEqual(store.archiveEntries.map(\.date), ["2026-05-12", "2026-05-10"], "newest day first")
        XCTAssertEqual(store.entries(for: "2026-05-12").map(\.raw), [moved.entry.raw])
        let left = store.entries(for: "2026-05-10")
        XCTAssertEqual(left.map(\.suffix), ["two"])
        XCTAssertEqual(left.first?.fileIndex, 0, "renumbered, as the file now has it")
        XCTAssertEqual(store.archiveDays.map(\.date), ["2026-05-12", "2026-05-10"])
        // The neighbour can be edited straight from the list.
        XCTAssertNotNil(store.saveEditorEntry(left[0], source: .archive(date: "2026-05-10"),
                                              text: "[2026-05-10 09:00:00] two\nstill editable"))
    }

    /// An editor autosave of a draft changes the draft in the list, without the
    /// inbox being read again.
    func testEditorAutosavePatchesTheDraftInPlace() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try XCTUnwrap(store.createEditorDraft(timestamp: "2026-05-10 08:00:00", title: "a", body: "one"))
        _ = try XCTUnwrap(store.createEditorDraft(timestamp: "2026-05-10 09:00:00", title: "b", body: "two"))
        let saved = try XCTUnwrap(store.saveEditorEntry(a, source: .inbox, text: "[2026-05-10 08:00:00] a\nmore words"))
        XCTAssertEqual(store.inboxDrafts.map(\.body), ["more words", "two"])
        XCTAssertEqual(store.inboxDrafts[0].raw, saved.entry.raw)
        XCTAssertEqual(store.inboxDrafts[0].fileIndex, saved.entry.fileIndex)
    }

    // MARK: A day change, and Today as it was last drawn

    func testADayChangeAsksForARebuild() {
        XCTAssertFalse(JournalStore.dayChanged(indexDay: "", today: "2026-11-09"), "nothing built yet")
        XCTAssertFalse(JournalStore.dayChanged(indexDay: "2026-11-09", today: "2026-11-09"))
        XCTAssertTrue(JournalStore.dayChanged(indexDay: "2026-11-08", today: "2026-11-09"))
    }

    func testTodaySnapshotDrawsTodayAndIsEmptiedOnAnotherDay() async throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let today = JournalStore.nowDate()
        let lastYear = String((Int(today.prefix(4)) ?? 2026) - 1) + today.dropFirst(4)
        write("[\(today) 08:00:00] Morning\n![](assets/a.jpg)\nfirst line\nsecond line\nthird line @walk\n", to: day(base, today))
        if !today.hasSuffix("02-29") {
            write("[\(lastYear) 07:00:00]\nA year ago @work\n", to: day(base, lastYear))
        }
        store.reload()
        try await waitForIndex(store)

        let snap = try XCTUnwrap(store.makeTodaySnapshot())
        XCTAssertEqual(snap.day, today)
        XCTAssertEqual(snap.entries.count, 1)
        let real = try XCTUnwrap(store.entries(for: today).first)
        let row = snap.entries[0].entry
        XCTAssertEqual(row.id, real.id, "a tap is resolved by id once the journal is read")
        XCTAssertEqual(row.preview, real.preview)
        XCTAssertFalse(snap.entries[0].lines.contains("third line"), "only what the row shows is kept")
        XCTAssertEqual(snap.wordsToday, store.stats().wordsToday)
        if !today.hasSuffix("02-29") {
            XCTAssertEqual(snap.onThisDay.map(\.title), ["A year ago @work"])
            XCTAssertEqual(snap.onThisDay.first?.tags, ["@work"])
        }

        // It survives the trip to disk and back.
        let file = base.appendingPathComponent("today-test.json")
        JournalStore.writeTodaySnapshot(snap, to: file)
        XCTAssertEqual(JournalStore.loadTodaySnapshot(from: file), snap)

        // The same day: as it was. The next day: today's figures are gone, the
        // streak (it ran through yesterday) is not. Later still: nothing.
        XCTAssertEqual(snap.rolled(to: today), snap)
        let tomorrow = try XCTUnwrap(JournalStore.TodaySnapshot.dayAfter(today))
        let next = snap.rolled(to: tomorrow)
        XCTAssertEqual(next.day, tomorrow)
        XCTAssertTrue(next.entries.isEmpty)
        XCTAssertTrue(next.onThisDay.isEmpty)
        XCTAssertEqual(next.wordsToday, 0)
        XCTAssertEqual(next.streak, snap.streak)
        let later = snap.rolled(to: try XCTUnwrap(JournalStore.TodaySnapshot.dayAfter(tomorrow)))
        XCTAssertEqual(later.streak, 0)
        XCTAssertTrue(later.entries.isEmpty)
    }

    // MARK: Whose change it was

    func testOnlyAChangeToAFileWeDidNotWriteCounts() {
        let before = ["journal/2026/05/10.md": "10:1", "inbox/2026/05/11.md": "5:1"]
        XCTAssertEqual(JournalStore.changedPaths(before, before), [])
        XCTAssertEqual(JournalStore.changedPaths(before, ["journal/2026/05/10.md": "10:1", "inbox/2026/05/11.md": "9:2"]),
                       ["inbox/2026/05/11.md"])
        XCTAssertEqual(JournalStore.changedPaths(before, ["journal/2026/05/10.md": "10:1"]), ["inbox/2026/05/11.md"], "a file gone")
        XCTAssertEqual(JournalStore.changedPaths(before, before.merging(["split/work/2026/05/10.md": "1:1"]) { a, _ in a }),
                       ["split/work/2026/05/10.md"], "a file new")
    }

    func testContentSignaturesAreKeyedByPathInTheJournal() {
        let (store, base) = makeStore()
        _ = store
        defer { try? FileManager.default.removeItem(at: base) }
        write("[2026-05-10 08:00:00] a\n", to: day(base, "2026-05-10"))
        write("[2026-05-10 08:00:00] b\n", to: base.appendingPathComponent("inbox/2026/05/10.md"))
        let found = JournalStore.contentSignatures(base: base)
        XCTAssertEqual(Set(found.keys), ["journal/2026/05/10.md", "inbox/2026/05/10.md"])
    }

    // MARK: Backups

    private func backupFixture() -> (base: URL, backups: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quire-backup-\(UUID().uuidString)", isDirectory: true)
        let base = root.appendingPathComponent("live"), backups = root.appendingPathComponent("backups")
        for n in 1...6 { write("[2026-11-0\(n) 08:00:00] day \(n)\nlive\n", to: base.appendingPathComponent("journal/2026/11/0\(n).md")) }
        write("[2026-11-08 08:00:00] draft\n", to: base.appendingPathComponent("inbox/2026/11/08.md"))
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        return (base, backups)
    }
    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// B1: the trigger for a backup is a write, so writes keep coming while it
    /// runs. Checked against the live folder afterwards, every such backup failed.
    func testBackupTakenWhileAFileIsAppendedStillVerifies() throws {
        let (base, backups) = backupFixture()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let draft = base.appendingPathComponent("inbox/2026/11/08.md")
        var writes = 0
        let result = JournalStore.copyTree(from: base, into: backups, named: "Quire-Backup-2026-11-09-10-00-00", keep: 10, beforeFile: { _ in
            // An autosave, and a new day file, in the middle of the copy.
            writes += 1
            let handle = try? FileHandle(forWritingTo: draft)
            _ = try? handle?.seekToEnd()
            try? handle?.write(contentsOf: Data("more \(writes)\n".utf8))
            try? handle?.close()
            self.write("[2026-11-09 08:00:0\(writes % 10)] new\n", to: base.appendingPathComponent("journal/2026/11/1\(writes % 10).md"))
        })
        XCTAssertTrue(result.ok, result.message)
        XCTAssertGreaterThan(writes, 3)
        XCTAssertEqual(names(in: backups), ["Quire-Backup-2026-11-09-10-00-00"], "finished, and nothing partial left")
        XCTAssertEqual(text(backups.appendingPathComponent("Quire-Backup-2026-11-09-10-00-00/journal/2026/11/01.md")),
                       "[2026-11-01 08:00:00] day 1\nlive\n")
    }

    /// B2: a copy that was interrupted is not a backup.
    func testAnUnfinishedBackupIsNeitherListedNorCounted() {
        let (base, backups) = backupFixture()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        write("half", to: backups.appendingPathComponent(".Quire-Backup-2026-11-01-00-00-00.partial/journal/2026/11/01.md"))
        XCTAssertTrue(JournalStore.copyTree(from: base, into: backups, named: "Quire-Backup-2026-11-08-10-00-00", keep: 1).ok)
        XCTAssertTrue(JournalStore.copyTree(from: base, into: backups, named: "Quire-Backup-2026-11-09-10-00-00", keep: 1).ok)
        XCTAssertEqual(JournalStore.backupCopies(in: backups).map(\.name), ["Quire-Backup-2026-11-09-10-00-00"])
        XCTAssertTrue(names(in: backups).contains(".Quire-Backup-2026-11-01-00-00-00.partial"),
                      "one that may still be being written is left alone")
        // A journal folder that isn't there fails, and leaves nothing behind.
        let missing = JournalStore.copyTree(from: base.appendingPathComponent("nowhere"), into: backups,
                                            named: "Quire-Backup-2026-11-10-10-00-00", keep: 1)
        XCTAssertFalse(missing.ok)
        XCTAssertFalse(names(in: backups).contains { $0.contains("2026-11-10") })
    }

    /// B3: with "keep 1", the backup after a restore used to delete the safety
    /// copy the restore had just taken.
    func testRestoreSafetyCopySurvivesTheNextBackupsPruning() throws {
        let (base, backups) = backupFixture()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        XCTAssertTrue(JournalStore.copyTree(from: base, into: backups, named: "Quire-Backup-2026-11-08-10-00-00", keep: 1).ok)
        write("[2026-11-01 08:00:00] day 1\nchanged since\n", to: base.appendingPathComponent("journal/2026/11/01.md"))

        let restored = JournalStore.restore(base: base, backupBase: backups, named: "Quire-Backup-2026-11-08-10-00-00")
        XCTAssertTrue(restored.0, restored.1)
        XCTAssertEqual(text(base.appendingPathComponent("journal/2026/11/01.md")), "[2026-11-01 08:00:00] day 1\nlive\n")
        let safety = try XCTUnwrap(names(in: backups).first { $0.hasPrefix("Quire before-restore ") })
        XCTAssertEqual(text(backups.appendingPathComponent(safety).appendingPathComponent("journal/2026/11/01.md")),
                       "[2026-11-01 08:00:00] day 1\nchanged since\n")
        XCTAssertEqual(leftovers(in: base), [])

        XCTAssertTrue(JournalStore.copyTree(from: base, into: backups, named: "Quire-Backup-2026-11-09-10-00-00", keep: 1).ok)
        XCTAssertEqual(names(in: backups), ["Quire before-restore " + safety.dropFirst("Quire before-restore ".count),
                                            "Quire-Backup-2026-11-09-10-00-00"],
                       "retention took the older backup, never the safety copy")
        let listed = JournalStore.backupCopies(in: backups)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.filter(\.isSafetyCopy).map(\.name), [safety], "and it is listed, so it can be restored from")
    }

    /// B4: a journal that has suddenly shrunk doesn't get to push the good
    /// backups out.
    func testAMuchSmallerBackupPrunesNothing() {
        let (base, backups) = backupFixture()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        XCTAssertTrue(JournalStore.copyTree(from: base, into: backups, named: "Quire-Backup-2026-11-08-10-00-00", keep: 1).ok)
        try? FileManager.default.removeItem(at: base.appendingPathComponent("journal"))
        write("[2026-11-09 08:00:00] all that is left\n", to: base.appendingPathComponent("journal/2026/11/09.md"))
        let result = JournalStore.copyTree(from: base, into: backups, named: "Quire-Backup-2026-11-09-10-00-00", keep: 1)
        XCTAssertTrue(result.ok, result.message)
        XCTAssertTrue(result.message.contains("smaller"), result.message)
        XCTAssertEqual(names(in: backups), ["Quire-Backup-2026-11-08-10-00-00", "Quire-Backup-2026-11-09-10-00-00"])
        XCTAssertTrue(JournalStore.shrankDrastically(from: (10, 10_000), to: (4, 9_000)))
        XCTAssertFalse(JournalStore.shrankDrastically(from: (10, 10_000), to: (9, 9_000)))
    }

    func testAFailedBackupWaitsLongerEachTime() {
        XCTAssertEqual(JournalStore.backupBackoff(failures: 0), 0)
        XCTAssertEqual(JournalStore.backupBackoff(failures: 1), 300)
        XCTAssertEqual(JournalStore.backupBackoff(failures: 2), 600)
        XCTAssertEqual(JournalStore.backupBackoff(failures: 40), 6 * 60 * 60)
    }

    /// B5: what an interrupted restore left behind.
    func testInterruptedRestoreLeftoversAreSweptOrReported() {
        let (base, _) = restoreFixture()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        write("copy", to: base.appendingPathComponent(".quire-restore-new-A/journal/2026/11/06.md"))
        write("only copy", to: base.appendingPathComponent(".quire-restore-old-B/journal/2026/11/06.md"))
        XCTAssertNotNil(JournalStore.sweepRestoreLeftovers(base: base))
        XCTAssertEqual(leftovers(in: base).sorted(), [".quire-restore-new-A", ".quire-restore-old-B"],
                       "a staged copy this fresh may be a restore still running elsewhere")
        let message = JournalStore.sweepRestoreLeftovers(base: base, now: Date().addingTimeInterval(2 * 3600))
        XCTAssertEqual(leftovers(in: base), [".quire-restore-old-B"])
        XCTAssertTrue(message?.contains(".quire-restore-old-B") == true)
        XCTAssertEqual(text(base.appendingPathComponent(".quire-restore-old-B/journal/2026/11/06.md")), "only copy")
        try? FileManager.default.removeItem(at: base.appendingPathComponent(".quire-restore-old-B"))
        XCTAssertNil(JournalStore.sweepRestoreLeftovers(base: base))
    }

    // MARK: Media, and where it goes instead of being deleted

    private func recoveryFiles(_ base: URL) -> [String] {
        let root = base.appendingPathComponent(".quire/media-cleanup")
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walk.compactMap { $0 as? String }.filter { rel in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }.sorted()
    }

    /// A3: a file deleted from the Media Library is moved to the recovery
    /// folder the core prunes, and a delete that didn't happen says so.
    func testDeletingAnAssetParksItInTheRecoveryFolder() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let asset = base.appendingPathComponent("assets/2026/11/photo.jpg")
        write("jpeg bytes", to: asset)

        XCTAssertTrue(store.deleteAsset(asset))
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path))
        let parked = recoveryFiles(base).filter { $0.hasSuffix("photo.jpg") }
        XCTAssertEqual(parked.count, 1)
        let parts = try XCTUnwrap(parked.first).split(separator: "/").map(String.init)
        XCTAssertEqual(Array(parts.dropFirst()), ["deleted", "assets", "2026", "11", "photo.jpg"])
        // The run folder is named for its UTC time, as the core names its own.
        XCTAssertNotNil(parts[0].range(of: #"^\d{8}T\d{6}\.\d{9}$"#, options: .regularExpression), parts[0])
        XCTAssertEqual(text(base.appendingPathComponent(".quire/media-cleanup").appendingPathComponent(parked[0])), "jpeg bytes")

        XCTAssertFalse(store.deleteAsset(asset), "it is no longer there to delete")
        XCTAssertNotNil(store.lastWriteError)

        // Kept for thirty days, then pruned; a folder named by hand never is.
        write("mine", to: base.appendingPathComponent(".quire/media-cleanup/kept-by-hand/d.jpg"))
        XCTAssertEqual(JournalStore.pruneRecovery(base: base, now: Date().addingTimeInterval(29 * 86_400)), 0)
        XCTAssertEqual(JournalStore.pruneRecovery(base: base, now: Date().addingTimeInterval(31 * 86_400)), 1)
        XCTAssertEqual(recoveryFiles(base), ["kept-by-hand/d.jpg"])
    }

    func testRecoveryStampIsUTCToTheNanosecond() {
        let stamp = JournalStore.recoveryStamp(Date(timeIntervalSince1970: 1_792_491_300.25))
        XCTAssertEqual(stamp, "20261020T101500.250000000")
    }

    /// A19: unused media is cleared by moving it, and only what nothing links.
    func testClearingUnusedMediaMovesItAndLeavesWhatIsLinked() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        write("[2026-11-06 08:00:00] with a photo\n![](assets/2026/11/used.jpg)\n", to: day(base, "2026-11-06"))
        write("used", to: base.appendingPathComponent("assets/2026/11/used.jpg"))
        write("unused", to: base.appendingPathComponent("assets/2026/11/unused.jpg"))
        store.reload()

        XCTAssertEqual(store.orphanAssets().map(\.lastPathComponent), ["unused.jpg"])
        XCTAssertEqual(store.deleteOrphanAssets(), 1)
        XCTAssertNil(store.lastWriteError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("assets/2026/11/used.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("assets/2026/11/unused.jpg").path))
        let parked = recoveryFiles(base)
        XCTAssertEqual(parked.count, 1)
        XCTAssertTrue(parked[0].hasSuffix("/orphans/assets/2026/11/unused.jpg"), parked[0])
        XCTAssertEqual(store.deleteOrphanAssets(), 0)
    }

    /// C7: a re-encode keeps the original, in the recovery folder.
    func testSwappingInACompressedFileParksTheOriginal() throws {
        let (store, base) = makeStore()
        _ = store
        defer { try? FileManager.default.removeItem(at: base) }
        let asset = base.appendingPathComponent("assets/2026/11/clip.m4a")
        let tmp = base.appendingPathComponent("assets/2026/11/._tmp_clip.m4a")
        let parked = base.appendingPathComponent(".quire/media-cleanup/20261109T100000.000000000/datasaver/assets/2026/11/clip.m4a")
        write("the original, large", to: asset)
        write("small", to: tmp)
        try MediaTranscoder.swap(tmp, into: asset, parking: parked)
        XCTAssertEqual(text(asset), "small")
        XCTAssertEqual(text(parked), "the original, large")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        // An animated or multi-page image is never re-encoded (it would lose frames).
        XCTAssertFalse(ImageDownsampler.isMultiFrame(Data("not an image".utf8)))
    }

    // MARK: Shares handed over by the extension

    /// One file per share now, the single pending.md of older builds still
    /// drained, and a file that can't be read kept rather than taken for empty.
    func testShareHandoffDrainsBothShapesAndKeepsWhatItCannotRead() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("quire-share-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        write("[2026-11-06 08:00:00] old one\nfirst\n\n[2026-11-06 08:05:00] old two\nsecond\n", to: dir.appendingPathComponent("pending.md"))
        write("[2026-11-07 09:00:00] new\n![](assets/pic.jpg)\n", to: dir.appendingPathComponent("share-A.md"))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x5B, 0xFF, 0xFE, 0xE9]).write(to: dir.appendingPathComponent("broken.processing"))
        write("picture", to: dir.appendingPathComponent("assets/pic.jpg"))
        write("still arriving", to: dir.appendingPathComponent("assets/later.mov"))

        JournalStore.drainShares(from: dir, into: base)
        store.reload()
        XCTAssertEqual(store.inboxDrafts.map(\.suffix), ["old one", "old two", "new"])
        XCTAssertEqual(text(base.appendingPathComponent("assets/pic.jpg")), "picture", "a linked file comes with its draft")
        XCTAssertEqual(names(in: dir), ["assets", "broken.processing"], "read and filed ones go; the unreadable one stays")
        XCTAssertEqual(names(in: dir.appendingPathComponent("assets")), ["later.mov"], "one nothing links yet may still be being copied")

        // Draining again adds nothing, and takes the file once it has been still.
        JournalStore.drainShares(from: dir, into: base, now: Date().addingTimeInterval(120))
        store.reload()
        XCTAssertEqual(store.inboxDrafts.count, 3)
        XCTAssertEqual(text(base.appendingPathComponent("assets/later.mov")), "still arriving")
        XCTAssertEqual(names(in: dir), ["assets", "broken.processing"])
    }

    /// Reading the inbox no longer folds legacy files unless one is there, and
    /// then only once for a file it leaves alone.
    func testALegacyInboxAppearingLaterIsStillFolded() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertNil(JournalStore.legacySignature(base: base))
        write("# Notes\nnot a journal\n", to: base.appendingPathComponent("notes.md"))
        XCTAssertNotNil(JournalStore.legacySignature(base: base))
        store.reload()
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("notes.md").path), "left alone")
        write("[2026-05-01 07:00:00] from jnl\none\n", to: inbox(base))
        store.reload()
        XCTAssertEqual(store.inboxDrafts.map(\.suffix), ["from jnl"])
        XCTAssertTrue(read(base.appendingPathComponent("inbox/2026/05/01.md")).contains("from jnl"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox(base).path))
    }

    // MARK: The stream editor's saves

    /// StreamEditor's commit: `updateDraft` / `updateFiledEntry` /
    /// `updateJournalEntry`, then `writtenEntry(fallback:)` for the reference
    /// the next save presents. Saving one row twice in a row must land both
    /// times: with the entry it opened with still in hand, the second save was
    /// refused as changed on disk.
    func testStreamEditorPathSavesTheSameEntryTwice() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        write("[2026-05-10 08:00:00] filed\nbody\n", to: day(base, "2026-05-10"))
        write("[2026-05-11 09:00:00] draft\nbody\n", to: base.appendingPathComponent("inbox/2026/05/11.md"))
        write("[2026-05-12 10:00:00] split\nbody @work\n", to: base.appendingPathComponent("split/work/2026/05/12.md"))
        store.reload()
        let all = try CoreJournal(base: base).load()

        // A filed entry.
        var current = try XCTUnwrap(all.first { $0.source == "journal" }?.entry)
        for words in ["first save", "second save", "third save"] {
            let raw = JournalStore.makeEntry(timestamp: current.ts, title: current.suffix, body: words).raw
            XCTAssertNotNil(store.updateFiledEntry(date: "2026-05-10", original: current, newText: raw, reindex: false), words)
            current = store.writtenEntry(fallback: current)
            XCTAssertEqual(current.raw, raw)
            XCTAssertNotNil(current.file, "the next save needs the store's reference")
        }
        XCTAssertEqual(read(day(base, "2026-05-10")), "[2026-05-10 08:00:00] filed\nthird save\n")

        // A draft.
        current = try XCTUnwrap(all.first { $0.source == "inbox" }?.entry)
        for words in ["first save", "second save"] {
            let raw = JournalStore.makeEntry(timestamp: current.ts, title: current.suffix, body: words).raw
            XCTAssertTrue(store.updateDraft(current, newText: raw, reindex: false), words)
            current = store.writtenEntry(fallback: current)
            XCTAssertEqual(current.raw, raw)
        }
        XCTAssertEqual(read(base.appendingPathComponent("inbox/2026/05/11.md")), "[2026-05-11 09:00:00] draft\nsecond save\n")

        // An entry in a split journal.
        current = try XCTUnwrap(all.first { $0.source == "split" }?.entry)
        for words in ["first save @work", "second save @work"] {
            let raw = JournalStore.makeEntry(timestamp: current.ts, title: current.suffix, body: words).raw
            XCTAssertTrue(store.updateJournalEntry(name: "work", original: current, newText: raw, reindex: false), words)
            current = store.writtenEntry(fallback: current)
            XCTAssertEqual(current.raw, raw)
        }
        XCTAssertTrue(read(base.appendingPathComponent("split/work/2026/05/12.md")).contains("second save @work"))
        XCTAssertNil(store.lastWriteError)
    }

    // MARK: A body line that looks like a header

    /// The core stores `[2026-…] pasted` in a body as `\[2026-…] pasted`. An
    /// editor opens with `shownBody` (no backslash) and saves through
    /// `makeEntry`, which puts it back: an untouched page composes to exactly
    /// the entry's raw text, so it reads as clean and is not rewritten, and an
    /// edited one is still one entry.
    func testAGuardedBodyOpensAsTypedAndSavesBackAsStored() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let stored = "[2026-05-10 08:00:00] notes\nbefore\n\\[2026-05-09 07:00:00] pasted line\nafter\n"
        write(stored, to: day(base, "2026-05-10"))
        store.reload()
        let entry = try XCTUnwrap(CoreJournal(base: base).load().first?.entry)
        XCTAssertEqual(entry.body, "before\n\\[2026-05-09 07:00:00] pasted line\nafter")
        XCTAssertEqual(entry.shownBody, "before\n[2026-05-09 07:00:00] pasted line\nafter")
        XCTAssertEqual(entry.preview, "notes")
        // Clean: what the editor would write is what is there (an entry read
        // from a file carries the blank line after it; one composed doesn't).
        let composed = JournalStore.makeEntry(timestamp: entry.ts, title: entry.suffix, body: entry.shownBody)
        XCTAssertEqual(composed.raw, JournalParser.trimRightNewlines(entry.raw))
        XCTAssertEqual(composed.body, entry.body)
        XCTAssertEqual(composed.raw, JournalStore.makeEntry(timestamp: entry.ts, title: entry.suffix, body: entry.body).raw,
                       "the Mac editors' baseline, composed from the stored body, matches too")
        // Edited: saved through the composer's path, still one entry, still guarded.
        let raw = JournalStore.makeEntry(timestamp: entry.ts, title: entry.suffix, body: entry.shownBody + "\nmore").raw
        let saved = try XCTUnwrap(store.saveEditorEntry(entry, source: .archive(date: entry.date), text: raw))
        XCTAssertEqual(saved.entry.shownBody, "before\n[2026-05-09 07:00:00] pasted line\nafter\nmore")
        XCTAssertEqual(read(day(base, "2026-05-10")),
                       "[2026-05-10 08:00:00] notes\nbefore\n\\[2026-05-09 07:00:00] pasted line\nafter\nmore\n")
        XCTAssertEqual(try CoreJournal(base: base).load().count, 1)
        // A backslash the core didn't put there is left alone.
        let plain = JournalStore.makeEntry(timestamp: "2026-05-10 08:00:00", title: "", body: "\\[not a date] x\n\\\\[2026-05-09 07:00:00] y")
        XCTAssertEqual(plain.shownBody, plain.body)
        // An untitled entry's preview is its first line as typed.
        let untitled = JournalStore.makeEntry(timestamp: "2026-05-10 08:00:00", title: "", body: "[2026-05-09 07:00:00] pasted first")
        XCTAssertEqual(untitled.preview, "[2026-05-09 07:00:00] pasted first")
        XCTAssertEqual(JournalStore.excerpt(of: entry), "before")
    }

    // MARK: The Data Saver ledger's ids

    /// The core lists each asset twice (`2026/09/x.jpg` and `2026/09/x`), and
    /// this app used to list the bare name (`x`). All three say the file is
    /// done; a short form that a long form explains says nothing about a file
    /// of another kind with the same name.
    func testLedgerIdsAreReadInEveryFormAndWrittenAsTheCoreWritesThem() {
        XCTAssertEqual(JournalStore.ledgerKey(assetRelPath: "assets/2026/09/x.jpg"), "2026/09/x.jpg")
        XCTAssertEqual(JournalStore.ledgerIDs(forKey: "2026/09/x.jpg"), ["2026/09/x.jpg", "2026/09/x"])
        XCTAssertEqual(JournalStore.ledgerIDs(forKey: "flat"), ["flat"])

        let core = JournalStore.LedgerHandled(["2026/09/x.jpg", "2026/09/x"])
        XCTAssertTrue(core.has(key: "2026/09/x.jpg"))
        XCTAssertFalse(core.has(key: "2026/09/x.mp4"), "the photo's short id is explained by its long one")
        XCTAssertFalse(core.has(key: "2026/09/y.jpg"))

        let nook = JournalStore.LedgerHandled(["2026/09/x"])
        XCTAssertTrue(nook.has(key: "2026/09/x.jpg"))
        XCTAssertTrue(nook.has(key: "2026/09/x.mp4"), "an unexplained short id can't tell them apart")

        let earlier = JournalStore.LedgerHandled(["ABC-123"])
        XCTAssertTrue(earlier.has(key: "2026/09/ABC-123.jpg"), "the bare name this app wrote before")
        XCTAssertTrue(earlier.has(key: "ABC-123.jpg"))

        let mixed = JournalStore.LedgerHandled(["ABC-123", "2026/09/ABC-123.jpg", "2026/09/ABC-123"])
        XCTAssertTrue(mixed.has(key: "2026/09/ABC-123.jpg"))
        XCTAssertFalse(mixed.has(key: "2026/09/ABC-123.mov"))
    }

    /// An attachment Data Saver shrank is listed once per id and its bytes
    /// counted once, in the shape the core reads and writes.
    func testAnAttachmentsSavingIsCountedOnceUnderBothIds() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        defer { UserDefaults.standard.removeObject(forKey: "dataSaver") }
        UserDefaults.standard.set(true, forKey: "dataSaver")
        // A large flat-colour image: PNG in, smaller PNG out at 2048 px.
        let side = 2400
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for i in 0..<48 {
            context.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
            context.fill(CGRect(x: i * 50, y: 0, width: 50, height: side))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let rel = try XCTUnwrap(store.saveAsset(data as Data, ext: "png"))
        let saved = store.totalDataSaved()
        try XCTSkipIf(saved == 0, "the downsampler found nothing to save on this host")
        struct Ledger: Decodable { let savedBytes: Int; let assets: [String] }
        let sidecar = base.appendingPathComponent(".quire")
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: sidecar.path).first { $0.hasPrefix("datasaver-") })
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: sidecar.appendingPathComponent(file)))
        let key = String(rel.dropFirst("assets/".count))
        XCTAssertEqual(ledger.assets, [key, (key as NSString).deletingPathExtension])
        XCTAssertEqual(ledger.savedBytes, saved)
        XCTAssertEqual(store.dataSaved, saved)
    }

    // MARK: Maintenance off the main actor

    /// The async jobs do what the main-actor ones do, and the lists are read
    /// again when they finish.
    func testFileAllDraftsAsyncFilesTheDraftsAndReloads() async throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        write("[2026-05-11 09:00:00] one\nbody\n\n[2026-05-11 10:00:00] two\nbody\n", to: base.appendingPathComponent("inbox/2026/05/11.md"))
        write("[2026-05-12 08:00:00] from transfer\nbody\n", to: base.appendingPathComponent("transfer.md"))
        store.reload()
        try await waitForIndex(store)
        XCTAssertEqual(store.inboxDrafts.count, 2)
        let filed = await store.fileAllDraftsAsync()
        XCTAssertEqual(filed, 2)
        XCTAssertTrue(store.inboxDrafts.isEmpty)
        XCTAssertTrue(read(day(base, "2026-05-11")).contains("] two"))
        XCTAssertNil(store.lastWriteError)
        let transferred = await store.fileTransferAsync()
        XCTAssertEqual(transferred, 1)
        XCTAssertTrue(read(day(base, "2026-05-12")).contains("from transfer"))
        let merged = await store.mergeConflictCopiesAsync()
        XCTAssertEqual(merged, 0)
        let exSplit = await store.mergeExSplitJournalsAsync()
        XCTAssertEqual(exSplit.journals, 0)
        for _ in 0..<500 where store.entries(for: "2026-05-11").count != 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.entries(for: "2026-05-11").count, 2)
    }
}
