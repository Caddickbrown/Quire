//
//  QuireTests.swift
//  QuireTests
//
//  The XCTest home for the pure model layer: jnl parser parity, the search-query
//  grammar, the editor's list-continuation rules and the command menu. The test
//  target compiles the pure model sources directly (no app host), so these run as
//  plain logic tests:
//
//      xcodebuild test -project Quire.xcodeproj -scheme Quire \
//          -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
//

import XCTest

// MARK: - jnl parser parity (mirrors ~/Code/jnl/main_test.go)

final class MonitorThemeRuleTests: XCTestCase {
    /// ⌘K Dark or Light mode leaves a monitor in disguise (hidden mode) as it is.
    func testDarkOrLightKeepsTheMonitorsDisguise() {
        XCTAssertEqual(MonitorThemeRule.afterDarkOrLight("vscode"), "vscode")
        XCTAssertEqual(MonitorThemeRule.afterDarkOrLight("paper"), "phone")
        XCTAssertEqual(MonitorThemeRule.afterDarkOrLight(nil), "phone")
    }
}

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

    /// A bare target may hold balanced brackets, as in the core: the pattern
    /// used to stop at the first `)`, so `image(1).jpg` had no owning entry in
    /// the Media Library.
    func testMediaTargetsMayHoldBalancedBrackets() {
        XCTAssertEqual(MediaLinks.paths(in: "![](assets/2026/09/image(1).jpg)"), ["assets/2026/09/image(1).jpg"])
        XCTAssertEqual(MediaLinks.paths(in: "a ![x](assets/a(1)(2).png \"t\") b ![](assets/plain.jpg) c"),
                       ["assets/a(1)(2).png", "assets/plain.jpg"])
        XCTAssertEqual(MediaLinks.paths(in: "![](<assets/with (space).jpg>)"), ["assets/with (space).jpg"])
        XCTAssertEqual(MediaLinks.strippingLinks("see ![cap](assets/image(1).png) here"), "see   here")
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

    /// The grammar is the core's (14 November): curly and angle quotes quote, a
    /// quoted token is always text, and an operator whose value can't be used
    /// is searched for as text, not dropped.
    func testQuotesAndUnusableOperatorsFollowTheCore() {
        XCTAssertEqual(SearchQuery.tokenize("a \u{201C}two words\u{201D} \u{00AB}trois mots\u{00BB} \u{201E}zwei\u{201C}\tb"),
                       ["a", "two words", "trois mots", "zwei", "b"])
        XCTAssertEqual(SearchQuery.parse("\u{201C}two words\u{201D}").terms, ["two words"])
        let quoted = SearchQuery.parse(#""tag:work" "is:starred""#)
        XCTAssertEqual(quoted.terms, ["tag:work", "is:starred"])
        XCTAssertEqual(quoted.tags, [])
        XCTAssertFalse(quoted.starred)
        let unusable = SearchQuery.parse("before:March has:pdf tag:")
        XCTAssertEqual(unusable.terms, ["before:march", "has:pdf", "tag:"])
        XCTAssertNil(unusable.before)
        XCTAssertEqual(unusable.has, [])
        // And the match is made with the same reading: a quoted operator is
        // looked for as words.
        XCTAssertTrue(quoted.matches(entry("2026-05-10", "", "note tag:work and is:starred")))
        XCTAssertFalse(quoted.matches(entry("2026-05-10", "", "about @work")))
        XCTAssertTrue(unusable.matches(entry("2026-05-10", "", "due before:March has:pdf tag: x")))
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

// MARK: - Widget snapshot and prompts (QuireShared)

final class WidgetSnapshotTests: XCTestCase {
    func testOlderSnapshotStillDecodes() throws {
        // Written by a build from before the redesign: no theme, no day.
        let json = #"{"currentStreak":4,"bestStreak":9,"inboxDrafts":2,"accentRaw":"teal"}"#
        let snap = try JSONDecoder().decode(QuireSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.currentStreak, 4)
        XCTAssertEqual(snap.inboxDrafts, 2)
        XCTAssertNil(snap.themeID)
        XCTAssertNil(snap.day)
        XCTAssertNil(snap.filedToday)
    }

    func testNewFieldsRoundTrip() throws {
        var snap = QuireSnapshot()
        snap.themeID = "marathon"
        snap.day = "2026-10-26"
        snap.filedToday = 2
        snap.wroteToday = true
        snap.onThisDayExcerpt = "Sun on the water."
        let back = try JSONDecoder().decode(QuireSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(back, snap)
    }

    func testDayKeyIsZeroPadded() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 12))!
        XCTAssertEqual(QuireSnapshot.dayKey(date), "2026-03-05")
    }

    func testPromptWalksTheDeckAndWraps() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        let n = QuirePrompts.deck.count
        XCTAssertEqual(QuirePrompts.prompt(on: date, offset: 0), QuirePrompts.deck[1 % n])
        XCTAssertEqual(QuirePrompts.prompt(on: date, offset: n), QuirePrompts.prompt(on: date, offset: 0))
        XCTAssertEqual(QuirePrompts.prompt(on: date, offset: -1), QuirePrompts.deck[0])
    }

    func testOnThisDayExcerptSkipsTitleAndMedia() {
        let titled = Entry(date: "2023-10-26", ts: "2023-10-26 12:30:00", suffix: " Lunch by the canal",
                           body: "![](assets/2023/10/heron.jpg)\nSun on the water.\nMore.", raw: "")
        XCTAssertEqual(JournalStore.excerpt(of: titled), "Sun on the water.")
        // Untitled: the first line is the preview, so the excerpt is the next.
        let untitled = Entry(date: "2023-10-26", ts: "2023-10-26 12:30:00", suffix: "",
                             body: "First line\nSecond line", raw: "")
        XCTAssertEqual(JournalStore.excerpt(of: untitled), "Second line")
    }
}

