//
//  main.swift
//  wander (terminal build)
//
//  The Linux — and any-terminal — Wander. Same folder, same jnl markdown, same
//  three pages; the almanac look carried over in rules, small caps and one
//  terracotta accent. Writing happens in $EDITOR, as it does in jnl.
//
//  Keys: j/k move · tab page · / search · n new · d draft · e edit
//        f file · s star · r reload · q quit
//

import Foundation
import WanderCore

// MARK: - State

struct Session {
    var library: JournalLibrary
    var entries: [Entry] = []
    var page: Page = .journal
    var query = ""
    var searching = false
    var selected = 0
    var scroll = 0
    var status = ""

    init(library: JournalLibrary) {
        self.library = library
        reload()
    }

    mutating func reload() {
        entries = library.load()
        clampSelection()
    }

    var visible: [Entry] {
        let matching = entries.filter { JournalIndex.matches($0, query: query) }
        switch page {
        case .journal: return matching.filter { !library.isUnfiled($0) }
        case .inbox:   return matching.filter { library.isUnfiled($0) }
        case .starred: return matching.filter(\.isStarred)
        }
    }

    var current: Entry? {
        let list = visible
        guard list.indices.contains(selected) else { return nil }
        return list[selected]
    }

    mutating func clampSelection() {
        let count = visible.count
        selected = count == 0 ? 0 : min(max(selected, 0), count - 1)
        scroll = 0
    }

    mutating func move(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selected = min(max(selected + delta, 0), count - 1)
        scroll = 0
    }

    mutating func turn(_ delta: Int) {
        let pages = Page.allCases
        let index = pages.firstIndex(of: page) ?? 0
        page = pages[(index + delta + pages.count) % pages.count]
        clampSelection()
    }
}

// MARK: - Text

enum Wrap {
    /// Word-wrap to a column width, keeping blank lines.
    static func lines(_ text: String, width: Int) -> [String] {
        guard width > 8 else { return [text] }
        var out: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            if paragraph.isEmpty { out.append(""); continue }
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if candidate.count <= width {
                    line = candidate
                } else {
                    if !line.isEmpty { out.append(line) }
                    line = String(word)
                }
            }
            out.append(line)
        }
        return out
    }

    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
    }

    static func trim(_ s: String, _ width: Int) -> String {
        s.count <= width ? s : String(s.prefix(max(0, width - 1))) + "\u{2026}"
    }
}

