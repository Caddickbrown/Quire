//
//  ParserChecks.swift
//  Standalone verification that the Swift JournalParser port matches the jnl Go
//  backend's semantics. Mirrors cases in ~/Code/jnl/main_test.go.
//
//  Run:  swiftc Nook/Models/Entry.swift Nook/Models/JournalParser.swift \
//              Tests/ParserChecks.swift -o /tmp/parserchecks && /tmp/parserchecks
//

import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ok  \(msg)") }
    else { print("  FAIL \(msg)"); failures += 1 }
}

// parseEntries basic fields
do {
    let e = JournalParser.parseEntries("[2026-05-10 08:00:00] A title\nfirst line\nsecond line\n")
    check(e.count == 1, "parse: one entry")
    check(e.first?.date == "2026-05-10", "parse: date")
    check(e.first?.ts == "2026-05-10 08:00:00", "parse: ts")
    check(e.first?.suffix == "A title", "parse: suffix")
    check(e.first?.body == "first line\nsecond line", "parse: body")
}

// multiple + preamble dropped
do {
    let e = JournalParser.parseEntries("orphan line\n\n[2026-05-10 08:00:00] one\nbody1\n\n[2026-05-11 09:00:00] two\nbody2\n")
    check(e.count == 2, "parse: two entries, preamble dropped")
    check(e[0].suffix == "one" && e[1].suffix == "two", "parse: suffixes")
}

// MediaLinks.renaming (HEIC -> JPEG relinking)
do {
    let text = "[2026-09-29 08:00:00] Walk\n![](assets/AB.heic)\nand ![x](assets/AB.heic) again\n![](assets/ABC.heic)"
    let out = MediaLinks.renaming(text, from: "AB.heic", to: "AB.jpg")
    check(out == "[2026-09-29 08:00:00] Walk\n![](assets/AB.jpg)\nand ![x](assets/AB.jpg) again\n![](assets/ABC.heic)",
          "renaming: every link to that file, and only that file")
    check(MediaLinks.renaming("no media here", from: "AB.heic", to: "AB.jpg") == nil, "renaming: nil when nothing links")
}

// leadingPreamble
do {
    check(JournalParser.leadingPreamble("[2026-05-10 08:00:00] x\nbody\n") == "", "preamble: none")
    check(JournalParser.leadingPreamble("\n\n[2026-05-10 08:00:00] x\n") == "", "preamble: blank only")
    check(JournalParser.leadingPreamble("loose note\n\n[2026-05-10 08:00:00] x\n") == "loose note", "preamble: present")
    check(JournalParser.leadingPreamble("a\nb\n[2026-05-10 08:00:00] x\n") == "a\nb", "preamble: multiline")
    check(JournalParser.leadingPreamble("just text\nmore text\n") == "just text\nmore text", "preamble: no headers")
}

// sortedByTimestamp orders oldest-first, stable, input untouched
do {
    let input = [
        Entry(date: "", ts: "2026-05-20 09:00:00", suffix: "c", body: "", raw: ""),
        Entry(date: "", ts: "2026-05-10 08:00:00", suffix: "a", body: "", raw: ""),
        Entry(date: "", ts: "2026-05-15 12:30:00", suffix: "b", body: "", raw: ""),
    ]
    let got = JournalParser.sortedByTimestamp(input)
    check(got.map(\.suffix) == ["a", "b", "c"], "sort: oldest first")
    check(input[0].suffix == "c", "sort: input untouched")

    let ties = [
        Entry(date: "", ts: "2026-05-10 08:00:00", suffix: "first", body: "", raw: ""),
        Entry(date: "", ts: "2026-05-10 08:00:00", suffix: "second", body: "", raw: ""),
        Entry(date: "", ts: "2026-05-10 08:00:00", suffix: "third", body: "", raw: ""),
    ]
    check(JournalParser.sortedByTimestamp(ties).map(\.suffix) == ["first", "second", "third"], "sort: stable on ties")
}

// renderEntries preserves preamble (mirrors jnl rebuildInbox test)
do {
    let e = Entry(date: "2026-05-10", ts: "2026-05-10 08:00:00", suffix: "a",
                  body: "body", raw: "[2026-05-10 08:00:00] a\nbody")
    let got = JournalParser.renderEntries(preamble: "loose note", entries: [e])
    check(got == "loose note\n\n[2026-05-10 08:00:00] a\nbody\n", "render: preamble preserved")
    check(JournalParser.renderEntries(preamble: "", entries: []) == "", "render: empty clears")
}