// MARK: - Attaching media where the caret is

final class MediaLinkTests: XCTestCase {
    func testMediaLinkLandsAtTheCaretAsItsOwnParagraph() {
        XCTAssertEqual(JournalStore.linking("assets/a.jpg", into: "", at: nil), "![](assets/a.jpg)")
        XCTAssertEqual(JournalStore.linking("assets/a.jpg", into: "Hi", at: nil), "Hi\n\n![](assets/a.jpg)")
        // At the very end the caret counts as no caret: appended.
        XCTAssertEqual(JournalStore.linking("assets/a.jpg", into: "Hi", at: 2), "Hi\n\n![](assets/a.jpg)")
        XCTAssertEqual(JournalStore.linking("assets/a.jpg", into: "One\n\nTwo", at: 5), "One\n\n![](assets/a.jpg)\n\nTwo")
        XCTAssertEqual(JournalStore.linking("assets/a.jpg", into: "One two", at: 3), "One\n\n![](assets/a.jpg)\n\n two")
        XCTAssertEqual(JournalStore.linking("assets/a.jpg", into: "One\nTwo", at: 4), "One\n\n![](assets/a.jpg)\n\nTwo")
        XCTAssertEqual(JournalStore.linking("assets/a.jpg", into: "Top", at: 0), "![](assets/a.jpg)\n\nTop")
    }
}

// MARK: - ⌘K

// MARK: - Esc on the monitor

