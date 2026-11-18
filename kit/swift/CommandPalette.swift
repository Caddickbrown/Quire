import Foundation
#if os(iOS)
import Combine
import SwiftUI
import UIKit
#endif

// MARK: - The command menu
// ⌘K, or "Commands" in the ⋯ menu: type a few words and do anything the app can do. One version of the behaviour
// Pippin, Quire, MiniOffice and BestShot each had their own copy of. An app gives it a `CommandList` (what's on the
// menu), says what each action does, and draws the panel in its own design: this file has the rules and the keys, and
// nothing that shows. `specs/PALETTE.md` is the guide, with the move from 0.5.
//
// The rules:
//   - Esc closes it in one press from the top, and backs out one step from a follow-up step (a pick or a question).
//     ⌘K closes it from anywhere. Either way, a preview is put back.
//   - Its keys go to it and nowhere else. It has a window of its own above sheets and the page, and `CommandKeys.chords`
//     holds the shortcuts an app binds underneath as well as the menu's own.
//   - Esc gives the keyboard back to whatever had it, so a composer gets its cursor back.
//   - It never destroys anything without a way back. A row that would says it `confirms` (the app asks first) or is
//     `undoable` (the app says so with Undo). Destructive rows are drawn red. `CommandSafety` is what an app's tests
//     hold its list to.
//   - It doesn't open over a question. Chosen over a sheet, a row leaves the sheet the way Esc does, so a draft is asked
//     about or kept as usual, and it only runs once the sheet has gone (`CommandGate`). A row marked `keepsSheet`
//     (a composer's Send) runs over the sheet instead, leaving it open (0.6.1).
//   - With nothing typed: recent commands, then what applies to the selected item, then the rest. No cap: it scrolls.
//   - Typing is fuzzy, in any word order, and finds a row by its synonyms as well as its title. Punctuation between
//     words (":", "›", "·", "—") counts as a space, so "theme: dark" finds "Theme: Dark". "…" doesn't: it means a step.
//   - A follow-up choice ("Theme…", "Move to…") or a typed answer ("Rename…") happens in the menu, not in a sheet.
//   - A highlighted row can preview what it does (a theme), and Esc puts back what was there.
//
// The part above `#if os(iOS)` further down is plain Foundation, so it can be tested without an app:
// tests/command_palette_selftest.swift.

/// Fuzzy matching: the letters of each word typed, in order, somewhere in the text. The words can come in any order.
enum CommandMatch {
    /// Punctuation that sits between words in titles ("Theme: Sepia", "Move to › Home", "Status · Review"): a space,
    /// in the typing and in the texts alike, so "theme: sepia" finds the row the way it's drawn. Not "…": it marks a
    /// step, so "tag…" means the step "Tag…" and is matched as typed.
    static let separators: Set<Character> = [":", ";", ",", "›", "‹", "»", "«", "·", "•", "—", "–", "|", "→"]

    /// Lower case, without accents, so "cafe" finds "Café", and with `separators` as spaces.
    static func fold(_ text: String) -> [Character] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
            .map { separators.contains($0) ? " " : $0 }
    }

    /// The letters of `query` in order within `t`. Runs and word starts score higher. Nil when they aren't all there.
    private static func run<S: Sequence>(_ query: S, _ t: [Character]) -> Int? where S.Element == Character {
        var score = 0, at = 0, run = 0
        for ch in query where ch != " " {
            var found = false
            while at < t.count {
                let here = at
                at += 1
                if t[here] == ch {
                    run += 1
                    score += 1 + run * 2 + (here == 0 || t[here - 1] == " " ? 6 : 0)
                    found = true
                    break
                }
                run = 0
            }
            if !found { return nil }
        }
        return score
    }

    private static func scored(_ q: [Character], _ t: [Character]) -> Int? {
        var best = run(q, t)
        let words = q.split(separator: " ")
        if words.count > 1 {
            var sum = 0
            for word in words {
                guard let s = run(word, t) else { return best.map { $0 - t.count / 8 } }
                sum += s
            }
            best = max(best ?? sum, sum)
        }
        return best.map { $0 - t.count / 8 }
    }

    /// Long texts score a little lower. Nil when it doesn't match. Each word typed is matched on its own, so
    /// "sepia theme" finds "Theme: Sepia".
    static func score(_ query: String, _ text: String) -> Int? {
        scored(fold(query), fold(text))
    }

    /// The best match over several texts: the first is the row's own words, the rest its synonyms, which score a
    /// little lower. Each word typed may be found in a different one: "vertical clip" finds Shorts by "vertical".
    static func score(_ query: String, in texts: [String]) -> Int? {
        let q = fold(query)
        let ts = texts.map(fold)
        func penalty(_ i: Int) -> Int { i == 0 ? 0 : 3 }
        var best: Int?
        for (i, t) in ts.enumerated() {
            if let s = scored(q, t) { best = max(best ?? Int.min, s - penalty(i)) }
        }
        let words = q.split(separator: " ")
        guard words.count > 1 else { return best }
        var sum = 0
        for word in words {
            var b: Int?
            for (i, t) in ts.enumerated() {
                if let s = run(word, t) { b = max(b ?? Int.min, s - t.count / 8 - penalty(i)) }
            }
            guard let b else { return best }
            sum += b
        }
        return max(best ?? sum, sum)
    }

    /// What matches, best first; equal scores keep the order they came in.
    static func rank<Item>(_ items: [Item], _ query: String, by text: (Item) -> String) -> [Item] {
        rank(items, query, texts: { [text($0)] })
    }

    /// The same, over each item's texts, with a bonus an item can earn (recent use, the selected item's actions).
    static func rank<Item>(_ items: [Item], _ query: String, texts: (Item) -> [String],
                           bonus: (Item) -> Int = { _ in 0 }) -> [Item] {
        let scored = items.enumerated().compactMap { i, item in
            score(query, in: texts(item)).map { (item, $0 + bonus(item), i) }
        }
        return scored.sorted { ($0.1, $1.2) > ($1.1, $0.2) }.map(\.0)
    }
}

