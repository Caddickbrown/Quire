//
//  QuireTests.swift
//  QuireTests
//
//  The XCTest home for the pure model layer: jnl parser parity (the same cases
//  ParserChecks runs standalone via `make check`), the search-query grammar,
//  and the editor's list-continuation rules. The test target compiles the pure
//  model sources directly (no app host), so these run as plain logic tests:
//
//      xcodebuild test -project Quire.xcodeproj -scheme Quire \
//          -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
//
//  `make check` stays the fast no-Xcode path; keep the two in step when the
//  parser or grammar changes.
//

import XCTest

// MARK: - jnl parser parity (mirrors ~/Code/jnl/main_test.go)

final class JournalParserTests: XCTestCase {
    /// The per-line check behind the editors' body escaper must agree with
    /// the parser on what opens an entry.
    func testHeaderLineCheckMatchesTheParser() {
        XCTAssertTrue(JournalParser.isHeaderLine("[2026-05-10 08:00:00] title"))
        XCTAssertTrue(JournalParser.isHeaderLine("[2026-05-10 08:00:00]"))
        XCTAssertFalse(JournalParser.isHeaderLine("\\[2026-05-10 08:00:00] escaped"))
        XCTAssertFalse(JournalParser.isHeaderLine(" [2026-05-10 08:00:00] indented"))
        XCTAssertFalse(JournalParser.isHeaderLine("[2026-05-10] no time"))
    }

    func testMediaTargetsAfterCleanup() {
        let text = "![caption](<assets/2026/09/old photo.jpg> \"Title\") ![](assets/2026/09/a%23b.jpg)"
        XCTAssertEqual(MediaLinks.paths(in: text), ["assets/2026/09/old photo.jpg", "assets/2026/09/a#b.jpg"])
        XCTAssertEqual(MediaLinks.resolved("../../../assets/2026/09/photo.jpg", file: "journal/2026/09/30.md"), "assets/2026/09/photo.jpg")
        XCTAssertNotEqual(MediaLinks.resolved("assets/2026/09/photo.jpg", file: "inbox.md"), MediaLinks.resolved("assets/2026/10/photo.jpg", file: "inbox.md"))
        XCTAssertNil(MediaLinks.resolved("../../outside.jpg", file: "inbox.md"))
    }

    func testStrippingLinksLeavesTheProse() {
        XCTAssertEqual(MediaLinks.strippingLinks("see ![cap](assets/a.png) here"), "see   here")
        XCTAssertEqual(MediaLinks.strippingLinks("plain"), "plain")
    }

    /// The star marker is a standalone token. A bare `hasSuffix("*")` also
    /// matched a markdown-bold title, which then lost one `*` per un-star.
    func testStarMarkerIsAStandaloneToken() {
        func titled(_ suffix: String) -> Entry {
            JournalParser.parseEntries("[2026-05-10 08:00:00] \(suffix)\nbody\n").first!
        }
        XCTAssertTrue(titled("Morning *").isStarred)
        XCTAssertTrue(titled("*").isStarred, "a bare marker is the whole title")
        XCTAssertFalse(titled("**bold**").isStarred, "markdown bold is not a star")
        XCTAssertFalse(titled("2 * 3").isStarred, "a mid-title asterisk is not a marker")
        XCTAssertFalse(titled("").isStarred)
        XCTAssertEqual(titled("Morning *").displayTitle, "Morning")
        XCTAssertEqual(titled("*").displayTitle, "")
        XCTAssertEqual(titled("**bold**").displayTitle, "**bold**")

    }