/// Esc steps back: an open entry to the list it came from, a list to Today. The
/// keys themselves live in iOS-only views, so the wiring is read from the source.
final class DeskEscapeTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheHintSaysWhereEscGoes() {
        XCTAssertEqual(DeskEscape.entry.hint, ShortcutHint(key: "⎋", label: "Back"))
        XCTAssertEqual(DeskEscape.list.hint, ShortcutHint(key: "⎋", label: "Today"))
        XCTAssertEqual(DeskEscape.sheet.hint, ShortcutHint(key: "⎋", label: "Close"))
    }

    func testAnOpenEntrySaysBackAndAListSaysToday() throws {
        let hints = try source("Quire/Design/DeskViews.swift")
        let reading = try XCTUnwrap(hints.range(of: "case .reading(_, _, _, _, let isDraft):"))
        let end = try XCTUnwrap(hints.range(of: "// MARK: - Confirmations"))
        XCTAssertLessThan(reading.lowerBound, end.lowerBound, "the hints come first")
        let bar = hints[reading.lowerBound..<end.lowerBound]
        XCTAssertTrue(bar.contains("DeskEscape.entry.hint"), "the open entry's bar")
        XCTAssertFalse(bar.contains("label: \"Today\""), "an open entry no longer says Today")
        XCTAssertTrue(hints.contains("DeskEscape.list.hint"), "a list's bar")
    }

    /// Esc on an open entry closes that page, monitor or not: it doesn't reach for
    /// the root's way home, which would drop the list and its selection.
    func testAnOpenEntryStepsBackRatherThanGoingHome() throws {
        let reader = try source("Quire/Design/ReaderScreen.swift")
        XCTAssertFalse(reader.contains("onBack"), "the reader never jumps to Today")
        XCTAssertTrue(reader.contains("clear: { close() }"), "Esc closes the page")
    }

    /// The list's selection is its own state, kept while a page sits over it; only
    /// losing the monitor clears it.
    func testTheListKeepsItsSelectionUnderAnOpenEntry() throws {
        let keys = try source("Quire/Design/QuireKeys.swift")
        XCTAssertTrue(keys.contains("if !monitor.isConnected { index = nil }"))
        // Beside the list nothing reappears, so the list is asked to show itself again.
        let root = try source("Quire/Design/PhoneRoot.swift")
        XCTAssertTrue(root.contains("onClose: { path.removeAll(); ExternalDisplayModel.shared.relist() }"))
    }
}

final class CommandPaletteTests: XCTestCase {
    typealias Menu = CommandPalette<QuireCommandList>
    typealias Row = CommandRow<QuireCommand>
    private let today = CommandDates.parse("2026-11-06")!

    /// A state with something of everything, as the app builds it from what's on screen.
    private func state(_ change: (inout QuireCommandState) -> Void = { _ in }) -> QuireCommandState {
        var s = QuireCommandState()
        s.counts = ["2026-03-13": 2, "2026-11-05": 1]
        s.today = today
        s.drafts = 2
        s.entries = [.init(id: "d1", title: "Shopping", when: "Fri 6 Nov, 09:00", isDraft: true),
                     .init(id: "e1", title: "The walk to Ely", when: "Thu 5 Nov, 18:30", isStarred: true)]
        s.splits = ["work"]
        s.searches = [.init(name: "Walks", query: "@walk")]
        s.tags = ["@walk", "@work"]
        s.prompt = "What surprised you today?"
        s.themes = [.init(id: "almanac", name: "Almanac"), .init(id: "sepia", name: "Sepia"),
                    .init(id: "cinema", name: "Cinema", dark: true)]
        s.settings.theme = "almanac"
        s.backupFolderSet = true
        change(&s)
        return s
    }

    private func menu(_ s: QuireCommandState) -> Menu { Menu(QuireCommandList(state: s)) }
    private func ids(_ s: QuireCommandState) -> [String] { QuireCommandList(state: s).all.map(\.id) }
    private func everything(_ rows: [Row]) -> [Row] { rows.flatMap { [$0] + $0.underneath } }

    func testNothingDestroysWithoutAWayBackAndDeletesAreRed() {
        let busy = [state(), state { $0.selected = .init(id: "d1", title: "Shopping", when: "", isDraft: true, isOpen: true) },
                    state { $0.composer = .init(title: "A page", saveFailed: true) },
                    state { $0.monitor = .init(); $0.settings.appLock = true; $0.settings.reminder = true
                            $0.settings.weekly = true; $0.settings.goalOn = true; $0.monitor?.dim = true }]
        for s in busy {
            let rows = QuireCommandList(state: s).all
            XCTAssertEqual(CommandSafety.unguarded(rows).map(\.id), [])
            XCTAssertEqual(CommandSafety.unmarked(rows).map(\.id), [])
        }
    }

    func testTheSelectedEntrysActionsComeFirstUnderItsName() {
        let s = state { $0.selected = .init(id: "e1", title: "The walk to Ely", when: "", isStarred: true) }
        let m = menu(s)
        XCTAssertEqual(m.sections.first?.title, "“The walk to Ely”")
        XCTAssertEqual(m.sections.first?.rows.map(\.id),
                       ["entry.open", "entry.edit", "entry.star", "entry.unfile", "entry.retime", "entry.delete"])
        XCTAssertEqual(m.lit?.id, "entry.open")
        // Starred, so the toggle offers to take it off and says where it is.
        let star = m.rows.first { $0.id == "entry.star" }
        XCTAssertEqual(star?.title, "Unstar")
        XCTAssertEqual(star?.state, "Starred")
        XCTAssertEqual(star?.step, .run(.entry(.unstar, "e1")))
    }