// round-trip stability: parse → render → parse yields identical entries
do {
    let src = "loose\n\n[2026-05-20 09:00:00] later\nB1\n\n[2026-05-10 08:00:00] earlier\nB2\n"
    let once = JournalParser.parseEntries(src)
    let rendered = JournalParser.renderEntries(preamble: JournalParser.leadingPreamble(src), entries: once)
    let twice = JournalParser.parseEntries(rendered)
    check(once.map(\.raw) == twice.map(\.raw), "roundtrip: parse→render→parse stable")
}

// tags: whole-token extraction
do {
    let tags = JournalParser.splitTags("real @work item and @health-check not @1bad")
    check(tags == ["@work", "@health-check"], "tags: whole tokens, leading-letter rule")
}

// SearchQuery: tokenizing, operators, matching
do {
    let tokens = SearchQuery.tokenize(#"plain "two words" tag:work"#)
    check(tokens == ["plain", "two words", "tag:work"], "search: quoted phrases tokenize whole")

    let q = SearchQuery.parse(#"coffee tag:Work before:2026-03 after:2025 has:image is:starred"#)
    check(q.terms == ["coffee"], "search: plain term")
    check(q.tags == ["@work"], "search: tag lowercased, @ added")
    check(q.before == "2026-03" && q.after == "2025", "search: date bounds")
    check(q.has == ["image"] && q.starred, "search: has/is clauses")
    check(SearchQuery.parse("").isEmpty, "search: empty query is empty")
    check(!SearchQuery.isPartialDate("26-03"), "search: bad partial date rejected")

    func entry(_ date: String, _ suffix: String, _ body: String) -> Entry {
        let ts = date + " 08:00:00"
        let raw = suffix.isEmpty ? "[\(ts)]\n\(body)" : "[\(ts)] \(suffix)\n\(body)"
        return Entry(date: date, ts: ts, suffix: suffix, body: body, raw: raw)
    }
    let starredHit = entry("2026-02-10", "Morning *", "coffee @work ![](assets/a.png)")
    check(q.matches(starredHit), "search: all clauses match")
    check(!q.matches(entry("2026-02-10", "Morning *", "coffee @work")), "search: has:image requires image")
    check(!q.matches(entry("2026-03-01", "Morning *", "coffee @work ![](assets/a.png)")), "search: before: excludes")
    check(!q.matches(entry("2024-12-31", "Morning *", "coffee @work ![](assets/a.png)")), "search: after: excludes")

    let phrase = SearchQuery.parse(#""exact phrase""#)
    check(phrase.matches(entry("2026-01-01", "", "an exact phrase here")), "search: phrase matches")
    check(!phrase.matches(entry("2026-01-01", "", "exact other phrase")), "search: phrase is contiguous")

    // after: includes the bound itself (prefix match)
    let after = SearchQuery.parse("after:2026-03")
    check(after.matches(entry("2026-03-01", "", "x")), "search: after: inclusive of its own month")
}

// ListContinuation: what ↩ does at the end of a list line
do {
    check(ListContinuation.action(for: "- milk") == .continueList(prefix: "- "), "lists: bullet continues")
    check(ListContinuation.action(for: "1. first") == .continueList(prefix: "2. "), "lists: ordered increments")
    check(ListContinuation.action(for: "- [x] done") == .continueList(prefix: "- [ ] "), "lists: next checkbox unchecked")
    check(ListContinuation.action(for: "- ") == .endList(prefixLength: 2), "lists: empty item ends the list")
    check(ListContinuation.action(for: "plain prose") == .none, "lists: prose untouched")
}

// normalizePunctuation: jnl cleanup's punctuation pass, media links untouched
do {
    check(JournalParser.normalizePunctuation("wait... what") == "wait\u{2026} what",
          "punctuation: ... becomes an ellipsis")
    check(JournalParser.normalizePunctuation("\u{2019}tis \u{201C}quoted\u{201D}") == "'tis \"quoted\"",
          "punctuation: curly quotes straighten")
    check(JournalParser.normalizePunctuation("see... ![dots](assets/a...b.png) end...") ==
          "see\u{2026} ![dots](assets/a...b.png) end\u{2026}",
          "punctuation: link targets are never rewritten")
    check(JournalParser.normalizePunctuation("![alt...](a.png)") == "![alt...](a.png)",
          "punctuation: alt text inside a link is untouched too")
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