    /// The editors hold the title as text and toggle through the same helpers
    /// the store uses, so a round-trip must land back on the original.
    func testStarMarkerHelpersRoundTrip() {
        func titled(_ suffix: String) -> Entry {
            JournalParser.parseEntries("[2026-05-10 08:00:00] \(suffix)\nbody\n").first!
        }
        for title in ["Morning", "**bold**", "", "2 * 3", "  Trailing \n"] {
            let on = Entry.togglingStarMarker(title)
            XCTAssertTrue(Entry.hasStarMarker(on), "starring \(title)")
            XCTAssertTrue(titled(on).isStarred, "starring \(title), parsed")
            XCTAssertEqual(Entry.strippingStarMarker(on), Entry.strippingStarMarker(title), "text kept: \(title)")
            XCTAssertEqual(Entry.togglingStarMarker(on), Entry.strippingStarMarker(title), "round-trip \(title)")
        }
        XCTAssertFalse(Entry.hasStarMarker("**bold**"))
        XCTAssertEqual(Entry.strippingStarMarker("**bold**"), "**bold**")
        XCTAssertEqual(Entry.togglingStarMarker("*"), "")
    }

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
        XCTAssertEqual(JournalParser.leadingPreamble("[2026-05-10 08:00:00] x\nbody\n"), "", "none")
        XCTAssertEqual(JournalParser.leadingPreamble("\n\n[2026-05-10 08:00:00] x\n"), "", "blank only")
        XCTAssertEqual(JournalParser.leadingPreamble("a\nb\n[2026-05-10 08:00:00] x\n"), "a\nb", "multiline")
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