    func testADraftFilesAndAnOpenPageCloses() {
        let s = state { $0.selected = .init(id: "d1", title: "Shopping", when: "", isDraft: true, isOpen: true) }
        let rows = QuireCommandList(state: s).all.filter { $0.context != nil }.map(\.id)
        XCTAssertEqual(rows, ["entry.edit", "entry.star", "entry.file", "entry.retime", "entry.delete", "entry.close"])
    }

    func testDeleteAsksInTheMenuThenDeletes() {
        var m = menu(state { $0.selected = .init(id: "e1", title: "The walk", when: "") })
        m.type("delete")
        XCTAssertEqual(m.lit?.id, "entry.delete")
        XCTAssertTrue(m.lit?.destructive ?? false)
        XCTAssertEqual(m.press(.enter), .stay)
        XCTAssertEqual(m.prompt, "Delete “The walk”? Esc keeps it.")
        var kept = m
        XCTAssertEqual(kept.press(.esc), .stay)
        XCTAssertEqual(kept.depth, 0)
        XCTAssertEqual(m.press(.enter), .run(.entry(.delete, "e1")))
    }

    func testThePageBeingWrittenHasItsOwnCommandsAndHidesTheList() {
        let s = state {
            $0.selected = .init(id: "e1", title: "The walk", when: "")
            $0.composer = .init(title: "A page", isDraft: true, recording: true)
        }
        let m = menu(s)
        XCTAssertEqual(m.sections.first?.title, "“A page”")
        let mine = m.sections.first?.rows.map(\.id) ?? []
        XCTAssertEqual(Array(mine.prefix(3)), ["composer.finish", "composer.save", "composer.retime"])
        XCTAssertTrue(mine.contains("composer.photoLibrary"))
        XCTAssertTrue(mine.contains("composer.discard"))
        XCTAssertFalse(ids(s).contains("entry.edit"), "the row beneath isn't what's being worked on")
        XCTAssertEqual(m.rows.first { $0.id == "composer.voice" }?.title, "Stop recording")
        XCTAssertTrue(QuireCommand.composer(.star).staysOverSheets, "done in the composer, which stays open")
        XCTAssertFalse(QuireCommand.inbox.staysOverSheets)
        // A filed entry's page says Done, and can't be discarded.
        let filed = ids(state { $0.composer = .init(isDraft: false) })
        XCTAssertFalse(filed.contains("composer.discard"))
    }

    func testTheMonitorNeverGetsAScreenItCantDraw() {
        let s = state { $0.monitorShows = true; $0.monitor = .init(); $0.composer = .init() }
        let all = ids(s)
        for phoneOnly in ["go.media", "media.kind", "media.find", "composer.photoLibrary", "composer.takePhoto",
                          "composer.video", "composer.file", "settings.page", "export.pdf", "import.dayone"] {
            XCTAssertFalse(all.contains(phoneOnly), phoneOnly)
        }
        XCTAssertTrue(all.contains("go.settings"), "Settings opens on the monitor")
        XCTAssertTrue(all.contains("composer.voice"))
    }

    func testAThemePreviewsAsTheHighlightMovesAndEscPutsItBack() {
        var m = menu(state())
        m.type("theme")
        XCTAssertEqual(m.lit?.id, "theme")
        _ = m.press(.enter)
        XCTAssertEqual(m.lit?.id, "almanac", "the theme in force is lit first")
        _ = m.takeEffects()
        _ = m.press(.down)
        XCTAssertEqual(m.takeEffects(), [.preview(.pref(QuirePrefKey.theme, .string("sepia")))])
        XCTAssertEqual(m.press(.esc), .stay)
        XCTAssertEqual(m.takeEffects(), [.revert(.pref(QuirePrefKey.theme, .string("almanac")))])
        // Chosen, it stays.
        _ = m.press(.enter)
        _ = m.press(.down)
        _ = m.takeEffects()
        XCTAssertEqual(m.press(.enter), .run(.pref(QuirePrefKey.theme, .string("sepia"))))
        XCTAssertEqual(m.takeEffects(), [])
    }

