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

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