        // Byte-for-byte, as jnl's rebuildInbox writes it.
        let e = Entry(date: "2026-05-10", ts: "2026-05-10 08:00:00", suffix: "a",
                      body: "body", raw: "[2026-05-10 08:00:00] a\nbody")
        XCTAssertEqual(JournalParser.renderEntries(preamble: "loose note", entries: [e]),
                       "loose note\n\n[2026-05-10 08:00:00] a\nbody\n")
    }

    func testEntryIdentityIsStableAcrossReparses() {
        let text = """
        [2026-05-10 08:00:00] first
        body one
        [2026-05-10 08:00:00] twin
        body two
        [2026-05-10 09:30:00] later
        body three
        """
        let a = JournalParser.parseEntries(text)
        let b = JournalParser.parseEntries(text)
        XCTAssertEqual(a.map(\.id), b.map(\.id), "a re-parse must not re-identify every entry")
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a.map(\.id)).count, a.count, "same-second twins need distinct ids")
        XCTAssertEqual(a[0].id, "2026-05-10 08:00:00")
        XCTAssertEqual(a[1].id, "2026-05-10 08:00:00#1")

        let rendered = JournalParser.renderEntries(preamble: "", entries: a)
        XCTAssertEqual(JournalParser.parseEntries(rendered).map(\.id), a.map(\.id))
    }

    func testOccurrenceRenumberingFixesSplicedEntries() {
        let a = JournalParser.parseEntries("""
        [2026-05-10 08:00:00] first
        [2026-05-10 08:00:00] twin
        [2026-05-10 09:30:00] later
        """)
        // What a store rewrite does: splice a freshly parsed entry (occurrence
        // 0) over one of a same-second pair.
        let spliced = [a[0], JournalParser.parseEntries("[2026-05-10 08:00:00] replaced").first!, a[2]]
        XCTAssertEqual(Set(spliced.map(\.id)).count, 2, "the splice collides before renumbering")
        let fixed = JournalParser.withOccurrences(spliced)
        XCTAssertEqual(Set(fixed.map(\.id)).count, 3)
        XCTAssertEqual(JournalParser.withOccurrences(a).map(\.id), a.map(\.id), "idempotent")
        XCTAssertTrue(JournalParser.withOccurrences([]).isEmpty)
    }

    /// Search, Starred and Tags merge entries from several files into one list.
    /// Each pool numbers its own same-second twins, so the ids collide across
    /// the merge unless the merged list is renumbered — which is what those
    /// views' source maps are keyed on.
    func testMergedPoolsNeedRenumbering() {
        let draft = JournalParser.parseEntries("[2026-05-10 08:00:00] a draft\nbody")
        let filed = JournalParser.parseEntries("[2026-05-10 08:00:00] a filed entry\nbody")
        XCTAssertEqual(draft[0].id, filed[0].id, "per-pool ids collide before renumbering")
        XCTAssertNotEqual(draft[0], filed[0], "they are genuinely different entries")

        let merged = JournalParser.withOccurrences(draft + filed)
        XCTAssertEqual(Set(merged.map(\.id)).count, 2)
        XCTAssertEqual(merged.map(\.raw), (draft + filed).map(\.raw), "order is preserved")
    }

    func testTagsWholeTokens() {
        XCTAssertEqual(JournalParser.splitTags("real @work item and @health-check not @1bad"),
                       ["@work", "@health-check"])
    }

    /// Why one editor's text is always one entry. Pasting a day's worth of
    /// entries into the composer used to be written verbatim, so the next parse
    /// of inbox.md handed back extra drafts — and every autosave added more.
    /// `JournalStore.makeEntry` escapes the embedded headers (the composer
    /// offers Import instead); these are the parser facts that rests on.
    func testEmbeddedHeadersSplitUnlessEscaped() {
        let pasted = "[2026-05-10 08:00:00] one\nbody1\n\n[2026-05-11 09:00:00] two\nbody2"
        XCTAssertEqual(JournalParser.parseEntries(pasted).count, 2, "a pasted body is two entries")
        XCTAssertTrue(JournalParser.parseEntries("just prose\nno headers").isEmpty)

        // The escape the composer applies, line by line: `\[` is no longer a header.
        let escaped = pasted.components(separatedBy: "\n")
            .map { JournalParser.parseEntries($0).count == 1 ? "\\" + $0 : $0 }
            .joined(separator: "\n")
        XCTAssertTrue(JournalParser.parseEntries(escaped).isEmpty, "escaped headers are body text")

        let parsed = JournalParser.parseEntries("[2026-05-12 07:00:00] kept\n" + escaped + "\n")
        XCTAssertEqual(parsed.count, 1, "one draft stays one entry")
        let rendered = JournalParser.renderEntries(preamble: "", entries: parsed)
        XCTAssertEqual(JournalParser.parseEntries(rendered).map(\.raw), parsed.map(\.raw),
                       "an escaped body round-trips unchanged")
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

    func testPlainTermsSkipTheTimestampHeader() {
        // "2025" used to match every entry written that year, via entry.raw.
        let year = SearchQuery.parse("2025")
        XCTAssertFalse(year.matches(entry("2025-06-01", "Morning", "nothing about the year here")))
        XCTAssertTrue(year.matches(entry("2026-01-01", "", "back in 2025 I moved")), "body")
        XCTAssertTrue(year.matches(entry("2026-01-01", "Trip 2025", "body")), "title")
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

    func testZeroPaddedAndHugeOrderedNumbers() {
        XCTAssertEqual(ListContinuation.action(for: "007. item"), .continueList(prefix: "8. "))
        // The prefix is measured from the match, not re-rendered from the Int.
        XCTAssertEqual(ListContinuation.action(for: "007. "), .endList(prefixLength: 5))
        XCTAssertEqual(ListContinuation.action(for: "  007) "), .endList(prefixLength: 7))
        XCTAssertEqual(ListContinuation.action(for: "18446744073709551615. item"),
                       .continueList(prefix: "18446744073709551615. "), "UInt64.max must not overflow")
    }

    func testCRLFLinesBehaveLikeLFOnes() {
        XCTAssertEqual(ListContinuation.action(for: "- milk\r\n"), .continueList(prefix: "- "))
        XCTAssertEqual(ListContinuation.action(for: "- \r\n"), .endList(prefixLength: 2))
        XCTAssertEqual(ListContinuation.action(for: "- [ ] \r\n"), .endList(prefixLength: 6))
    }

    func testPlainProseIsUntouched() {
        XCTAssertEqual(ListContinuation.action(for: "just a sentence - with a dash"), .none)
        XCTAssertEqual(ListContinuation.action(for: ""), .none)
    }
}