/// One key prompt: the glyph and what it does.
struct CommandHint: Identifiable, Equatable {
    let key: String
    let label: String
    var id: String { key + label }
}

/// One line of the menu.
struct CommandRow<Action: Equatable>: Equatable, Identifiable {
    indirect enum Step: Equatable {
        case run(Action)
        /// A shorter list to choose from, by the name the app knows it by: the app's `rows(stage:)` lists it. Esc closes
        /// the menu from here, as before 0.6; `.pick` is the newer way.
        case open(String)
        /// A follow-up choice inside the menu: "Theme…" then the theme. Esc backs out of it.
        case pick(CommandPick<Action>)
        /// A typed answer inside the menu: "Rename…" then the name.
        case ask(CommandAsk<Action>)
    }

    var id: String
    var title: String
    var detail: String?
    var symbol: String
    var step: Step
    /// What typing is matched against, when it isn't just the title.
    var search: String
    /// The action goes through the app's own confirmation before it destroys anything.
    var confirms: Bool
    /// Other words for it: "vertical" for Shorts, "dark" for a theme. Matched as well as `search`.
    var synonyms: [String]
    /// It removes or overwrites something: drawn red.
    var destructive: Bool
    /// The app offers Undo straight after, as it does everywhere else, so it needn't ask first.
    var undoable: Bool
    /// The selected item this acts on, by name ("“Buy milk”"). Such rows come first, under that name.
    var context: String?
    /// Done while the row is highlighted, so the change shows before it's chosen: a theme.
    var preview: Action?
    /// Puts back what was there before any preview. Read once, at the first preview, so a list rebuilt mid-preview
    /// can't make the previewed value the one put back.
    var revert: Action?
    /// For a toggle, whether it's on now. The title says what choosing it will do.
    var isOn: Bool?
    /// For a toggle, its state in words, as the app wants it shown ("On", "Paused").
    var state: String?
    /// In a pick, the choice in force now: lit first, and drawn with a tick.
    var isCurrent: Bool
    /// It runs over the sheet that's open (a composer's Send, Attach, Save draft) rather than leaving it first, which
    /// is what every other row does. On a pick or a question, its choices and typed answer keep the sheet too.
    var keepsSheet: Bool

    init(_ id: String, _ title: String, detail: String? = nil, symbol: String, step: Step, search: String? = nil,
         confirms: Bool = false, synonyms: [String] = [], destructive: Bool = false, undoable: Bool = false,
         context: String? = nil, preview: Action? = nil, revert: Action? = nil, isCurrent: Bool = false,
         keepsSheet: Bool = false) {
        self.id = id; self.title = title; self.detail = detail; self.symbol = symbol; self.step = step
        self.search = search ?? title
        self.confirms = confirms
        self.synonyms = synonyms
        self.destructive = destructive
        self.undoable = undoable
        self.context = context
        self.preview = preview
        self.revert = revert
        self.isOn = nil
        self.state = nil
        self.isCurrent = isCurrent
        self.keepsSheet = keepsSheet
    }

    /// A setting or mode that flips: its title says which way it will go ("Pause monitor" while showing, "Resume
    /// monitor" while paused), its state says where it is, and either title finds it.
    static func toggle(_ id: String, isOn: Bool, turnOn: String, turnOff: String, states: (on: String, off: String) = ("On", "Off"),
                       detail: String? = nil, symbol: String, action: Action, synonyms: [String] = [],
                       context: String? = nil, keepsSheet: Bool = false) -> CommandRow {
        var row = CommandRow(id, isOn ? turnOff : turnOn, detail: detail, symbol: symbol, step: .run(action),
                             synonyms: [isOn ? turnOn : turnOff] + synonyms, context: context, keepsSheet: keepsSheet)
        row.isOn = isOn
        row.state = isOn ? states.on : states.off
        return row
    }

    /// What typing is matched against: `search` first, then the synonyms.
    var texts: [String] { [search] + synonyms }

    /// It opens a follow-up step rather than doing something.
    var leads: Bool {
        switch step {
        case .run: return false
        case .open, .pick, .ask: return true
        }
    }

    /// Every row under this one, its picks' choices and its questions' suggestions, deepest last.
    var underneath: [CommandRow] {
        switch step {
        case .pick(let p): return p.choices.flatMap { [$0] + $0.underneath }
        case .ask(let a): return a.suggestions.flatMap { [$0] + $0.underneath }
        case .run, .open: return []
        }
    }
}

/// A follow-up choice: "Theme…", "Move to…", "Priority…". The choices are rows, so each can preview, lead on to another
/// step, or be destructive.
struct CommandPick<Action: Equatable>: Equatable {
    /// The grey words in the box: "Which theme?"
    var prompt: String
    var choices: [CommandRow<Action>]
    /// Puts back what was there, if a choice previewed something.
    var revert: Action?
    var nothing: String
    /// Typing at the top finds each choice by name too ("Theme: Sepia"), as its own command.
    var searchable: Bool

    init(prompt: String, choices: [CommandRow<Action>], revert: Action? = nil,
         nothing: String = "Nothing here by that name.", searchable: Bool = true) {
        self.prompt = prompt; self.choices = choices; self.revert = revert; self.nothing = nothing
        self.searchable = searchable
    }
}

/// A typed answer: "Rename…", "Snooze until…", "New project…". What's typed becomes the first row, if `make` takes it,
/// and the suggestions follow, narrowed by the typing.
struct CommandAsk<Action: Equatable>: Equatable {
    var prompt: String
    /// Already in the box: the name being changed.
    var initial: String
    var suggestions: [CommandRow<Action>]
    var symbol: String
    var nothing: String
    /// The first row's title for what's typed: "Rename to “\($0)”".
    var title: (String) -> String
    /// What to do with what's typed, or nil while it isn't usable.
    var make: (String) -> Action?

    init(prompt: String, initial: String = "", suggestions: [CommandRow<Action>] = [], symbol: String = "return",
         nothing: String = "Type, then Return.", title: @escaping (String) -> String,
         make: @escaping (String) -> Action?) {
        self.prompt = prompt; self.initial = initial; self.suggestions = suggestions; self.symbol = symbol
        self.nothing = nothing; self.title = title; self.make = make
    }

