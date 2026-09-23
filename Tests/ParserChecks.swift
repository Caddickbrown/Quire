//
//  ParserChecks.swift
//  Standalone verification that the Swift JournalParser port matches the jnl Go
//  backend's semantics. Mirrors cases in ~/Code/jnl/main_test.go.
//
//  Run:  make check  — which compiles this file against the pure model sources
//  (the list of them lives in the Makefile's `check` target; keep the two in
//  step when a model file is added). NookTests.swift covers the same ground
//  under XCTest; add a case to both.
//

import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ok  \(msg)") }
    else { print("  FAIL \(msg)"); failures += 1 }
}

// star marker is a standalone token, not any trailing "*"
do {
    func titled(_ suffix: String) -> Entry {
        JournalParser.parseEntries("[2026-05-10 08:00:00] \(suffix)\nbody\n").first!
    }
    check(titled("Morning *").isStarred, "star: trailing marker")
    check(titled("*").isStarred, "star: bare marker")
    check(!titled("**bold**").isStarred, "star: markdown bold is not starred")
    check(!titled("2 * 3").isStarred, "star: mid-title asterisk is not a marker")
    check(!titled("").isStarred, "star: empty title")
    check(titled("Morning *").displayTitle == "Morning", "star: marker stripped")
    check(titled("*").displayTitle == "", "star: bare marker strips to empty")
    check(titled("**bold**").displayTitle == "**bold**", "star: bold title kept whole")
    // The editors hold the title as text and toggle through the same helpers
    // the store uses, so a round-trip must land back on the original.
    for title in ["Morning", "**bold**", "", "2 * 3", "  Trailing \n"] {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty)" : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let on = Entry.togglingStarMarker(title)
        check(Entry.hasStarMarker(on), "star: \(name) stars")
        check(titled(on).isStarred, "star: \(name) stars once parsed")
        check(Entry.strippingStarMarker(on) == Entry.strippingStarMarker(title), "star: \(name) keeps its text")
        check(Entry.togglingStarMarker(on) == Entry.strippingStarMarker(title), "star: \(name) round-trips")
    }
    check(!Entry.hasStarMarker("**bold**"), "star helper: bold is not starred")
    check(Entry.strippingStarMarker("**bold**") == "**bold**", "star helper: bold kept whole")
    check(Entry.togglingStarMarker("*") == "", "star helper: bare marker toggles to empty")
}

// isHeaderLine (the per-line check behind the editors' body escaper) and
// MediaLinks.strippingLinks (the importers' re-run identity)
do {
    check(JournalParser.isHeaderLine("[2026-05-10 08:00:00] title"), "header line: with title")
    check(JournalParser.isHeaderLine("[2026-05-10 08:00:00]"), "header line: bare")
    check(!JournalParser.isHeaderLine("\\[2026-05-10 08:00:00] escaped"), "header line: escaped is body")
    check(!JournalParser.isHeaderLine(" [2026-05-10 08:00:00] indented"), "header line: indented is body")
    check(!JournalParser.isHeaderLine("[2026-05-10] no time"), "header line: needs a time")
    check(MediaLinks.strippingLinks("see ![cap](assets/a.png) here") == "see   here", "media: links stripped")
    check(MediaLinks.strippingLinks("plain") == "plain", "media: no links untouched")
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

    // Plain terms search the title and body, never the timestamp header —
    // "2025" used to return every entry written that year.
    let year = SearchQuery.parse("2025")
    check(!year.matches(entry("2025-06-01", "Morning", "nothing about the year here")),
          "search: plain term skips the timestamp header")
    check(year.matches(entry("2026-01-01", "", "back in 2025 I moved")),
          "search: plain term matches the body")
    check(year.matches(entry("2026-01-01", "Trip 2025", "body")),
          "search: plain term matches the title")
}

// Embedded headers: why one editor's text is always one entry. Pasting a day's
// worth of entries into the composer used to be written verbatim, so the next
// parse of inbox.md handed back extra drafts — and every autosave added more.
// JournalStore.makeEntry escapes the embedded headers (the composer offers
// Import instead); these are the parser facts that behaviour rests on.
do {
    let pasted = "[2026-05-10 08:00:00] one\nbody1\n\n[2026-05-11 09:00:00] two\nbody2"
    check(JournalParser.parseEntries(pasted).count == 2, "paste: a pasted body is two entries")
    check(JournalParser.parseEntries("just prose\nno headers").isEmpty, "paste: prose holds no entries")

    // The escape the composer applies, line by line: `\[` is no longer a header.
    let escaped = pasted.components(separatedBy: "\n")
        .map { JournalParser.parseEntries($0).count == 1 ? "\\" + $0 : $0 }
        .joined(separator: "\n")
    check(JournalParser.parseEntries(escaped).isEmpty, "paste: escaped headers are body text")

    let oneDraft = "[2026-05-12 07:00:00] kept\n" + escaped + "\n"
    let parsed = JournalParser.parseEntries(oneDraft)
    check(parsed.count == 1, "paste: one draft stays one entry")
    let rendered = JournalParser.renderEntries(preamble: "", entries: parsed)
    check(JournalParser.parseEntries(rendered).map(\.raw) == parsed.map(\.raw),
          "paste: an escaped body round-trips unchanged")
}