    func testTypingFindsAThemeByNameInAnyOrder() {
        var m = menu(state())
        m.type("sepia theme")
        XCTAssertEqual(m.lit?.title, "Theme: Sepia")
        XCTAssertEqual(m.press(.enter), .run(.pref(QuirePrefKey.theme, .string("sepia"))))
    }

    func testTheMonitorsLooksIncludeTheVSCodeDisguise() {
        let s = state { $0.monitor = .init(paused: true, theme: "phone") }
        var m = menu(s)
        m.type("vs code")
        XCTAssertEqual(m.lit?.step, .run(.pref(QuirePrefKey.monitorTheme, .string("vscode"))))
        let pause = QuireCommandList(state: s).all.first { $0.id == "monitor.pause" }
        XCTAssertEqual(pause?.title, "Resume the monitor")
        XCTAssertEqual(pause?.state, "Paused")
        XCTAssertFalse(ids(state()).contains("monitor.pause"), "no monitor, no monitor commands")
    }

    func testTogglesSayWhichWayTheyGo() {
        let off = QuireCommandList(state: state()).all.first { $0.id == "prompts" }
        XCTAssertEqual(off?.title, "Show writing prompts")
        XCTAssertEqual(off?.step, .run(.pref(QuirePrefKey.prompts, .bool(true))))
        let on = QuireCommandList(state: state { $0.settings.prompts = true }).all.first { $0.id == "prompts" }
        XCTAssertEqual(on?.title, "Stop showing writing prompts")
        XCTAssertEqual(on?.state, "On")
    }

    func testAJumpSaysWhereItLands() {
        var m = menu(state())
        m.type("jump")
        _ = m.press(.enter)
        XCTAssertEqual(m.rows.map(\.title), ["Today", "Yesterday", "A week ago", "A month ago", "A year ago"])
        XCTAssertEqual(m.rows[1].detail, "Thursday 5 November 2026 · 1 entry")
        m.type("14 march")
        XCTAssertEqual(m.lit?.title, "Saturday 14 March 2026 · Nothing that day: opens Friday 13 March 2026")
        XCTAssertEqual(m.press(.enter), .run(.jump("2026-03-13")))

        var nonsense = menu(state())
        nonsense.type("jump")
        _ = nonsense.press(.enter)
        nonsense.type("bananas")
        XCTAssertTrue(nonsense.rows.isEmpty)
        XCTAssertEqual(nonsense.nothing, "That isn't a date. Try 14 March.")
    }

    func testAnEntryOpensByName() {
        var m = menu(state())
        m.type("open an entry")
        XCTAssertEqual(m.lit?.id, "go.entry")
        _ = m.press(.enter)
        m.type("ely")
        XCTAssertEqual(m.lit?.title, "The walk to Ely")
        XCTAssertEqual(m.press(.enter), .run(.openEntry("e1")))
    }

    func testTypedAnswersStayInTheMenu() {
        var line = menu(state())
        line.type("write a line")
        _ = line.press(.enter)
        XCTAssertTrue(line.isAsking)
        line.type("Milk")
        XCTAssertEqual(line.lit?.title, "Save “Milk” to the Inbox")
        XCTAssertEqual(line.press(.enter), .run(.writeLine("Milk")))

        var pin = menu(state())
        pin.type("pin a search")
        _ = pin.press(.enter)
        pin.type("is:starred")
        XCTAssertEqual(pin.press(.enter), .run(.saveSearch("is:starred")))

        var time = menu(state { $0.settings.reminder = true })
        time.type("daily reminder at")
        _ = time.press(.enter)
        time.type("2115")
        XCTAssertEqual(time.lit?.title, "Remind me at 21:15")
        XCTAssertEqual(time.press(.enter), .run(.reminderTime(hour: 21, minute: 15)))
    }

    func testSavedSearchesAndTags() {
        var m = menu(state())
        m.type("walks")
        XCTAssertEqual(m.lit?.title, "Saved search: Walks")
        XCTAssertEqual(m.press(.enter), .run(.searchFor("@walk")))
        var tag = menu(state())
        tag.type("tag work")
        XCTAssertEqual(tag.lit?.step, .run(.searchFor("@work")))
    }