    static func == (a: CommandAsk, b: CommandAsk) -> Bool {
        a.prompt == b.prompt && a.initial == b.initial && a.suggestions == b.suggestions && a.symbol == b.symbol
            && a.nothing == b.nothing
    }
}

/// A run of rows under one heading: "Recent", the selected item's name, or the rest.
struct CommandSection<Action: Equatable>: Equatable, Identifiable {
    enum Kind: Equatable { case recent, context, all }
    var kind: Kind
    /// Nil when it's the only section.
    var title: String?
    var rows: [CommandRow<Action>]
    var id: String { "\(kind):\(title ?? "")" }
}

/// What the menu asks the app to do while it's open, rather than when it closes.
enum CommandEffect<Action: Equatable>: Equatable {
    /// The highlighted row's `preview`.
    case preview(Action)
    /// Put back what was there before the first preview.
    case revert(Action)

    var action: Action {
        switch self {
        case .preview(let a), .revert(let a): return a
        }
    }
}

/// The commands chosen lately, newest first, by row id. Kept in UserDefaults, which is the app's own.
struct CommandRecents: Equatable {
    let key: String
    let cap: Int
    let store: UserDefaults

    init(key: String = "kit.commandPalette.recents", cap: Int = 8, store: UserDefaults = .standard) {
        self.key = key; self.cap = cap; self.store = store
    }

    var ids: [String] { store.stringArray(forKey: key) ?? [] }

    func note(_ id: String) {
        var list = ids.filter { $0 != id }
        list.insert(id, at: 0)
        store.set(Array(list.prefix(cap)), forKey: key)
    }

    func clear() { store.removeObject(forKey: key) }

    static func == (a: CommandRecents, b: CommandRecents) -> Bool { a.key == b.key && a.cap == b.cap && a.store === b.store }
}

/// What's on an app's menu, as a value: the app builds one from what it has just now.
protocol CommandList: Equatable {
    associatedtype Action: Equatable
    /// `stage` is nil at the top, or the name from `.open`. `typing` is false for the list before anything's typed,
    /// which can be shorter than all that typing can find.
    func rows(stage: String?, typing: Bool) -> [CommandRow<Action>]
    /// The grey words in the box.
    func prompt(stage: String?) -> String
    /// Said in place of the list when nothing matches.
    func nothing(stage: String?) -> String
}

extension CommandList {
    func nothing(stage: String?) -> String { "Nothing here by that name." }
}

enum CommandPaletteLimit {
    /// How many rows a panel shows before it scrolls. Not a cap on the list (it was, before 0.6).
    static let rows = 10
    /// How many recent commands head the list.
    static let recents = 5
    /// The longest search.
    static let query = 60
    /// The longest typed answer.
    static let answer = 300
}

enum CommandKey: Equatable, CaseIterable { case esc, enter, up, down, tab, backTab, toggle, pageUp, pageDown, first, last }

struct CommandPalette<List: CommandList>: Equatable {
    typealias Key = CommandKey
    typealias Row = CommandRow<List.Action>
    typealias Section = CommandSection<List.Action>
    typealias Effect = CommandEffect<List.Action>

    enum Outcome: Equatable {
        case stay, close
        /// Closed, with this to do.
        case run(List.Action)
    }

    /// One step in: a shorter list, a pick, or a question, with the row that opened it.
    private enum Frame: Equatable {
        case stage(String, Row?)
        case pick(Row, CommandPick<List.Action>)
        case ask(Row, CommandAsk<List.Action>)

        var opener: Row? {
            switch self {
            case .stage(_, let row): return row
            case .pick(let row, _), .ask(let row, _): return row
            }
        }
    }

    /// Where the step before was, to go back to.
    private struct Mark: Equatable {
        var query: String
        var selected: String?
    }

    private(set) var query = ""
    /// The list as it's drawn: under headings with nothing typed, one run of best matches with something typed.
    private(set) var sections: [Section] = []
    /// Every row, in the order drawn.
    private(set) var rows: [Row] = []
    /// The row the keys are on, by id, so the highlight follows the row and not a position: something arriving at the
    /// top can't slide a different row under it.
    private(set) var selected: String?
    /// The preview showing now, if any.
    private(set) var previewing: List.Action?
    /// The row whose action the last `.run` carried, so the host can tell how to run it. Nil until then.
    private(set) var chosen: Row?
    /// The last `.run` is to happen over the open sheet, without leaving it: the chosen row, or the row that opened
    /// its step, said `keepsSheet`.
    var keepsSheet: Bool {
        guard let chosen else { return false }
        return chosen.keepsSheet || frames.contains { $0.opener?.keepsSheet == true }
    }
    private var restore: List.Action?
    /// Which kind of preview `restore` puts back: the pick or step the previewing row belongs to. Arrowing from
    /// "Theme: Sepia" to "Monitor theme: Sepia" changes kind, so the first is put back before the second shows.
    private var restoreKind: String?
    private var effects: [Effect] = []
    private var frames: [Frame] = []
    private var marks: [Mark] = []
    /// Previews wait for the first key: opening the menu changes nothing.
    private var armed = false
    private var list: List
    private var recents: CommandRecents?

    init(_ list: List, recents: CommandRecents? = nil) {
        self.list = list
        self.recents = recents
        relist()
    }

    var lit: Row? { rows.first { $0.id == selected } }

    /// The name from `.open`, if a shorter list of the app's is open.
    var stage: String? {
        for frame in frames.reversed() { if case .stage(let name, _) = frame { return name } }
        return nil
    }

    /// How many steps in: 0 at the top.
    var depth: Int { frames.count }
    /// The row whose step is open, for a heading ("Theme…") and a back button.
    var opener: Row? { frames.last?.opener }
    /// The box holds an answer rather than a search.
    var isAsking: Bool { if case .ask? = frames.last { return true } else { return false } }

    var prompt: String {
        switch frames.last {
        case .pick(_, let p)?: return p.prompt
        case .ask(_, let a)?: return a.prompt
        default: return list.prompt(stage: stage)
        }
    }

