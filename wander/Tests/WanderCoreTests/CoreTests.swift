//
//  CoreTests.swift
//  WanderCoreTests
//
//  The format is the contract between five programs — the macOS app, the iOS
//  app, the Tauri app, the Android app and the `jnl` CLI — so these tests are
//  about bytes, not behaviour. The first fourteen are the Android suite's
//  (`ParserTest.kt`), case for case, so the two ports are held to the same
//  contract; the rest are the ways a write could cost someone their journal.
//

import XCTest
import WanderCore

final class ParserTests: XCTestCase {

    private let sample = """
        # My journal

        [2026-09-08 08:12:00] The long way round the reservoir *
        Left before seven and took the **long way** round.

        ## What the light was doing

        - ask about the boiler service @admin

        [2026-09-08 19:40:00] Evening
        Nothing much. @admin @Admin @later
        """

    private let x = URL(fileURLWithPath: "/tmp/x.md")

    func testParsesEntriesAndLeavesThePreambleOutOfThem() {
        let entries = JournalParser.parseEntries(sample, source: x)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].ts, "2026-09-08 08:12:00")
        XCTAssertEqual(entries[0].date, "2026-09-08")
        XCTAssertEqual(entries[0].suffix, "The long way round the reservoir *")
        XCTAssertTrue(entries[0].body.hasPrefix("Left before seven"))
        XCTAssertFalse(entries[0].body.contains("My journal"))
    }

    func testPreambleSurvivesARewrite() {
        let preamble = JournalParser.leadingPreamble(sample)
        XCTAssertEqual(preamble, "# My journal")

        let entries = JournalParser.parseEntries(sample, source: x)
        let rendered = JournalParser.renderEntries(preamble: preamble, entries: entries)
        XCTAssertTrue(rendered.hasPrefix("# My journal\n\n"))
        XCTAssertTrue(rendered.contains("[2026-09-08 08:12:00] The long way round the reservoir *"))
        XCTAssertTrue(rendered.contains("[2026-09-08 19:40:00] Evening"))
        XCTAssertTrue(rendered.hasSuffix("\n"))
    }

    func testRenderingIsIdempotentSoARewriteNeverChurnsTheFile() {
        let once = render(sample)
        // Saving an untouched file must not change it, or every entry would
        // show as modified to a sync client.
        XCTAssertEqual(once, render(once))
    }

    func testReparsingARenderGivesBackTheSameEntries() {
        let first = JournalParser.parseEntries(sample, source: x)
        let second = JournalParser.parseEntries(render(sample), source: x)
        XCTAssertEqual(first.map(\.ts), second.map(\.ts))
        XCTAssertEqual(first.map(\.suffix), second.map(\.suffix))
        XCTAssertEqual(first.map(\.body), second.map(\.body))
        XCTAssertEqual(first.map { JournalParser.trimRightNewlines($0.raw) },
                       second.map { JournalParser.trimRightNewlines($0.raw) })
    }

    func testAStarIsAStandaloneTokenNotAnyTrailingAsterisk() {
        let starred = entry("2026-01-01 09:00:00", "A title *")
        XCTAssertTrue(starred.isStarred)
        XCTAssertEqual(starred.displayTitle, "A title")

        // A bold title ends in an asterisk too, and un-starring it used to eat
        // one of them.
        let bold = entry("2026-01-01 09:00:00", "**Important**")
        XCTAssertFalse(bold.isStarred)
        XCTAssertEqual(bold.displayTitle, "**Important**")

        let bare = entry("2026-01-01 09:00:00", "*")
        XCTAssertTrue(bare.isStarred)
        XCTAssertEqual(bare.displayTitle, "")
    }

    func testStarringRoundTripsThroughTheTitle() {
        let plain = entry("2026-01-01 09:00:00", "A title", "Body")
        let starred = plain.revised(title: plain.displayTitle, body: plain.body, starred: true)
        XCTAssertEqual(starred.suffix, "A title *")
        let back = starred.revised(title: starred.displayTitle, body: starred.body, starred: false)
        XCTAssertEqual(back.suffix, "A title")
        XCTAssertEqual(back.raw, plain.raw)
    }

    func testTagsAreDeduplicatedCaseInsensitivelyInOrderOfAppearance() {
        let entries = JournalParser.parseEntries(sample, source: x)
        XCTAssertEqual(entries[1].tags, ["@admin", "@later"])
    }

    func testAnEnDashDateIsNormalisedToHyphens() {
        let entries = JournalParser.parseEntries("[2026–09–08 08:12:00] Title\nBody", source: x)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].ts, "2026-09-08 08:12:00")
        XCTAssertEqual(entries[0].date, "2026-09-08")
        XCTAssertTrue(entries[0].raw.hasPrefix("[2026-09-08 08:12:00]"))
    }

    func testEntriesSortChronologicallyAndStably() {
        let a = entry("2026-01-01 09:00:00", "a")
        let b = entry("2026-01-01 08:00:00", "b")
        let c = entry("2026-01-01 09:00:00", "c")
        XCTAssertEqual(JournalParser.sortedByTimestamp([a, b, c]).map(\.suffix), ["b", "a", "c"])
    }

    func testADayFileIsJournalSlashYearSlashMonthSlashDay() {
        let library = JournalLibrary(baseURL: URL(fileURLWithPath: "/tmp/base", isDirectory: true))
        XCTAssertEqual(library.dayFile(for: "2026-09-08")?.path, "/tmp/base/journal/2026/09/08.md")
        XCTAssertNil(library.dayFile(for: "nonsense"))
    }

    func testAnEntryInTheInboxIsUnfiledAndOneInADayFileIsNot() {
        let library = JournalLibrary(baseURL: URL(fileURLWithPath: "/tmp/base", isDirectory: true))
        let day = library.dayFile(for: "2026-01-01")
        XCTAssertTrue(library.isUnfiled(entry("2026-01-01 09:00:00", source: library.inboxURL)))
        XCTAssertFalse(library.isUnfiled(entry("2026-01-01 09:00:00", source: day)))
        XCTAssertFalse(library.isUnfiled(entry("2026-01-01 09:00:00")))
    }

    func testAnEmptyEntryRendersAsABareHeader() {
        let blank = entry("2026-01-01 09:00:00", "A title").revised(title: "", body: "")
        XCTAssertEqual(blank.raw, "[2026-01-01 09:00:00]")
    }

    func testPreviewFallsBackToTheFirstBodyLineWithItsMarkersStripped() {
        XCTAssertEqual(entry("2026-01-01 09:00:00", "", "## A heading\nand more").preview, "A heading")
    }

    func testCountsWalkTheTextTheWayTheStatusLineReportsIt() {
        XCTAssertEqual(Counts.words("one two  three"), 3)
        XCTAssertEqual(Counts.words("   \n\t "), 0)
        XCTAssertEqual(Counts.readingMinutes(""), 0)
        XCTAssertEqual(Counts.readingMinutes("a few words here"), 1)
        XCTAssertEqual(Counts.paragraphs("one\n\ntwo"), 2)
    }

    // MARK: Line endings and byte-order marks

    func testCRLFIsReadAsLF() {
        let crlf = "[2026-09-08 08:00:00] One\r\nline a\r\nline b\r\n\r\n[2026-09-08 09:00:00] Two\r\nbody\r\n"
        let entries = JournalParser.parseEntries(crlf, source: x)
        XCTAssertEqual(entries.map(\.suffix), ["One", "Two"])
        XCTAssertEqual(entries[0].body, "line a\nline b")
        XCTAssertFalse(render(crlf).utf8.contains(0x0D))
        XCTAssertEqual(render(crlf), render(render(crlf)))
    }

    func testTrailingCRLFIsNotTakenForOneCharacter() {
        XCTAssertEqual(JournalParser.trimRightNewlines("a\n\n"), "a")
        // Go's TrimRight(s, "\n") leaves the "\r"; so does this.
        XCTAssertEqual(JournalParser.trimRightNewlines("a\r\n"), "a\r")
    }

    func testALeadingByteOrderMarkDoesNotHideTheFirstEntry() {
        let text = "\u{FEFF}[2026-09-08 08:00:00] First\nbody"
        XCTAssertEqual(JournalParser.parseEntries(text, source: x).map(\.suffix), ["First"])
        XCTAssertEqual(JournalParser.leadingPreamble(text), "")
    }

    // MARK: Helpers

    private func render(_ text: String) -> String {
        JournalParser.renderEntries(preamble: JournalParser.leadingPreamble(text),
                                    entries: JournalParser.parseEntries(text, source: x))
    }
}

