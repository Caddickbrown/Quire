//
//  NookTests.swift
//  NookTests
//
//  The XCTest home for the pure model layer: jnl parser parity (the same cases
//  ParserChecks runs standalone via `make check`), the search-query grammar,
//  and the editor's list-continuation rules. The test target compiles the pure
//  model sources directly (no app host), so these run as plain logic tests:
//
//      xcodebuild test -project Nook.xcodeproj -scheme Nook \
//          -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
//
//  `make check` stays the fast no-Xcode path; keep the two in step when the
//  parser or grammar changes.
//

import XCTest

// MARK: - jnl parser parity (mirrors ~/Code/jnl/main_test.go)

final class JournalParserTests: XCTestCase {
    func testParseBasicFields() {
        let e = JournalParser.parseEntries("[2026-05-10 08:00:00] A title\nfirst line\nsecond line\n")
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e.first?.date, "2026-05-10")
        XCTAssertEqual(e.first?.ts, "2026-05-10 08:00:00")
        XCTAssertEqual(e.first?.suffix, "A title")
        XCTAssertEqual(e.first?.body, "first line\nsecond line")
    }

    func testPreambleDroppedOnParsePreservedByHelper() {
        let src = "orphan line\n\n[2026-05-10 08:00:00] one\nbody1\n\n[2026-05-11 09:00:00] two\nbody2\n"
        let e = JournalParser.parseEntries(src)
        XCTAssertEqual(e.map(\.suffix), ["one", "two"])
        XCTAssertEqual(JournalParser.leadingPreamble(src), "orphan line")
        XCTAssertEqual(JournalParser.leadingPreamble("\n\n[2026-05-10 08:00:00] x\n"), "")
        XCTAssertEqual(JournalParser.leadingPreamble("just text\nmore text\n"), "just text\nmore text")
    }

    func testSortStableOldestFirst() {
        let input = [
            Entry(date: "", ts: "2026-05-20 09:00:00", suffix: "c", body: "", raw: ""),
            Entry(date: "", ts: "2026-05-10 08:00:00", suffix: "a", body: "", raw: ""),
            Entry(date: "", ts: "2026-05-15 12:30:00", suffix: "b", body: "", raw: ""),
        ]
        XCTAssertEqual(JournalParser.sortedByTimestamp(input).map(\.suffix), ["a", "b", "c"])
        XCTAssertEqual(input[0].suffix, "c", "input untouched")

        let ties = ["first", "second", "third"].map {
            Entry(date: "", ts: "2026-05-10 08:00:00", suffix: $0, body: "", raw: "")
        }
        XCTAssertEqual(JournalParser.sortedByTimestamp(ties).map(\.suffix),
                       ["first", "second", "third"], "stable on ties")
    }

    func testRenderRoundTrip() {
        let src = "loose\n\n[2026-05-20 09:00:00] later\nB1\n\n[2026-05-10 08:00:00] earlier\nB2\n"
        let once = JournalParser.parseEntries(src)
        let rendered = JournalParser.renderEntries(preamble: JournalParser.leadingPreamble(src),
                                                   entries: once)
        XCTAssertEqual(JournalParser.parseEntries(rendered).map(\.raw), once.map(\.raw))
        XCTAssertEqual(JournalParser.renderEntries(preamble: "", entries: []), "")
    }

    func testTagsWholeTokens() {
        XCTAssertEqual(JournalParser.splitTags("real @work item and @health-check not @1bad"),
                       ["@work", "@health-check"])
    }
}

// MARK: - Cleanup punctuation (link-safe)

final class NormalizePunctuationTests: XCTestCase {
    func testProseEllipsisAndQuotes() {
        XCTAssertEqual(JournalParser.normalizePunctuation("wait... what"), "wait\u{2026} what")
        XCTAssertEqual(JournalParser.normalizePunctuation("\u{2019}tis \u{201C}q\u{201D}"), "'tis \"q\"")
    }

    func testMediaLinksAreMasked() {
        XCTAssertEqual(
            JournalParser.normalizePunctuation("see... ![dots](assets/a...b.png) end..."),
            "see\u{2026} ![dots](assets/a...b.png) end\u{2026}")
        XCTAssertEqual(JournalParser.normalizePunctuation("![alt...](a.png)"), "![alt...](a.png)")
    }
}