    var nothing: String {
        switch frames.last {
        case .pick(_, let p)?: return p.nothing
        case .ask(_, let a)?: return a.nothing
        default: return list.nothing(stage: stage)
        }
    }

    // MARK: typing

    mutating func type(_ text: String) {
        let clean = text.filter { !$0.isNewline && !($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) }
        guard !clean.isEmpty else { return }
        query = String((query + clean).prefix(isAsking ? CommandPaletteLimit.answer : CommandPaletteLimit.query))
        armed = true
        relist()
    }

    /// One letter back. With none left, back out of a step.
    mutating func backspace() {
        if query.isEmpty {
            guard !frames.isEmpty else { return }
            pop()
        } else {
            query.removeLast()
            armed = true
            relist()
        }
    }

    // MARK: following the app

    /// What's there changed while the menu is open. A highlight whose row has gone is dropped rather than moved on, so
    /// a stray Return does nothing. A pick or a question that's open stays as it was opened.
    mutating func refresh(_ list: List) {
        self.list = list
        layOut()
        if !rows.contains(where: { $0.id == selected }) { selected = nil }
        moved()
    }

    // MARK: keys

    mutating func press(_ key: Key) -> Outcome {
        switch key {
        case .esc:
            switch frames.last {
            case .pick?, .ask?:
                pop()
                return .stay
            default:
                cancel()
                return .close
            }
        case .toggle:
            cancel()
            return .close
        case .up, .backTab: move(-1)
        case .down, .tab: move(1)
        case .pageUp: move(-CommandPaletteLimit.rows, wraps: false)
        case .pageDown: move(CommandPaletteLimit.rows, wraps: false)
        case .first: move(-rows.count, wraps: false)
        case .last: move(rows.count, wraps: false)
        case .enter: return enter()
        }
        return .stay
    }

    /// A tap or a click on a row: light it, then go.
    mutating func choose(_ id: String) -> Outcome {
        guard rows.contains(where: { $0.id == id }) else { return .stay }
        selected = id
        armed = true
        moved()
        return enter()
    }

    /// The pointer resting on a row lights it, and previews it.
    mutating func highlight(_ id: String) {
        guard rows.contains(where: { $0.id == id }), id != selected else { return }
        selected = id
        armed = true
        moved()
    }

    /// One step out, as the back button. At the top, it closes.
    mutating func back() -> Outcome {
        guard !frames.isEmpty else {
            cancel()
            return .close
        }
        pop()
        return .stay
    }

    /// Closing without choosing: any preview is put back.
    mutating func cancel() {
        chosen = nil
        guard previewing != nil else { return }
        if let restore { effects.append(.revert(restore)) }
        previewing = nil
        restore = nil
        restoreKind = nil
    }

    /// What to do now for previews, in order. Each call hands them over once.
    mutating func takeEffects() -> [Effect] {
        defer { effects = [] }
        return effects
    }

    private mutating func enter() -> Outcome {
        guard let row = lit else { return .stay }
        switch row.step {
        case .run(let action):
            // Chosen: what's previewing stays.
            previewing = nil
            restore = nil
            restoreKind = nil
            chosen = row
            if !row.destructive && !row.confirms, let recents {
                // A step's choice is remembered as the step, so the list shows "Move to…" rather than one folder.
                // Destructive rows aren't remembered: Return straight after opening must never delete.
                let root = frames.first?.opener
                if let root, !root.destructive { recents.note(root.id) } else if root == nil { recents.note(row.id) }
            }
            return .run(action)
        case .open(let name):
            push(.stage(name, row), query: "")
        case .pick(let pick):
            push(.pick(row, pick), query: "")
        case .ask(let ask):
            push(.ask(row, ask), query: String(ask.initial.prefix(CommandPaletteLimit.answer)))
        }
        return .stay
    }

    private mutating func push(_ frame: Frame, query: String) {
        marks.append(Mark(query: self.query, selected: selected))
        frames.append(frame)
        self.query = query
        armed = true
        layOut()
        if case .pick(_, let p) = frame, let current = p.choices.first(where: \.isCurrent) {
            selected = current.id
        } else {
            selected = rows.first?.id
        }
        moved()
    }

    private mutating func pop() {
        frames.removeLast()
        let mark = marks.removeLast()
        if previewing != nil {
            if let restore { effects.append(.revert(restore)) }
            previewing = nil
            restore = nil
        }
        restoreKind = nil
        query = mark.query
        layOut()
        selected = rows.contains { $0.id == mark.selected } ? mark.selected : rows.first?.id
        moved()
    }

    /// Down the list as it's drawn, wrapping round. With nothing lit, the first row.
    private mutating func move(_ by: Int, wraps: Bool = true) {
        guard !rows.isEmpty else { return }
        armed = true
        if let i = rows.firstIndex(where: { $0.id == selected }) {
            selected = rows[wraps ? (i + by % rows.count + rows.count) % rows.count : max(0, min(rows.count - 1, i + by))].id
        } else {
            selected = rows[0].id
        }
        moved()
    }

    /// The highlight may have moved: preview what's lit now, or put back what was there.
    private mutating func moved() {
        guard armed else { return }
        let want = lit?.preview
        guard want != previewing else { return }
        if let want {
            let kind = previewKind
            if kind != restoreKind {
                // A preview of another kind: put the first back (if it's still showing) and remember this kind's own.
                if previewing != nil, let restore { effects.append(.revert(restore)) }
                restore = nil
                restoreKind = kind
            }
            if restore == nil { restore = lit?.revert ?? stepRevert }
            previewing = want
            effects.append(.preview(want))
        } else {
            if let restore { effects.append(.revert(restore)) }
            previewing = nil
        }
    }

    /// The kind of preview the lit row makes: inside a pick, the pick; at the top, the step a spread choice came from
    /// ("theme" for "theme/sepia"), or the row itself.
    private var previewKind: String? {
        guard let row = lit else { return nil }
        if case .pick(let opener, _)? = frames.last { return opener.id }
        if let slash = row.id.firstIndex(of: "/") { return String(row.id[..<slash]) }
        return row.id
    }