/// Writes against a real folder, in a fresh temporary directory per test.
final class LibraryTests: XCTestCase {

    private var base: URL!
    private var library: JournalLibrary!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wander-tests-\(UUID().uuidString)", isDirectory: true)
        library = JournalLibrary(baseURL: base)
        library.ensureFolders()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Refusing to rewrite what can't be read

    func testANonUTF8DayFileIsRefusedAndLeftByteForByte() throws {
        let day = try XCTUnwrap(library.dayFile(for: "2026-09-08"))
        try FileManager.default.createDirectory(at: day.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // "café" in Latin-1: 0xE9 on its own is not UTF-8.
        var bytes = Data("[2026-09-08 08:00:00] One\ncaf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: Data("\n\n[2026-09-08 09:00:00] Two\nbody\n".utf8))
        try bytes.write(to: day)

        let third = entry("2026-09-08 10:00:00", "Three", "new", source: day)
        XCTAssertThrowsError(try library.persist(third, previous: nil)) { error in
            XCTAssertEqual(error as? JournalError, .notUTF8("08.md"))
        }
        XCTAssertThrowsError(try library.remove(entry("2026-09-08 09:00:00", "Two", source: day)))
        XCTAssertThrowsError(try library.move(entry("2026-09-08 09:00:00", "Two", source: day),
                                              to: library.inboxURL, stamp: "2026-09-08 09:00:00"))
        XCTAssertEqual(try Data(contentsOf: day), bytes)
        // Refused before anything was written, not after a copy was made.
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.inboxURL.path))
    }