    func testAMacroThatChangesALotAsksFirst() {
        var m = menu(state())
        m.type("file every draft")
        _ = m.press(.enter)
        XCTAssertEqual(m.lit?.title, "File all 2 drafts")
        XCTAssertEqual(m.press(.enter), .run(.macro(.fileAll)))
        var clean = menu(state())
        clean.type("clean up")
        XCTAssertEqual(clean.press(.enter), .run(.macro(.cleanUp)))
    }

    func testEveryPlaceIsOnTheList() {
        let all = ids(state { $0.regularWidth = true; $0.settingsOpen = true })
        for place in ["go.today", "go.inbox", "go.journal", "go.lookBack", "go.search", "go.settings", "go.media",
                      "go.date", "go.entry", "go.random", "go.randomDraft", "journal.split", "journal.starred",
                      "sidebar", "settings.close", "new", "writeLine", "writePrompt", "anotherPrompt"] {
            XCTAssertTrue(all.contains(place), place)
        }
    }

    func testTheSettingsKeysAreTheAppsOwn() {
        XCTAssertEqual(QuirePrefKey.backupInterval, JournalStore.backupIntervalKey)
        XCTAssertEqual(QuirePrefKey.backupKeep, JournalStore.backupKeepKey)
        XCTAssertEqual(QuirePrefKey.reminder, ReminderScheduler.enabledKey)
        XCTAssertEqual(QuirePrefKey.weekly, ResurfacingScheduler.enabledKey)
        XCTAssertEqual(QuirePrefKey.weeklyDay, ResurfacingScheduler.weekdayKey)
        XCTAssertEqual(QuirePrefKey.weeklyHour, ResurfacingScheduler.hourKey)
        XCTAssertEqual(QuirePrefKey.spotlight, SpotlightIndexer.enabledKey)
        XCTAssertEqual(QuirePrefKey.autoTranscribe, JournalStore.autoTranscribeKey)
    }

    func testTheNearestDayWithSomethingFiled() {
        let s = CommandSources(counts: ["2026-01-01": 1, "2026-01-11": 1])
        XCTAssertNil(CommandSources().nearest(to: "2026-01-01"))
        XCTAssertEqual(s.nearest(to: "2026-01-01"), "2026-01-01")
        XCTAssertEqual(s.nearest(to: "2025-12-01"), "2026-01-01")
        XCTAssertEqual(s.nearest(to: "2026-02-01"), "2026-01-11")
        XCTAssertEqual(s.nearest(to: "2026-01-04"), "2026-01-01")
        XCTAssertEqual(s.nearest(to: "2026-01-06"), "2026-01-11", "Equally close: the later one.")
    }

    func testDatesAsTyped() {
        func day(_ text: String) -> String? { CommandDates.parse(text, today: today).map(CommandDates.key) }
        XCTAssertEqual(day("2026-03-14"), "2026-03-14")
        XCTAssertEqual(day("2026-3-4"), "2026-03-04")
        XCTAssertEqual(day("2026-03"), "2026-03-01")
        XCTAssertEqual(day("14/3/2025"), "2025-03-14")
        XCTAssertEqual(day("14/3/25"), "2025-03-14")
        XCTAssertEqual(day("14.3"), "2026-03-14")
        XCTAssertEqual(day("14 March"), "2026-03-14")
        XCTAssertEqual(day("14th mar 2025"), "2025-03-14")
        XCTAssertEqual(day("March 14"), "2026-03-14")
        XCTAssertEqual(day("March 2025"), "2025-03-01")
        // No year: the latest that isn't in the future, today included.
        XCTAssertEqual(day("25 December"), "2025-12-25")
        XCTAssertEqual(day("6/11"), "2026-11-06")
        for nonsense in ["", "14", "march", "bananas", "31 February", "2026-13-01", "32/1", "1 2 3 march"] {
            XCTAssertNil(day(nonsense), nonsense)
        }
    }