    private var stepRevert: List.Action? {
        for frame in frames.reversed() {
            if case .pick(let row, let p) = frame, let r = p.revert ?? row.revert { return r }
        }
        return nil
    }

    /// Exactly the keys that do something right now.
    var hints: [CommandHint] {
        var out: [CommandHint] = []
        if rows.count > 1 { out.append(.init(key: "↑↓ ⇥", label: "Move")) }
        if lit != nil { out.append(.init(key: "↩", label: "Go")) }
        out.append(.init(key: "Type", label: isAsking ? "To write" : "To find"))
        if !query.isEmpty { out.append(.init(key: "⌫", label: "A letter")) }
        else if !frames.isEmpty { out.append(.init(key: "⌫", label: "Back")) }
        switch frames.last {
        case .pick?, .ask?:
            out.append(.init(key: "⎋", label: "Back"))
            out.append(.init(key: "⌘K", label: "Close"))
        default:
            out.append(.init(key: "⎋ ⌘K", label: "Close"))
        }
        return out
    }

    // MARK: the list

    private mutating func relist() {
        layOut()
        selected = rows.first?.id
        moved()
    }

    private mutating func layOut() {
        sections = listed()
        rows = sections.flatMap(\.rows)
    }

    /// Each pick's choices as commands of their own, for typing at the top: "Theme: Sepia".
    private static func spread(_ pool: [Row]) -> [Row] {
        pool + pool.flatMap { row -> [Row] in
            guard case .pick(let pick) = row.step, pick.searchable else { return [] }
            let base = row.title.hasSuffix("…") ? String(row.title.dropLast()) : row.title
            return pick.choices.compactMap { choice in
                guard case .run = choice.step else { return nil }
                var v = choice
                v.id = row.id + "/" + choice.id
                v.title = base + ": " + choice.title
                v.search = base + " " + choice.search
                v.synonyms = choice.synonyms + row.texts
                v.revert = choice.revert ?? pick.revert ?? row.revert
                v.context = choice.context ?? row.context
                v.destructive = choice.destructive || row.destructive
                v.undoable = choice.undoable || row.undoable
                v.confirms = choice.confirms || row.confirms
                v.keepsSheet = choice.keepsSheet || row.keepsSheet
                return v
            }
        }
    }

    private func listed() -> [Section] {
        let blank = query.allSatisfy { $0 == " " }
        switch frames.last {
        case .pick(_, let pick)?:
            return [Section(kind: .all, title: nil, rows: blank ? pick.choices : CommandMatch.rank(pick.choices, query, texts: \.texts))]
        case .ask(let opener, let ask)?:
            var out: [Row] = []
            let text = query.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, let action = ask.make(text) {
                out.append(Row(opener.id + "#typed", ask.title(text), symbol: ask.symbol, step: .run(action),
                               destructive: opener.destructive, undoable: opener.undoable, context: opener.context,
                               keepsSheet: opener.keepsSheet))
            }
            out += blank || !ask.initial.isEmpty && query == ask.initial
                ? ask.suggestions : CommandMatch.rank(ask.suggestions, query, texts: \.texts)
            return [Section(kind: .all, title: nil, rows: out)]
        default:
            break
        }
        let recent = recents?.ids ?? []
        if !blank {
            let pool = Self.spread(list.rows(stage: stage, typing: true))
            let ranked = CommandMatch.rank(pool, query, texts: \.texts) { row in
                var bonus = row.context == nil ? 0 : 3
                if let i = recent.firstIndex(of: row.id) { bonus += max(0, 6 - i) }
                if row.id.contains("/") { bonus -= 2 }
                return bonus
            }
            return [Section(kind: .all, title: nil, rows: ranked)]
        }
        let pool = list.rows(stage: stage, typing: false)
        guard frames.isEmpty else { return [Section(kind: .all, title: nil, rows: pool)] }
        var out: [Section] = []
        var used = Set<String>()
        if !recent.isEmpty {
            let everything = Self.spread(list.rows(stage: nil, typing: true))
            var found: [Row] = []
            for id in recent where found.count < CommandPaletteLimit.recents {
                if let row = everything.first(where: { $0.id == id }), !row.destructive { found.append(row) }
            }
            if !found.isEmpty {
                out.append(Section(kind: .recent, title: "Recent", rows: found))
                used.formUnion(found.map(\.id))
            }
        }
        var names: [String] = []
        for row in pool { if let c = row.context, !names.contains(c) { names.append(c) } }
        for name in names {
            let these = pool.filter { $0.context == name && !used.contains($0.id) }
            if !these.isEmpty { out.append(Section(kind: .context, title: name, rows: these)) }
            used.formUnion(these.map(\.id))
        }
        let rest = pool.filter { !used.contains($0.id) }
        if !rest.isEmpty { out.append(Section(kind: .all, title: out.isEmpty ? nil : "Commands", rows: rest)) }
        return out
    }
}

// MARK: - The keys, as values

struct CommandMods: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let command = CommandMods(rawValue: 1)
    static let alternate = CommandMods(rawValue: 2)
    static let shift = CommandMods(rawValue: 4)
    static let control = CommandMods(rawValue: 8)
}

enum CommandInput: Hashable, Sendable {
    case esc, up, down, left, right, pageUp, pageDown, home, end
    case text(String)
}

struct CommandChord: Hashable, Sendable {
    var input: CommandInput
    var mods: CommandMods
    init(_ input: CommandInput, _ mods: CommandMods = []) { self.input = input; self.mods = mods }
}

enum CommandKeys {
    /// What a key means to the menu, if anything.
    static func meaning(_ chord: CommandChord) -> CommandKey? {
        switch (chord.input, chord.mods) {
        case (.esc, []): return .esc
        case (.text("."), [.command]): return .esc
        case (.up, []): return .up
        case (.down, []): return .down
        case (.up, [.command]), (.home, []): return .first
        case (.down, [.command]), (.end, []): return .last
        case (.pageUp, []): return .pageUp
        case (.pageDown, []): return .pageDown
        case (.text("\r"), []): return .enter
        case (.text("\t"), []): return .tab
        case (.text("\t"), [.shift]): return .backTab
        case (.text("k"), [.command]): return .toggle
        default: return nil
        }
    }