    func testTheFirstEntryOfADayCreatesItsFileAndLeavesNoTemporaryBehind() throws {
        let day = try XCTUnwrap(library.dayFile(for: "2026-09-08"))
        try library.persist(entry("2026-09-08 08:00:00", "One", "body"), previous: nil)
        XCTAssertEqual(try String(contentsOf: day, encoding: .utf8), "[2026-09-08 08:00:00] One\nbody\n")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: day.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["08.md"])
    }

    func testASaveToACRLFFileWritesLF() throws {
        try "[2026-09-08 08:00:00] One\r\nline\r\n".write(to: library.inboxURL, atomically: true, encoding: .utf8)
        try library.persist(entry("2026-09-08 09:00:00", "Two", source: library.inboxURL), previous: nil)
        let written = try String(contentsOf: library.inboxURL, encoding: .utf8)
        XCTAssertEqual(written, "[2026-09-08 08:00:00] One\nline\n\n[2026-09-08 09:00:00] Two\n")
    }

    // MARK: Moving keeps exactly one copy

    func testFilingMovesTheEntryFromTheInboxToItsDay() throws {
        let draft = try library.persist(entry("2026-09-08 08:00:00", "Draft", "body",
                                              source: library.inboxURL), previous: nil)
        let day = try XCTUnwrap(library.dayFile(for: draft.date))
        let filed = try library.move(draft, to: day, stamp: draft.ts)

        XCTAssertEqual(filed.source, day)
        XCTAssertEqual(filed.ts, draft.ts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.inboxURL.path))
        XCTAssertEqual(try entries(in: day).map(\.ts), [draft.ts])
    }

    func testMovingOntoATakenSecondTakesTheNextFreeOne() throws {
        let day = try XCTUnwrap(library.dayFile(for: "2026-09-08"))
        try library.persist(entry("2026-09-08 08:00:00", "Already here", source: day), previous: nil)
        let draft = try library.persist(entry("2026-09-08 08:00:00", "Draft",
                                              source: library.inboxURL), previous: nil)
        let filed = try library.move(draft, to: day, stamp: draft.ts)

        XCTAssertEqual(filed.ts, "2026-09-08 08:00:01")
        XCTAssertEqual(try entries(in: day).map(\.suffix), ["Already here", "Draft"])
    }

    func testRetimingWithinAFileKeepsOneCopy() throws {
        let day = try XCTUnwrap(library.dayFile(for: "2026-09-08"))
        let first = try library.persist(entry("2026-09-08 08:00:00", "First", source: day), previous: nil)
        try library.persist(entry("2026-09-08 09:00:00", "Second", source: day), previous: nil)

        let later = try library.move(first, to: day, stamp: "2026-09-08 10:00:00")
        XCTAssertEqual(later.ts, "2026-09-08 10:00:00")
        XCTAssertEqual(try entries(in: day).map(\.suffix), ["Second", "First"])
    }

    func testMovingAnEntryOntoItsOwnSecondKeepsIt() throws {
        // The case a write-then-remove order gets wrong: the stamp comes back
        // unchanged, so the write replaces the entry and a remove by the old
        // stamp would then take out the only copy.
        let day = try XCTUnwrap(library.dayFile(for: "2026-09-08"))
        let only = try library.persist(entry("2026-09-08 08:00:00", "Only", "body", source: day),
                                       previous: nil)
        _ = try library.move(only, to: day, stamp: only.ts)
        XCTAssertEqual(try entries(in: day).map(\.suffix), ["Only"])
    }

    func testAnUntouchedEntryIsNeverWrittenByAMove() throws {
        let day = try XCTUnwrap(library.dayFile(for: "2026-09-08"))
        let blank = entry("2026-09-08 08:00:00", source: library.inboxURL)
        let moved = try library.move(blank, to: day, stamp: blank.ts)
        XCTAssertNil(moved.source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: day.path))
    }

    // MARK: Helpers

    private func entries(in url: URL) throws -> [Entry] {
        JournalParser.parseEntries(try String(contentsOf: url, encoding: .utf8), source: url)
    }
}

/// An entry as the parser would produce it from `[ts] suffix` + body.
private func entry(_ ts: String, _ suffix: String = "", _ body: String = "",
                   source: URL? = nil) -> Entry {
    var head = "[\(ts)]"
    if !suffix.isEmpty { head += " " + suffix }
    return Entry(date: String(ts.prefix(10)), ts: ts, suffix: suffix, body: body,
                 raw: body.isEmpty ? head : head + "\n" + body, source: source)
}