    func testTimesAsTyped() {
        func time(_ text: String) -> String? { TypedTime.parse(text).map { "\($0.hour):\($0.minute)" } }
        XCTAssertEqual(time("9"), "9:0")
        XCTAssertEqual(time("14"), "14:0")
        XCTAssertEqual(time("930"), "9:30")
        XCTAssertEqual(time("1430"), "14:30")
        XCTAssertEqual(time("14:30"), "14:30")
        XCTAssertEqual(time("14.30"), "14:30")
        XCTAssertEqual(time("14:"), "14:0")
        XCTAssertEqual(time("0000"), "0:0")
        XCTAssertEqual(time("23:59"), "23:59")
        for nonsense in ["", "24", "2400", "1460", "14:60", "123:4", "14:300", "14:30:00", "abc"] {
            XCTAssertNil(time(nonsense), nonsense)
        }
    }
}

// MARK: - Esc and ⌘.

/// An iPad's keyboard often has no Esc, and iOS never makes ⌘. into one, so ⌘. has
/// to be declared everywhere Esc is.
final class EscapeChordTests: XCTestCase {
    func testAFieldAndTheCatcherHearBoth() {
        XCTAssertEqual(EscapeChord.declared(composing: false), [.escape, .commandPeriod])
    }

    func testMidCompositionBothBelongToTheInputMethod() {
        XCTAssertTrue(EscapeChord.declared(composing: true).isEmpty)
    }

    func testTheChords() {
        XCTAssertEqual(EscapeChord.escape.input, "\u{1B}")
        XCTAssertEqual(EscapeChord.commandPeriod.input, ".")
        XCTAssertTrue(EscapeChord.commandPeriod.command)
    }
}

// MARK: - On this day

final class OnThisDayYearsTests: XCTestCase {
    private typealias Day = (date: String, entries: [String])

    func testEachYearIsOneGroupNewestFirst() {
        let days: [Day] = [("2021-11-07", ["a"]), ("2024-11-07", ["b", "c"]), ("2023-11-07", ["d"])]
        let years = OnThisDayYears.group(days, thisYear: "2026")
        XCTAssertEqual(years.map(\.year), ["2024", "2023", "2021"])
        XCTAssertEqual(years[0].items.map(\.item), ["b", "c"])
    }

    func testEachEntryKeepsTheDayItCameFrom() {
        let years = OnThisDayYears.group([("2024-11-07", ["b"])] as [Day], thisYear: "2026")
        XCTAssertEqual(years[0].items[0].date, "2024-11-07")
    }

    func testTwoDaysInOneYearShareAGroup() {
        let days: [Day] = [("2024-02-29", ["a"]), ("2024-02-28", ["b"])]
        let years = OnThisDayYears.group(days, thisYear: "2026")
        XCTAssertEqual(years.count, 1)
        XCTAssertEqual(years[0].items.map(\.item), ["a", "b"])
    }

    func testAYearSaysHowLongAgoItWas() {
        let years = OnThisDayYears.group([("2025-11-07", ["a"]), ("2023-11-07", ["b"])] as [Day], thisYear: "2026")
        XCTAssertEqual(years[0].ago, "A year ago")
        XCTAssertEqual(years[1].ago, "3 years ago")
    }

    func testAYearWithNoEntriesIsLeftOut() {
        XCTAssertTrue(OnThisDayYears.group([("2024-11-07", [])] as [Day], thisYear: "2026").isEmpty)
    }

    func testALimitKeepsTheFirstOfEachYearAndCountsTheRest() {
        let years = OnThisDayYears.group([("2024-11-07", ["a", "b", "c"])] as [Day], thisYear: "2026", perYear: 2)
        XCTAssertEqual(years[0].items.map(\.item), ["a", "b"])
        XCTAssertEqual(years[0].hidden, 1)
    }

    func testNoLimitKeepsThemAll() {
        let years = OnThisDayYears.group([("2024-11-07", ["a", "b", "c"])] as [Day], thisYear: "2026")
        XCTAssertEqual(years[0].items.count, 3)
        XCTAssertEqual(years[0].hidden, 0)
    }
}

// MARK: - 13 November: hidden mode, the title bar, Settings' macros