    /// Everything the menu takes for itself while it's up: its own keys, and any shortcut the page behind could be
    /// listening for. Plain letters aren't here, because they're the typing.
    static let chords: [CommandChord] = {
        var out: [CommandChord] = [.init(.esc), .init(.text("\r")), .init(.text("\t")), .init(.text("\t"), .shift)]
        for arrow: CommandInput in [.up, .down, .left, .right] {
            out += [.init(arrow), .init(arrow, .alternate), .init(arrow, .command)]
        }
        out += [.init(.pageUp), .init(.pageDown), .init(.home), .init(.end)]
        let sets: [CommandMods] = [.command, [.command, .shift], [.command, .alternate], [.command, .alternate, .shift],
                                   [.command, .control], .control]
        for mods in sets {
            for ch in "abcdefghijklmnopqrstuvwxyz0123456789,./;'[]\\-=`" { out.append(.init(.text(String(ch)), mods)) }
        }
        return out
    }()
}

// MARK: - Choosing something over a sheet

enum CommandGate {
    enum Step: Equatable {
        case run
        /// Close the sheet the way Esc does.
        case leave
        case wait
        /// The sheet stayed: it's asking about a draft, and that comes first.
        case drop
    }

    /// How long a sheet gets to go, in seconds.
    static let patience = 1.2

    /// `keepsSheet`: the row runs over the sheet (`CommandRow.keepsSheet`), so there's nothing to wait for.
    static func step(sheetUp: Bool, waited: Double, keepsSheet: Bool = false) -> Step {
        guard sheetUp, !keepsSheet else { return .run }
        if waited == 0 { return .leave }
        return waited < patience ? .wait : .drop
    }
}

// MARK: - Destructive rows

enum CommandSafety {
    private static let words: Set<String> = ["delete", "remove", "clear", "erase", "wipe", "reset", "discard", "trash",
                                             "unsubscribe", "empty", "sign", "log", "overwrite", "replace", "forget",
                                             "destroy", "purge", "drop", "disconnect"]

    private static func sounds(_ text: String) -> Bool {
        let parts = text.lowercased().split { !$0.isLetter }.map(String.init)
        for (i, part) in parts.enumerated() where words.contains(part) {
            // "Log" and "Sign" alone are ordinary words; "log out" and "sign out" aren't.
            if part == "log" || part == "sign" {
                if i + 1 < parts.count, parts[i + 1] == "out" { return true }
                continue
            }
            return true
        }
        return false
    }

    /// The rows and every row under them, in picks and questions.
    private static func all<Action>(_ rows: [CommandRow<Action>]) -> [CommandRow<Action>] {
        rows.flatMap { [$0] + $0.underneath }
    }

    /// Rows that destroy something (by their words, or marked `destructive`) with no way back: the app neither asks
    /// first (`confirms`) nor offers Undo (`undoable`). Looks inside picks and questions too.
    static func unguarded<Action>(_ rows: [CommandRow<Action>]) -> [CommandRow<Action>] {
        all(rows).filter { !$0.confirms && !$0.undoable && ($0.destructive || sounds($0.title) || sounds($0.search)) }
    }

    /// Rows whose titles say they destroy something but that aren't marked `destructive`, so wouldn't be drawn red.
    static func unmarked<Action>(_ rows: [CommandRow<Action>]) -> [CommandRow<Action>] {
        all(rows).filter { !$0.destructive && sounds($0.title) }
    }
}

#if os(iOS)

// MARK: - The host
// Quire's arrangement, without Quire in it. The keys go to a text view nobody sees, in a window of its own above sheets
// and the page, so nothing beneath hears them. With the monitor showing things the app draws the menu there, and this
// window only takes the keys. Opened by touch (`present`), the same text view brings up the on-screen keyboard and the
// app's panel takes taps.

@MainActor
final class CommandHost<List: CommandList>: ObservableObject {
    typealias Row = CommandRow<List.Action>

    @Published private(set) var menu: CommandPalette<List>?
    /// Drawn on the monitor rather than over the phone. Decided when it opens.
    @Published private(set) var onMonitor = false
    /// Opened from the ⋯ menu rather than ⌘K: the panel should take taps, and show a way back and a way out.
    @Published private(set) var byTouch = false

    /// What's on the menu just now. Nil keeps it shut, as before the app has loaded.
    var list: () -> List? = { nil }
    /// Whether the monitor is showing things, rather than absent, paused or blank.
    var monitorShows: () -> Bool = { false }
    /// Not behind a lock, a monitor question or a system picker. Alerts are already covered.
    var blocked: () -> Bool = { false }
    /// Does what was chosen.
    var perform: (List.Action) -> Void = { _ in }
    /// Closes the sheet on top the way Esc does, asking about a draft as usual.
    var leaveSheet: () -> Void = {}
    /// What the menu's window draws: the dimmed page and the panel, or just a way to tap out with the monitor showing.
    var overlay: () -> AnyView = { AnyView(EmptyView()) }
    /// Recent commands, kept in this app's UserDefaults. Nil keeps none.
    var recents: CommandRecents? = CommandRecents()
    /// Does a row's `preview`, and the `revert` that puts things back, while the menu is open: at once, without leaving
    /// a sheet, and without telling the person it happened. Nil uses `perform`.
    var preview: ((List.Action) -> Void)?
    /// The highlight moved, to this row or to none. For anything a preview action can't say.
    var onHighlight: (Row?) -> Void = { _ in }
    /// It closed without running anything (Esc, ⌘K, a tap outside), after any preview was put back.
    var onCancel: () -> Void = {}

    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    /// Whatever had the keyboard when the menu came up, given it back by Esc.
    private weak var wasTyping: UIResponder?
    private var litID: String?

    init() {
        CommandRoute.toggle = { [weak self] in self?.toggle() }
        CommandRoute.present = { [weak self] in self?.present() }
    }