// MARK: - Search grammar

final class SearchQueryTests: XCTestCase {
    private func entry(_ date: String, _ suffix: String, _ body: String) -> Entry {
        let ts = date + " 08:00:00"
        let raw = suffix.isEmpty ? "[\(ts)]\n\(body)" : "[\(ts)] \(suffix)\n\(body)"
        return Entry(date: date, ts: ts, suffix: suffix, body: body, raw: raw)
    }

    func testTokenizeKeepsQuotedPhrases() {
        XCTAssertEqual(SearchQuery.tokenize(#"plain "two words" tag:work"#),
                       ["plain", "two words", "tag:work"])
    }

    func testOperatorsParse() {
        let q = SearchQuery.parse(#"coffee tag:Work before:2026-03 after:2025 has:image is:starred"#)
        XCTAssertEqual(q.terms, ["coffee"])
        XCTAssertEqual(q.tags, ["@work"])
        XCTAssertEqual(q.before, "2026-03")
        XCTAssertEqual(q.after, "2025")
        XCTAssertEqual(q.has, ["image"])
        XCTAssertTrue(q.starred)
        XCTAssertTrue(SearchQuery.parse("").isEmpty)
        XCTAssertFalse(SearchQuery.isPartialDate("26-03"))
    }

    func testMatchingClausesAreConjunctive() {
        let q = SearchQuery.parse(#"coffee tag:Work before:2026-03 after:2025 has:image is:starred"#)
        XCTAssertTrue(q.matches(entry("2026-02-10", "Morning *", "coffee @work ![](assets/a.png)")))
        XCTAssertFalse(q.matches(entry("2026-02-10", "Morning *", "coffee @work")), "has:image")
        XCTAssertFalse(q.matches(entry("2026-03-01", "Morning *", "coffee @work ![](assets/a.png)")), "before:")
        XCTAssertFalse(q.matches(entry("2024-12-31", "Morning *", "coffee @work ![](assets/a.png)")), "after:")
    }

    func testPhrasesAndInclusiveAfter() {
        let phrase = SearchQuery.parse(#""exact phrase""#)
        XCTAssertTrue(phrase.matches(entry("2026-01-01", "", "an exact phrase here")))
        XCTAssertFalse(phrase.matches(entry("2026-01-01", "", "exact other phrase")))
        XCTAssertTrue(SearchQuery.parse("after:2026-03").matches(entry("2026-03-01", "", "x")))
    }
}

// MARK: - Editor list continuation

final class ListContinuationTests: XCTestCase {
    func testBulletContinuesAndEnds() {
        XCTAssertEqual(ListContinuation.action(for: "- milk"), .continueList(prefix: "- "))
        XCTAssertEqual(ListContinuation.action(for: "  * two"), .continueList(prefix: "  * "))
        XCTAssertEqual(ListContinuation.action(for: "- "), .endList(prefixLength: 2))
        XCTAssertEqual(ListContinuation.action(for: "  - "), .endList(prefixLength: 4))
    }

    func testOrderedIncrementsAndEnds() {
        XCTAssertEqual(ListContinuation.action(for: "1. first"), .continueList(prefix: "2. "))
        XCTAssertEqual(ListContinuation.action(for: "  9) nine"), .continueList(prefix: "  10) "))
        XCTAssertEqual(ListContinuation.action(for: "3. "), .endList(prefixLength: 3))
    }

    func testCheckboxContinuesUncheckedAndEnds() {
        XCTAssertEqual(ListContinuation.action(for: "- [x] done thing"),
                       .continueList(prefix: "- [ ] "), "next box starts unchecked")
        XCTAssertEqual(ListContinuation.action(for: "- [ ] "), .endList(prefixLength: 6))
    }

    func testPlainProseIsUntouched() {
        XCTAssertEqual(ListContinuation.action(for: "just a sentence - with a dash"), .none)
        XCTAssertEqual(ListContinuation.action(for: ""), .none)
    }
}