// ListContinuation: what ↩ does at the end of a list line
do {
    check(ListContinuation.action(for: "- milk") == .continueList(prefix: "- "), "lists: bullet continues")
    check(ListContinuation.action(for: "  * two") == .continueList(prefix: "  * "), "lists: indent kept")
    check(ListContinuation.action(for: "1. first") == .continueList(prefix: "2. "), "lists: ordered increments")
    check(ListContinuation.action(for: "  9) nine") == .continueList(prefix: "  10) "), "lists: paren separator kept")
    check(ListContinuation.action(for: "- [x] done") == .continueList(prefix: "- [ ] "), "lists: next checkbox unchecked")
    check(ListContinuation.action(for: "- ") == .endList(prefixLength: 2), "lists: empty item ends the list")
    check(ListContinuation.action(for: "  - ") == .endList(prefixLength: 4), "lists: indent counts toward the prefix")
    check(ListContinuation.action(for: "3. ") == .endList(prefixLength: 3), "lists: empty ordered item ends the list")
    check(ListContinuation.action(for: "- [ ] ") == .endList(prefixLength: 6), "lists: empty checkbox ends the list")
    check(ListContinuation.action(for: "007. item") == .continueList(prefix: "8. "),
          "lists: zero-padded number increments")
    check(ListContinuation.action(for: "007. ") == .endList(prefixLength: 5),
          "lists: zero-padded prefix measured as written")
    check(ListContinuation.action(for: "  007) ") == .endList(prefixLength: 7),
          "lists: indented zero-padded prefix")
    check(ListContinuation.action(for: "9223372036854775807. item")
            == .continueList(prefix: "9223372036854775807. "),
          "lists: Int.max doesn't overflow")
    check(ListContinuation.action(for: "- milk\r\n") == .continueList(prefix: "- "),
          "lists: CRLF line continues")
    check(ListContinuation.action(for: "- \r\n") == .endList(prefixLength: 2),
          "lists: CRLF empty item ends the list")
    check(ListContinuation.action(for: "- [ ] \r\n") == .endList(prefixLength: 6),
          "lists: CRLF empty checkbox ends the list")
    check(ListContinuation.action(for: "plain prose") == .none, "lists: prose untouched")
    check(ListContinuation.action(for: "just a sentence - with a dash") == .none, "lists: mid-line dash isn't a bullet")
    check(ListContinuation.action(for: "") == .none, "lists: empty line untouched")
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

// Entry identity: stable across re-parses, unique among same-second twins.
// The views key rows, the open editor and SwiftUI's own diffing off `id`, so a
// re-parse of unchanged text must produce the same ids — it used to mint a
// fresh UUID per entry per parse.
do {
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
    check(a.map(\.id) == b.map(\.id), "identity: re-parsing the same text gives the same ids")
    check(a == b, "identity: re-parsed entries compare equal")
    check(Set(a.map(\.id)).count == a.count, "identity: same-second twins get distinct ids")
    check(a[0].id == "2026-05-10 08:00:00", "identity: first of a second is the bare timestamp")
    check(a[1].id == "2026-05-10 08:00:00#1", "identity: the twin is suffixed")
    check(a[2].id == "2026-05-10 09:30:00", "identity: a lone entry is the bare timestamp")

    // Store paths splice freshly parsed entries (occurrence 0) into a list, so
    // the renumber has to be idempotent and has to fix a collision.
    let spliced = [a[0], JournalParser.parseEntries("[2026-05-10 08:00:00] replaced").first!, a[2]]
    let fixed = JournalParser.withOccurrences(spliced)
    check(Set(fixed.map(\.id)).count == 3, "identity: renumbering separates a spliced twin")
    check(JournalParser.withOccurrences(a).map(\.id) == a.map(\.id), "identity: renumbering is idempotent")
    check(JournalParser.withOccurrences([]).isEmpty, "identity: renumbering an empty list")

    // Round-tripping through the file format must preserve them too, since the
    // inbox cache hands back a parse of exactly what it wrote.
    let rendered = JournalParser.renderEntries(preamble: "", entries: a)
    check(JournalParser.parseEntries(rendered).map(\.id) == a.map(\.id),
          "identity: ids survive a render/parse round trip")

    // A merged list (Search, Starred, Tags) draws from several files at once.
    // Each pool numbers its own twins, so the bare ids collide across the
    // merge — renumbering the merged list is what the views' source maps key
    // on, and what stops a draft's edit being routed into a day file.
    let draft = JournalParser.parseEntries("[2026-05-10 08:00:00] a draft\nbody")
    let filed = JournalParser.parseEntries("[2026-05-10 08:00:00] a filed entry\nbody")
    check(draft[0].id == filed[0].id, "merge: per-pool ids collide before renumbering")
    let mergedPools = JournalParser.withOccurrences(draft + filed)
    check(Set(mergedPools.map(\.id)).count == 2, "merge: renumbering separates the pools")
    check(mergedPools.map(\.raw) == (draft + filed).map(\.raw), "merge: renumbering preserves order")
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