    /// ⌘K, from whichever key command heard it.
    func toggle() {
        if menu != nil { close(); return }
        open(byTouch: false)
    }

    /// Opens it without a hardware keyboard: what a "Commands" item in the ⋯ menu calls, on phone and iPad. On the
    /// monitor when it's showing, with the phone's keyboard to type.
    func present() {
        guard menu == nil else { return }
        open(byTouch: true)
    }

    private func open(byTouch: Bool) {
        guard !blocked(), !CommandScreen.questionIsUp, let list = list(), let scene = CommandScreen.scene else { return }
        onMonitor = monitorShows()
        self.byTouch = byTouch
        menu = CommandPalette(list, recents: recents)
        wasTyping = CommandScreen.firstResponder
        previousKey = scene.windows.first(where: \.isKeyWindow)

        let host = UIHostingController(rootView: overlay())
        host.view.backgroundColor = .clear
        let top = UIWindow(windowScene: scene)
        top.rootViewController = host
        top.backgroundColor = .clear
        // A new window follows the system, not the light or dark the app has chosen.
        top.overrideUserInterfaceStyle = previousKey?.traitCollection.userInterfaceStyle ?? .unspecified
        // Above sheets; an app's lock screen sits higher still.
        top.windowLevel = .alert
        top.makeKeyAndVisible()
        let field = CommandField(onScreenKeyboard: byTouch)
        field.typed = { [weak self] in self?.type($0) }
        field.deleted = { [weak self] in self?.backspace() }
        field.entered = { [weak self] in self?.press(.enter) }
        top.addSubview(field)
        window = top
        CommandRoute.heard = { [weak self] in self?.press($0) }
        litID = menu?.selected
        onHighlight(menu?.lit)
    }

    /// Closes it without running anything, putting back any preview.
    func close() {
        guard menu != nil else { return }
        menu?.cancel()
        settle()
        dismiss()
        onCancel()
    }

    private func dismiss() {
        guard menu != nil else { return }
        menu = nil
        byTouch = false
        litID = nil
        CommandRoute.heard = nil
        window?.isHidden = true
        window = nil
        previousKey?.makeKey()
        let field = wasTyping
        wasTyping = nil
        DispatchQueue.main.async { field?.becomeFirstResponder() }
    }

    func press(_ key: CommandKey) {
        guard let outcome = menu?.press(key) else { return }
        follow(outcome)
    }

    func type(_ text: String) {
        menu?.type(text)
        settle()
    }

    func backspace() {
        menu?.backspace()
        settle()
    }

    /// A tap on a row.
    func choose(_ id: String) {
        guard let outcome = menu?.choose(id) else { return }
        follow(outcome)
    }

    /// The pointer over a row.
    func highlight(_ id: String) {
        menu?.highlight(id)
        settle()
    }

    /// The panel's back button: one step out, or closed at the top.
    func back() {
        guard let outcome = menu?.back() else { return }
        follow(outcome)
    }

    private func follow(_ outcome: CommandPalette<List>.Outcome) {
        settle()
        switch outcome {
        case .stay: break
        case .close:
            dismiss()
            onCancel()
        case .run(let action):
            let keeps = menu?.keepsSheet ?? false
            // It's going somewhere: the keyboard isn't handed back to what's being left. A row that runs over the
            // sheet isn't leaving it, so the composer gets its cursor back as it would from Esc.
            if !keeps { wasTyping = nil }
            dismiss()
            // On the next turn, not inside the key's own handling: changing things from there is what hung Quire.
            DispatchQueue.main.async { [weak self] in self?.gate(action, waited: 0, keepsSheet: keeps) }
        }
    }

    /// Previews and reverts, as they come, and the highlight hook.
    private func settle() {
        let effects = menu?.takeEffects() ?? []
        let run = preview ?? perform
        for effect in effects {
            DispatchQueue.main.async { run(effect.action) }
        }
        if menu != nil, menu?.selected != litID {
            litID = menu?.selected
            onHighlight(menu?.lit)
        }
    }

    private func gate(_ action: List.Action, waited: Double, keepsSheet: Bool) {
        let again = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.gate(action, waited: waited + 0.15, keepsSheet: keepsSheet)
            }
        }
        switch CommandGate.step(sheetUp: CommandScreen.sheetIsUp, waited: waited, keepsSheet: keepsSheet) {
        case .run: perform(action)
        case .leave: leaveSheet(); again()
        case .wait: again()
        case .drop: break
        }
    }

    /// What's on the menu changed while it's open.
    func refresh() {
        guard menu != nil, let list = list() else { return }
        menu?.refresh(list)
        settle()
    }
}

/// Where the keys go. One menu per app, so one route.
@MainActor
enum CommandRoute {
    fileprivate(set) static var toggle: (() -> Void)?
    fileprivate(set) static var present: (() -> Void)?
    fileprivate(set) static var heard: ((CommandKey) -> Void)?

    static func pressToggle() { toggle?() }
    /// Opens the menu for touch: the ⋯ menu's "Commands".
    static func presentMenu() { present?() }
}

/// Reading the screen, for the host.
@MainActor
enum CommandScreen {
    private static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }.flatMap(\.windows)
    }

    static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// What's on top of the window with the keyboard, if anything is presented over it.
    private static var top: UIViewController? {
        guard var top = windows.first(where: \.isKeyWindow)?.rootViewController?.presentedViewController else { return nil }
        while let next = top.presentedViewController { top = next }
        return top
    }

    static var sheetIsUp: Bool { top != nil }
    /// An alert or a confirmation dialog: both are this underneath.
    static var questionIsUp: Bool { top is UIAlertController }

    private static weak var captured: UIResponder?

    static var firstResponder: UIResponder? {
        captured = nil
        UIApplication.shared.sendAction(#selector(UIResponder.kitCaptureFirstResponder), to: nil, from: nil, for: nil)
        return captured
    }

    fileprivate static func capture(_ responder: UIResponder) { captured = responder }
}

// MARK: - Keys, on the responder chain

@MainActor
enum CommandResponders {
    private typealias Getter = @convention(c) (AnyObject, Selector) -> NSArray?