/// The markdown styling, in ANSI: the same idea as the app's — structure shows,
/// markers recede.
enum Style {
    private static let inlineBold = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let inlineItalic = try! NSRegularExpression(pattern: #"(?<![*\w])\*([^*\n]+?)\*(?![*\w])"#)
    private static let inlineCode = try! NSRegularExpression(pattern: "`([^`\n]+)`")
    private static let tag = try! NSRegularExpression(pattern: #"@[a-zA-Z][a-zA-Z0-9_-]*"#)

    static func line(_ raw: String) -> String {
        var text = raw

        if let hashes = text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            let marks = String(text[hashes]).trimmingCharacters(in: .whitespaces)
            let rest = String(text[hashes.upperBound...])
            return Ink.dim + Ink.rule + marks + Ink.reset + " " + Ink.bold + inline(rest) + Ink.reset
        }
        if text.hasPrefix(">") {
            let rest = text.dropFirst().trimmingCharacters(in: .whitespaces)
            return Ink.dim + Ink.rule + ">" + Ink.reset + " " + Ink.italic + Ink.muted + rest + Ink.reset
        }
        if let bullet = text.range(of: #"^\s*([-*+]|\d{1,3}\.)\s"#, options: .regularExpression) {
            let marker = String(text[bullet])
            let rest = String(text[bullet.upperBound...])
            return Ink.accent + marker + Ink.reset + inline(rest)
        }
        if text.range(of: #"^\s*([-*_])(\s*\1){2,}\s*$"#, options: .regularExpression) != nil {
            return Ink.rule + String(repeating: "\u{2500}", count: min(text.count * 3, 40)) + Ink.reset
        }
        text = inline(text)
        return text
    }

    private static func inline(_ s: String) -> String {
        var out = s
        out = replace(inlineBold, in: out) { Ink.bold + $0 + Ink.reset }
        out = replace(inlineItalic, in: out) { Ink.italic + $0 + Ink.reset }
        out = replace(inlineCode, in: out) { Ink.reverse + " " + $0 + " " + Ink.reset }
        out = replaceWhole(tag, in: out) { Ink.accent + $0 + Ink.reset }
        return out
    }

    private static func replace(_ regex: NSRegularExpression, in s: String,
                                _ transform: (String) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += transform(ns.substring(with: match.range(at: 1)))
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func replaceWhole(_ regex: NSRegularExpression, in s: String,
                                     _ transform: (String) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += transform(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}

// MARK: - Screen

struct Screen {
    static let indexWidth = 34

    static func draw(_ session: Session) {
        let (rows, columns) = Term.size
        var out = "\u{1B}[2J\u{1B}[H"

        out += masthead(session, width: columns) + "\n"
        out += Ink.rule + String(repeating: "\u{2501}", count: columns) + Ink.reset + "\n"

        let bodyRows = max(3, rows - 4)
        let indexLines = index(session, rows: bodyRows)
        let readerWidth = max(20, columns - indexWidth - 3)
        let readerLines = reader(session, width: readerWidth, rows: bodyRows)

        for row in 0..<bodyRows {
            let left = row < indexLines.count ? indexLines[row] : Cell(plain: "", styled: "")
            let right = row < readerLines.count ? readerLines[row] : ""
            out += left.padded(to: indexWidth) + Ink.rule + " \u{2502} " + Ink.reset + right + "\n"
        }

        out += Ink.rule + String(repeating: "\u{2500}", count: columns) + Ink.reset + "\n"
        out += status(session, width: columns)
        Term.write(out)
    }

    private static func masthead(_ session: Session, width: Int) -> String {
        var left = Ink.bold + "wander" + Ink.reset + "  "
        let ordered = [session.page] + Page.allCases.filter { $0 != session.page }
        for page in ordered {
            var label = page.label.uppercased()
            if page == .inbox {
                let count = session.entries.filter(session.library.isUnfiled).count
                if count > 0 { label += " \(count)" }
            }
            left += (page == session.page ? Ink.accent : Ink.muted) + label + Ink.reset + "  "
        }
        let right = Ink.muted + Formats.longDay.string(from: Date()).uppercased() + Ink.reset
        let plainLeft = "wander  " + ordered.map { page -> String in
            page == .inbox ? "\(page.label.uppercased()) " : page.label.uppercased() + "  "
        }.joined()
        let gap = max(1, width - plainLeft.count - Formats.longDay.string(from: Date()).count - 2)
        return left + String(repeating: " ", count: gap) + right
    }

    /// A rendered line plus the text without its escape codes — column widths
    /// have to be measured on what is actually visible, or the divider frays.
    struct Cell {
        let plain: String
        let styled: String

        func padded(to width: Int) -> String {
            let short = plain.count >= width
                ? String(plain.prefix(width))
                : plain + String(repeating: " ", count: width - plain.count)
            return plain.count >= width ? short : styled + String(repeating: " ", count: width - plain.count)
        }
    }

    private static func index(_ session: Session, rows: Int) -> [Cell] {
        var lines: [Cell] = []
        let list = session.visible
        let width = indexWidth

        let title = session.page.label
        let ruleWidth = max(0, width - title.count - 3)
        lines.append(Cell(plain: title.uppercased() + "  " + String(repeating: "\u{2500}", count: ruleWidth),
                          styled: Ink.smallCaps(title) + "  " + Ink.rule
                                + String(repeating: "\u{2500}", count: ruleWidth) + Ink.reset))

        guard !list.isEmpty else {
            lines.append(Cell(plain: "  nothing here yet",
                              styled: Ink.muted + Ink.italic + "  nothing here yet" + Ink.reset))
            return lines
        }

        // Keep the selection on screen: each entry takes two lines.
        let capacity = max(1, (rows - 1) / 2)
        let firstShown = max(0, min(session.selected - capacity / 2, max(0, list.count - capacity)))

        for offset in 0..<capacity {
            let position = firstShown + offset
            guard list.indices.contains(position) else { break }
            let entry = list[position]
            let chosen = position == session.selected
            let title = Wrap.trim(entry.preview.isEmpty ? "Untitled" : entry.preview, width - 3)
            let bar = chosen ? "\u{258C}" : " "
            lines.append(Cell(
                plain: bar + " " + title,
                styled: (chosen ? Ink.accent + bar + Ink.reset : bar) + " "
                      + (chosen ? Ink.bold : "") + title + Ink.reset))

            let day = entry.createdDate.map { Formats.shortDay.string(from: $0) } ?? entry.date
            var meta = "\(day) · \(entry.wordCount) words"
            if entry.isStarred { meta += " \u{2731}" }
            let trimmed = Wrap.trim(meta.uppercased(), width - 3)
            lines.append(Cell(plain: "  " + trimmed,
                              styled: "  " + Ink.muted + trimmed + Ink.reset))
        }
        return lines
    }

    private static func reader(_ session: Session, width: Int, rows: Int) -> [String] {
        guard let entry = session.current else {
            return [Ink.muted + Ink.italic + "Nothing open. Press n to start an entry." + Ink.reset]
        }
        var lines: [String] = []
        let title = entry.displayTitle.isEmpty ? "Untitled" : entry.displayTitle
        lines += Wrap.lines(title, width: width).map { Ink.bold + $0 + Ink.reset }

        var dateline: [String] = []
        if let date = entry.createdDate {
            dateline.append(Formats.longDay.string(from: date))
            dateline.append(Formats.clock.string(from: date))
        }
        if session.library.isUnfiled(entry) { dateline.append("draft") }
        if entry.isStarred { dateline.append("starred") }
        dateline += entry.tags.prefix(4)
        lines.append(Ink.smallCaps(dateline.joined(separator: " · ")))
        lines.append(Ink.rule + String(repeating: "\u{2500}", count: width) + Ink.reset)
        lines.append("")

        for line in Wrap.lines(entry.body, width: width) {
            lines.append(line.isEmpty ? "" : Style.line(line))
        }

        let start = min(session.scroll, max(0, lines.count - 1))
        return Array(lines.dropFirst(start).prefix(rows))
    }

    private static func status(_ session: Session, width: Int) -> String {
        if session.searching {
            return Ink.accent + "/" + Ink.reset + session.query + Ink.accent + "\u{2588}" + Ink.reset
        }
        if !session.status.isEmpty {
            return Ink.accent + Wrap.trim(session.status, width) + Ink.reset
        }
        let keys = "j/k move · tab page · / find · n new · d draft · e edit · f file · s star · r reload · q quit"
        var line = Ink.muted + Wrap.trim(keys, width) + Ink.reset
        if !session.query.isEmpty {
            line = Ink.accent + "find: \(session.query)" + Ink.reset + Ink.muted + "  (esc clears)" + Ink.reset
        }
        return line
    }
}

// MARK: - Editing

enum Editing {
    static var editorCommand: String {
        ProcessInfo.processInfo.environment["VISUAL"]
            ?? ProcessInfo.processInfo.environment["EDITOR"]
            ?? "vi"
    }

    /// Open `text` in $EDITOR and hand back what came out, or nil if unchanged.
    static func edit(_ text: String) -> String? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wander-\(UUID().uuidString).md")
        guard (try? text.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ran = Term.suspended { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "\(editorCommand) \"\(tmp.path)\""]
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }
        guard ran, let edited = try? String(contentsOf: tmp, encoding: .utf8) else { return nil }
        return edited == text ? nil : edited
    }
}

// MARK: - Loop

let base = JournalLibrary.resolveBase(preferred: CommandLine.arguments.dropFirst().first)
let library = JournalLibrary(baseURL: base)
library.ensureFolders()
var session = Session(library: library)

if CommandLine.arguments.contains("--path") {
    print(base.path)
    exit(0)
}
if CommandLine.arguments.contains("--help") {
    print("""
    wander — a journal in jnl markdown

      wander [folder]     open the journal (default $JNL_DIR or ~/Documents/Wander)
      wander --path       print the folder in use
      wander --help       this

    Keys: j/k move · tab page · / find · n new · d draft · e edit
          f file · s star · r reload · q quit
    """)
    exit(0)
}

Term.enterRawMode()
defer { Term.exitRawMode() }

/// Save whatever came back from the editor into `target`, replacing `original`.
func commit(edited: String, original: Entry?, target: URL) {
    let parsed = JournalParser.parseEntries(edited, source: target)
    do {
        if let first = parsed.first {
            // The header line was left intact (or retimed by hand) — take it.
            if let original, original.ts != first.ts { try library.remove(original) }
            for entry in parsed { try library.persist(entry, previous: nil) }
        } else {
            // No header: treat the whole buffer as the body of the entry.
            let body = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            let stamp = original?.ts ?? library.freeStamp(Formats.stamp.string(from: Date()),
                                                          in: target, excluding: nil)
            var head = "[\(stamp)]"
            if let suffix = original?.suffix, !suffix.isEmpty { head += " " + suffix }
            let entry = Entry(date: String(stamp.prefix(10)), ts: stamp,
                              suffix: original?.suffix ?? "", body: body,
                              raw: head + "\n" + body, source: target)
            try library.persist(entry, previous: original)
        }
        session.status = "Saved"
    } catch {
        session.status = "Not saved — \(error.localizedDescription)"
    }
    session.reload()
}

func startEntry(draft: Bool) {
    let stamp = Formats.stamp.string(from: Date())
    let target = draft
        ? library.inboxURL
        : (library.dayFile(for: String(stamp.prefix(10))) ?? library.inboxURL)
    let free = library.freeStamp(stamp, in: target, excluding: nil)
    let template = "[\(free)] \n"
    guard let edited = Editing.edit(template) else {
        session.status = "Nothing written"
        return
    }
    commit(edited: edited, original: nil, target: target)
    session.page = draft ? .inbox : .journal
    session.selected = 0
}

var running = true
while running {
    Screen.draw(session)
    let key = Term.readKey()

    if session.searching {
        switch key {
        case .character(let c):
            session.query.append(c)
        case .backspace:
            if !session.query.isEmpty { session.query.removeLast() }
        case .enter, .escape:
            session.searching = false
            if key == .escape { session.query = "" }
            session.clampSelection()
        default: break
        }
        continue
    }

    session.status = ""
    switch key {
    case .character("q"): running = false
    case .character("j"), .down: session.move(1)
    case .character("k"), .up: session.move(-1)
    case .character("g"): session.selected = 0; session.scroll = 0
    case .character("G"): session.selected = max(0, session.visible.count - 1); session.scroll = 0
    case .tab, .right: session.turn(1)
    case .left: session.turn(-1)
    case .character(" "): session.scroll += 10
    case .character("b"): session.scroll = max(0, session.scroll - 10)
    case .character("/"): session.searching = true; session.query = ""
    case .escape: session.query = ""; session.clampSelection()
    case .character("r"): session.reload(); session.status = "Reloaded"
    case .character("n"): startEntry(draft: false)
    case .character("d"): startEntry(draft: true)
    case .character("e"):
        guard let entry = session.current, let source = entry.source else { break }
        if let edited = Editing.edit(entry.raw) {
            commit(edited: edited, original: entry, target: source)
        }
    case .character("s"):
        guard let entry = session.current else { break }
        let flipped = entry.revised(title: entry.displayTitle, body: entry.body,
                                    starred: !entry.isStarred)
        _ = try? library.persist(flipped, previous: entry)
        session.reload()
        session.status = flipped.isStarred ? "Starred" : "Unstarred"
    case .character("f"):
        guard let entry = session.current else { break }
        let unfiled = library.isUnfiled(entry)
        guard let target = unfiled ? library.dayFile(for: entry.date) : library.inboxURL else { break }
        let stamp = library.freeStamp(entry.ts, in: target, excluding: entry)
        var head = "[\(stamp)]"
        if !entry.suffix.isEmpty { head += " " + entry.suffix }
        let moved = Entry(date: String(stamp.prefix(10)), ts: stamp, suffix: entry.suffix,
                          body: entry.body,
                          raw: entry.body.isEmpty ? head : head + "\n" + entry.body,
                          source: target)
        do {
            try library.remove(entry)
            try library.persist(moved, previous: nil)
            session.status = unfiled ? "Filed" : "Returned to the inbox"
        } catch {
            session.status = "Could not move it — \(error.localizedDescription)"
        }
        session.reload()
    default: break
    }
}

Term.exitRawMode()