final class ThirteenNovemberTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func entry(_ ts: String) -> Entry {
        Entry(date: String(ts.prefix(10)), ts: ts, suffix: "", body: "words", raw: "[\(ts)]\nwords")
    }

    /// Hidden mode's preview shows the header's own seconds, not ":00".
    func testSecondsComeFromTheTimestamp() {
        XCTAssertEqual(entry("2026-11-12 08:12:33").seconds, "33")
        XCTAssertEqual(entry("2026-11-12 08:12:00").seconds, "00")
        XCTAssertEqual(entry("2026-11-12 08:12").seconds, "00")
    }

    /// A long entry's preview is whole up to the limit, and says when it is cut.
    func testExcerptKeepsLongEntriesWhole() {
        let long = String(repeating: "word ", count: 600)   // 3,000 characters
        XCTAssertEqual(Entry.excerpt(long, limit: 12_000), long.trimmingCharacters(in: .whitespaces))
        let cut = Entry.excerpt(long, limit: 100)
        XCTAssertEqual(cut.count, 101)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertEqual(Entry.excerpt("\n  hello \n", limit: 100), "hello")
    }

    func testHiddenModeUsesTheRealSecondsAndTheWeekday() throws {
        let code = try source("Quire/Design/DeskCode.swift")
        XCTAssertFalse(code.contains("row.time + \":00\""), "no made-up seconds")
        XCTAssertTrue(code.contains("row.time + \":\" + row.seconds"))
        XCTAssertTrue(code.contains("headerHint: weekday.string(from: date)"), "an open entry names its day")
        let rows = try source("Quire/Views/ExternalDisplayView.swift")
        XCTAssertFalse(rows.contains("prefix(1500)"), "long previews are no longer cut at 1,500 characters")
    }

    /// A new page starts in the title; ^t must reach the composer from there.
    func testTheTitleFieldDeclaresTheComposerChords() throws {
        let composer = try source("Quire/Design/ComposerScreen.swift")
        let field = try XCTUnwrap(composer.range(of: "final class EscapingTextField: UITextField {"))
        let rest = composer[field.lowerBound...]
        XCTAssertTrue(rest.contains("KeyCommandRouter.chords.map"))
        XCTAssertTrue(rest.contains("wantsPriorityOverSystemBehavior = true"))
    }

    /// The buttons that come and go sit left of the Calendar, in every layout.
    func testTheCalendarComesAfterTheButtonsThatComeAndGo() throws {
        let masthead = try source("Quire/Design/QuireComponents.swift")
        let start = try XCTUnwrap(masthead.range(of: "@ViewBuilder private var masthead: some View {"))
        let end = try XCTUnwrap(masthead.range(of: "private func icon("))
        let body = String(masthead[start.upperBound..<end.lowerBound])
        let lines = body.components(separatedBy: "\n")
        func index(_ needle: String, after: Int) -> Int? {
            lines.indices.first { $0 > after && lines[$0].contains(needle) }
        }
        var from = -1
        var layouts = 0
        while let calendar = index("\"Calendar\", \"calendar\"", after: from) {
            let block = lines[max(0, calendar - 4)..<calendar].joined(separator: "\n")
            let next = lines[calendar..<min(lines.count, calendar + 3)].joined(separator: "\n")
            XCTAssertFalse(next.contains("onMedia") || next.contains("onRandom"), "nothing that comes and goes after the Calendar")
            XCTAssertTrue(block.contains("onRandom"), "Random sits before the Calendar")
            layouts += 1
            from = calendar
        }
        XCTAssertEqual(layouts, 3, "the sidebar, Marathon and plain title bars")
    }

    /// The maintenance macros have a Settings page of their own, each with an icon.
    func testMacrosHaveTheirOwnSettingsPageWithIcons() throws {
        let settings = try source("Quire/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("case looks, reminders, privacy, display, journal, folder, media, macros, maintenance, help"))
        let start = try XCTUnwrap(settings.range(of: "if shows(.macros) {"))
        let end = try XCTUnwrap(settings.range(of: "QLabel(\"Macros\")"))
        let section = String(settings[start.upperBound..<end.lowerBound])
        for name in ["cleanUpButton", "Sort Inbox", "File All Drafts", "File transfer.md", "Merge Conflict Copies", "mergeExSplitButton"] {
            XCTAssertTrue(section.contains(name), "\(name) is a macro")
        }
        XCTAssertFalse(section.contains("{ Text(\""), "every macro has an icon")
        XCTAssertFalse(section.contains("Button(\""), "every macro has an icon")
        let phone = try source("Quire/Design/PhoneSettings.swift")
        XCTAssertTrue(phone.contains("(.macros, \"Macros\""))
    }
}