    private static func uiInput(_ input: CommandInput) -> String {
        switch input {
        case .esc: return UIKeyCommand.inputEscape
        case .up: return UIKeyCommand.inputUpArrow
        case .down: return UIKeyCommand.inputDownArrow
        case .left: return UIKeyCommand.inputLeftArrow
        case .right: return UIKeyCommand.inputRightArrow
        case .pageUp: return UIKeyCommand.inputPageUp
        case .pageDown: return UIKeyCommand.inputPageDown
        case .home: return UIKeyCommand.inputHome
        case .end: return UIKeyCommand.inputEnd
        case .text(let text): return text
        }
    }

    private static func command(_ chord: CommandChord) -> UIKeyCommand {
        var flags: UIKeyModifierFlags = []
        if chord.mods.contains(.command) { flags.insert(.command) }
        if chord.mods.contains(.alternate) { flags.insert(.alternate) }
        if chord.mods.contains(.shift) { flags.insert(.shift) }
        if chord.mods.contains(.control) { flags.insert(.control) }
        let c = UIKeyCommand(input: uiInput(chord.input), modifierFlags: flags,
                             action: #selector(UIResponder.kitCommandKey(_:)))
        // Otherwise a text view takes them for itself.
        c.wantsPriorityOverSystemBehavior = true
        // These are the characters printed on the keys.
        c.allowsAutomaticLocalization = false
        c.allowsAutomaticMirroring = false
        return c
    }

    static let toggle = command(CommandChord(.text("k"), .command))
    /// Everything the menu takes while it's up, declared on its own field.
    static let held = CommandKeys.chords.map { command($0) }

    static func key(for command: UIKeyCommand) -> CommandKey? {
        let flags = command.modifierFlags
        var mods: CommandMods = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.alternate) { mods.insert(.alternate) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        let input: CommandInput
        switch command.input {
        case UIKeyCommand.inputEscape: input = .esc
        case UIKeyCommand.inputUpArrow: input = .up
        case UIKeyCommand.inputDownArrow: input = .down
        case UIKeyCommand.inputPageUp: input = .pageUp
        case UIKeyCommand.inputPageDown: input = .pageDown
        case UIKeyCommand.inputHome: input = .home
        case UIKeyCommand.inputEnd: input = .end
        case let text?: input = .text(text)
        case nil: return nil
        }
        return CommandKeys.meaning(CommandChord(input, mods))
    }

    /// Once, at launch: ⌘K on every text field and text view, SwiftUI's included, ahead of the text system, and on every
    /// window, which is the end of the responder chain wherever the keyboard is. `keyCommands` is wrapped in place,
    /// keeping whatever the class declared, as the apps' own Esc is.
    static func install() {
        wrap(UITextField.self)
        wrap(UITextView.self)
        wrap(UIWindow.self)
    }

    private static func wrap(_ type: AnyClass) {
        let selector = #selector(getter: UIResponder.keyCommands)
        guard let method = class_getInstanceMethod(type, selector) else { return }
        // The class's own if it has one, or else what it inherits.
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (AnyObject) -> NSArray? = { responder in
            let own = original(responder, selector) as? [UIKeyCommand] ?? []
            // Mid-composition the keys belong to the input method.
            let composing = MainActor.assumeIsolated { (responder as? UITextInput)?.markedTextRange != nil }
            if composing { return own as NSArray }
            return MainActor.assumeIsolated { own + [toggle] } as NSArray
        }
        let wrapped = imp_implementationWithBlock(block)
        if !class_addMethod(type, selector, wrapped, method_getTypeEncoding(method)) {
            method_setImplementation(method, wrapped)
        }
    }
}

extension UIResponder {
    @objc func kitCommandKey(_ command: UIKeyCommand) {
        MainActor.assumeIsolated {
            let key = CommandResponders.key(for: command)
            if let heard = CommandRoute.heard {
                // Held keys mean nothing, and that's the point of them.
                if let key { heard(key) }
            } else if key == .toggle {
                CommandRoute.pressToggle()
            }
        }
    }

    @objc fileprivate func kitCaptureFirstResponder() {
        MainActor.assumeIsolated { CommandScreen.capture(self) }
    }
}

/// ⌘K for a screen with nothing else holding the keyboard, and the name iPad lists when ⌘ is held. There to be heard,
/// not seen.
struct CommandMenuShortcut: View {
    var body: some View {
        Button("Command Menu") { CommandRoute.pressToggle() }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 0, height: 0).opacity(0)
            .accessibilityHidden(true)
    }
}

/// "Commands", for the ⋯ menu: the way in without a hardware keyboard. It waits for the menu it's in to go first.
struct CommandMenuItem: View {
    var title = "Commands"
    var body: some View {
        Button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { CommandRoute.presentMenu() }
        } label: {
            Label(title, systemImage: "command")
        }
    }
}

/// Where typing lands while the menu is up: out of sight, always empty, and the letters go to the menu. Opened by ⌘K
/// there's a real keyboard, so no on-screen one; opened by touch, the on-screen keyboard comes up.
private final class CommandField: UITextView, UITextViewDelegate {
    var typed: (String) -> Void = { _ in }
    var deleted: () -> Void = {}
    var entered: () -> Void = {}

    init(onScreenKeyboard: Bool) {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: nil)
        delegate = self
        alpha = 0
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        if !onScreenKeyboard { inputView = UIView() }
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        autocorrectionType = .no
        spellCheckingType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        returnKeyType = .go
    }

    required init?(coder: NSCoder) { fatalError("Built in code.") }

    override var keyCommands: [UIKeyCommand]? { CommandResponders.held }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DispatchQueue.main.async { self.becomeFirstResponder() } }
    }

    override func deleteBackward() {
        MainActor.assumeIsolated { deleted() }
    }

    func textView(_ v: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        MainActor.assumeIsolated {
            if text.isEmpty { deleted() }
            // The on-screen keyboard's Go. A hardware Return is a held key and never arrives here.
            else if text == "\n" { entered() }
            else { typed(text) }
        }
        return false
    }
}

#endif
