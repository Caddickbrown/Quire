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
//   - In Monitor Mode every phone action can be done from here (0.9): typed edits (`.ask`, prefilled), one or several
//     choices (`.pick`, `.multi`), a question before deleting (`.confirm`), several answers in a row (`CommandForm`),
//     settings (`CommandSettings`), notices on the monitor with ⌘Z for Undo (`CommandNotices`), and "Finish on the
//     phone" for system sheets (`onPhone`).
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
        /// Ticks inside the menu: "Labels…" then several labels. Space ticks, Return is Done (0.9).
        case multi(CommandMulti<Action>)
        /// A question inside the menu before something that can't be undone: "Delete 3 items?" (0.9).
        case confirm(CommandConfirm<Action>)
        /// In a multi pick, ticks or unticks this option. The kit makes these rows; an app doesn't (0.9).
        case tick(String)
        /// One step out, as Esc: a confirm step's Cancel (0.9).
        case back
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
    /// It needs the phone's own screen to finish (a Photos or Files picker, the share sheet, print, Face ID): what the
    /// monitor says while the phone has it, "Choose the photos on the phone." Chosen on the monitor, the host shows
    /// this there as a notice until the sheet on the phone has come and gone (0.9).
    var onPhone: String?

    init(_ id: String, _ title: String, detail: String? = nil, symbol: String, step: Step, search: String? = nil,
         confirms: Bool = false, synonyms: [String] = [], destructive: Bool = false, undoable: Bool = false,
         context: String? = nil, preview: Action? = nil, revert: Action? = nil, isCurrent: Bool = false,
         keepsSheet: Bool = false, onPhone: String? = nil) {
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
        self.onPhone = onPhone
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
        case .run, .tick, .back: return false
        case .open, .pick, .ask, .multi, .confirm: return true
        }
    }

    /// Every row under this one, its picks' choices, its questions' suggestions and a confirm step's answer, deepest
    /// last. What a typed answer or a multi pick's Done leads on to depends on what's typed, so isn't here.
    var underneath: [CommandRow] {
        switch step {
        case .pick(let p): return p.choices.flatMap { [$0] + $0.underneath }
        case .ask(let a): return a.suggestions.flatMap { [$0] + $0.underneath }
        case .confirm(let c): return [c.row(under: self)]
        case .run, .open, .multi, .tick, .back: return []
        }
    }
}

/// One thing to tick in a multi pick: a label, a tag, a list.
struct CommandOption: Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String?
    var symbol: String
    var synonyms: [String]

    init(_ id: String, _ title: String, detail: String? = nil, symbol: String = "tag", synonyms: [String] = []) {
        self.id = id; self.title = title; self.detail = detail; self.symbol = symbol; self.synonyms = synonyms
    }
}

/// What a multi pick ends with: the options ticked, in the order they're listed, and any typed in as new.
struct CommandTicks: Equatable {
    var ids: [String]
    /// New names, in the order they were added. Only when the pick `adds`.
    var added: [String]

    init(ids: [String] = [], added: [String] = []) { self.ids = ids; self.added = added }
    var isEmpty: Bool { ids.isEmpty && added.isEmpty }
}

/// Several choices at once: "Labels…", "Tags…", "Lists…", "Show only…". Ticks show what's on now. Space ticks the lit
/// option, a tap ticks the option tapped, Return (or ⌘↩, or the Done row) finishes, Esc backs out with nothing changed.
/// Typing narrows the options; with `adds`, a name that isn't there can be added ("New label “urgent”").
struct CommandMulti<Action: Equatable>: Equatable {
    var prompt: String
    var options: [CommandOption]
    /// Ticked when it opens: what's on now.
    var ticked: [String]
    var nothing: String
    /// The row for a name typed that isn't an option: "New label “\($0)”". Nil: only the options listed.
    var adds: ((String) -> String)?
    /// The Done row's title, from what's ticked. Nil: "Done: Bug, UI", "Done: none ticked".
    var done: ((CommandTicks, [String]) -> String)?
    /// What Done leads to: a step, or `.run` of an action. Nil while nothing usable is ticked: Done backs out.
    var finish: (CommandTicks) -> CommandRow<Action>.Step?

    /// Done runs an action.
    init(prompt: String, options: [CommandOption], ticked: [String] = [], nothing: String = "No option by that name.",
         adds: ((String) -> String)? = nil, done: ((CommandTicks, [String]) -> String)? = nil,
         make: @escaping (CommandTicks) -> Action?) {
        self.init(prompt: prompt, options: options, ticked: ticked, nothing: nothing, adds: adds, done: done,
                  then: { make($0).map { .run($0) } })
    }

    /// Done leads on to another step: a pick, a typed answer, another multi pick, a confirm.
    init(prompt: String, options: [CommandOption], ticked: [String] = [], nothing: String = "No option by that name.",
         adds: ((String) -> String)? = nil, done: ((CommandTicks, [String]) -> String)? = nil,
         then: @escaping (CommandTicks) -> CommandRow<Action>.Step?) {
        self.prompt = prompt; self.options = options; self.ticked = ticked; self.nothing = nothing
        self.adds = adds; self.done = done; self.finish = then
    }

    static func == (a: CommandMulti, b: CommandMulti) -> Bool {
        a.prompt == b.prompt && a.options == b.options && a.ticked == b.ticked && a.nothing == b.nothing
            && (a.adds == nil) == (b.adds == nil)
    }
}

/// A question before something that can't be undone, inside the menu: "Delete 3 items?" with the answer lit, so
/// Return confirms and Esc (or Cancel) backs out. Use it instead of a phone-only alert, which the monitor can't show.
struct CommandConfirm<Action: Equatable>: Equatable {
    /// The grey words in the box: "Delete 3 items?"
    var prompt: String
    /// The answer's title: "Delete 3 items".
    var title: String
    /// Under the answer: "This can't be undone."
    var detail: String?
    var symbol: String
    var action: Action
    var cancel: String
    /// Drawn red. On for deleting; off for something that only needs a second look ("Send to 40 people").
    var destructive: Bool

    init(prompt: String, title: String, detail: String? = nil, symbol: String = "trash", action: Action,
         cancel: String = "Cancel", destructive: Bool = true) {
        self.prompt = prompt; self.title = title; self.detail = detail; self.symbol = symbol; self.action = action
        self.cancel = cancel; self.destructive = destructive
    }

    /// The answer as a row, under the row that asked.
    func row(under opener: CommandRow<Action>) -> CommandRow<Action> {
        CommandRow<Action>(opener.id + "#confirm", title, detail: detail, symbol: symbol, step: .run(action),
                           confirms: true, destructive: destructive, context: opener.context,
                           keepsSheet: opener.keepsSheet, onPhone: opener.onPhone)
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
    /// What's typed leads on to another step instead (a pick, another question, a confirm), for a command that
    /// needs several answers: "New duty…" then the title, the due date, the person. Nil while it isn't usable (0.9).
    var then: ((String) -> CommandRow<Action>.Step?)?
    /// With the box empty, a row that goes on with nothing typed: "No due date", "Skip". Nil: something must be
    /// typed (0.9).
    var skip: String?

    init(prompt: String, initial: String = "", suggestions: [CommandRow<Action>] = [], symbol: String = "return",
         nothing: String = "Type, then Return.", skip: String? = nil, title: @escaping (String) -> String,
         make: @escaping (String) -> Action?) {
        self.prompt = prompt; self.initial = initial; self.suggestions = suggestions; self.symbol = symbol
        self.nothing = nothing; self.skip = skip; self.title = title; self.make = make; self.then = nil
    }

    /// What's typed leads on to another step: `then` gives it, or nil while the typing isn't usable.
    init(prompt: String, initial: String = "", suggestions: [CommandRow<Action>] = [], symbol: String = "return",
         nothing: String = "Type, then Return.", skip: String? = nil, title: @escaping (String) -> String,
         then: @escaping (String) -> CommandRow<Action>.Step?) {
        self.prompt = prompt; self.initial = initial; self.suggestions = suggestions; self.symbol = symbol
        self.nothing = nothing; self.skip = skip; self.title = title; self.make = { _ in nil }; self.then = then
    }

    /// Where what's typed goes: a step, or nil while it isn't usable.
    func step(for text: String) -> CommandRow<Action>.Step? {
        if let then { return then(text) }
        return make(text).map { .run($0) }
    }

    static func == (a: CommandAsk, b: CommandAsk) -> Bool {
        a.prompt == b.prompt && a.initial == b.initial && a.suggestions == b.suggestions && a.symbol == b.symbol
            && a.nothing == b.nothing && a.skip == b.skip && (a.then == nil) == (b.then == nil)
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

/// What a key means to the menu. 0.9 added `clear` (⌘⌫: empty the box), `deleteWord` (⌥⌫), `done` (⌘↩: finish a
/// multi pick, or Return anywhere else) and `paste` (⌘V: the host types what's on the clipboard).
enum CommandKey: Equatable, CaseIterable {
    case esc, enter, up, down, tab, backTab, toggle, pageUp, pageDown, first, last
    case clear, deleteWord, done, paste
}

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

    /// One step in: a shorter list, a pick, a question, ticks or a confirm, with the row that opened it.
    private enum Frame: Equatable {
        case stage(String, Row?)
        case pick(Row, CommandPick<List.Action>)
        case ask(Row, CommandAsk<List.Action>)
        /// What's ticked now, and names added, as the step goes.
        case multi(Row, CommandMulti<List.Action>, ticked: [String], added: [String])
        case confirm(Row, CommandConfirm<List.Action>)

        var opener: Row? {
            switch self {
            case .stage(_, let row): return row
            case .pick(let row, _), .ask(let row, _), .multi(let row, _, _, _), .confirm(let row, _): return row
            }
        }
    }

    /// Where the step before was, to go back to.
    private struct Mark: Equatable {
        var query: String
        var selected: String?
    }

    /// The id of a multi pick's Done row, and the prefix of a name added there.
    static var doneID: String { "#done" }
    static var addedPrefix: String { "+" }

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
    /// The last `.run` needs the phone's own screen to finish: what the monitor should say meanwhile (`onPhone` on
    /// the chosen row, or on the row that opened its step).
    var phoneNote: String? {
        guard let chosen else { return nil }
        return chosen.onPhone ?? frames.reversed().lazy.compactMap { $0.opener?.onPhone }.first
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
    /// Every row that opened a step, outermost first: "New duty…", "Title: “Mow”", "Due: Friday", for a trail.
    var trail: [Row] { frames.compactMap(\.opener) }
    /// The box holds an answer rather than a search.
    var isAsking: Bool { if case .ask? = frames.last { return true } else { return false } }
    /// A multi pick is open: Space ticks, Return is Done.
    var isTicking: Bool { if case .multi? = frames.last { return true } else { return false } }
    /// A confirm step is open: Return answers, Esc backs out, typing does nothing.
    var isConfirming: Bool { if case .confirm? = frames.last { return true } else { return false } }
    /// In a multi pick, what's ticked now (ids, then added names with `addedPrefix`). Empty elsewhere.
    var ticked: [String] {
        if case .multi(_, _, let ticked, let added)? = frames.last { return ticked + added.map { Self.addedPrefix + $0 } }
        return []
    }

    var prompt: String {
        switch frames.last {
        case .pick(_, let p)?: return p.prompt
        case .ask(_, let a)?: return a.prompt
        case .multi(_, let m, _, _)?: return m.prompt
        case .confirm(_, let c)?: return c.prompt
        default: return list.prompt(stage: stage)
        }
    }

    var nothing: String {
        switch frames.last {
        case .pick(_, let p)?: return p.nothing
        case .ask(_, let a)?: return a.nothing
        case .multi(_, let m, _, _)?: return m.nothing
        case .confirm(_, let c)?: return c.prompt
        default: return list.nothing(stage: stage)
        }
    }

    // MARK: typing

    mutating func type(_ text: String) {
        let clean = text.filter { !$0.isNewline && !($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) }
        guard !clean.isEmpty, !isConfirming else { return }
        // In a multi pick, Space ticks the lit option. On the Done row or a "New …" row it's a space.
        if isTicking, clean == " ", lit?.id != "#new", case .tick(let id)? = lit?.step {
            tick(id)
            return
        }
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

    /// ⌥⌫: the last word and the spaces after it. With nothing typed, the same as ⌫.
    mutating func deleteWord() {
        guard !query.isEmpty else { return backspace() }
        while query.last == " " { query.removeLast() }
        while let last = query.last, last != " " { query.removeLast() }
        armed = true
        relist()
    }

    /// ⌘⌫: the box emptied, as for a name to type afresh over the one it opened with. Never backs out of a step.
    mutating func clear() {
        guard !query.isEmpty else { return }
        query = ""
        armed = true
        relist()
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
            case .pick?, .ask?, .multi?, .confirm?:
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
        case .enter, .done: return enter()
        case .clear: clear()
        case .deleteWord: deleteWord()
        // The host reads the clipboard and calls `type`.
        case .paste: break
        }
        return .stay
    }

    /// A tap or a click on a row: light it, then go. In a multi pick, a tap on an option ticks it.
    mutating func choose(_ id: String) -> Outcome {
        guard let row = rows.first(where: { $0.id == id }) else { return .stay }
        selected = id
        armed = true
        moved()
        if case .tick(let option) = row.step {
            tick(option)
            return .stay
        }
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
        // In a multi pick Return is Done, wherever the highlight is, except on a "New …" row, where it adds.
        if isTicking, lit?.id != "#new", let done = rows.first(where: { $0.id == Self.doneID }) {
            return go(done)
        }
        guard let row = lit else { return .stay }
        return go(row)
    }

    private mutating func go(_ row: Row) -> Outcome {
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
        case .multi(let multi):
            let known = Set(multi.options.map(\.id))
            push(.multi(row, multi, ticked: multi.ticked.filter { known.contains($0) }, added: []), query: "")
        case .confirm(let confirm):
            push(.confirm(row, confirm), query: "")
        case .tick(let id):
            tick(id)
        case .back:
            return back()
        }
        return .stay
    }

    /// Ticks or unticks an option of the open multi pick, or adds a typed name (`addedPrefix` + name), ticked.
    private mutating func tick(_ id: String) {
        guard case .multi(let row, let multi, var ticked, var added)? = frames.last else { return }
        var keep = selected
        if id.hasPrefix(Self.addedPrefix) {
            let name = String(id.dropFirst(Self.addedPrefix.count))
            if let i = added.firstIndex(of: name) {
                added.remove(at: i)
            } else if !name.isEmpty {
                added.append(name)
                // Added: the search is done with, and the new name is lit among the rest.
                query = ""
                keep = id
            }
        } else if let i = ticked.firstIndex(of: id) {
            ticked.remove(at: i)
        } else {
            // Kept in the options' order, so what Done hands over doesn't depend on the order of ticking.
            ticked.append(id)
            let order = multi.options.map(\.id)
            ticked.sort { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        }
        frames[frames.count - 1] = .multi(row, multi, ticked: ticked, added: added)
        armed = true
        layOut()
        selected = rows.contains { $0.id == keep } ? keep : rows.first { if case .tick = $0.step { return true } else { return false } }?.id
        moved()
    }

    private mutating func push(_ frame: Frame, query: String) {
        marks.append(Mark(query: self.query, selected: selected))
        frames.append(frame)
        self.query = query
        armed = true
        layOut()
        switch frame {
        case .pick(_, let p):
            selected = p.choices.first(where: \.isCurrent)?.id ?? rows.first?.id
        case .multi:
            // The first option, so Space ticks it; Return is Done from anywhere.
            selected = rows.first { if case .tick = $0.step { return true } else { return false } }?.id ?? rows.first?.id
        default:
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
        switch frames.last {
        case .multi?:
            if lit?.id == "#new" {
                out.append(.init(key: "↩", label: "Add"))
            } else {
                if case .tick? = lit?.step { out.append(.init(key: "Space", label: "Tick")) }
                out.append(.init(key: "↩", label: "Done"))
            }
            out.append(.init(key: "Type", label: "To find"))
        case .confirm(_, let c)?:
            if lit != nil { out.append(.init(key: "↩", label: lit?.step == .back ? c.cancel : c.title)) }
        default:
            if lit != nil { out.append(.init(key: "↩", label: "Go")) }
            out.append(.init(key: "Type", label: isAsking ? "To write" : "To find"))
        }
        if !query.isEmpty {
            out.append(.init(key: "⌫", label: "A letter"))
            if isAsking { out.append(.init(key: "⌘⌫", label: "Clear")) }
        } else if !frames.isEmpty, !isConfirming {
            out.append(.init(key: "⌫", label: "Back"))
        }
        switch frames.last {
        case .confirm(_, let c)?:
            out.append(.init(key: "⎋", label: c.cancel))
            out.append(.init(key: "⌘K", label: "Close"))
        case .pick?, .ask?, .multi?:
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
        if isTicking {
            // Typing in a multi pick lights the best option, not Done.
            selected = rows.first { $0.id != Self.doneID }?.id ?? rows.first?.id
        } else {
            selected = rows.first?.id
        }
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
                v.onPhone = choice.onPhone ?? row.onPhone
                return v
            }
        }
    }

    /// A multi pick's rows: Done, then a "New …" row when nothing matches, the options, and the "New …" row when
    /// something does.
    private func multiRows(_ opener: Row, _ multi: CommandMulti<List.Action>, ticked: [String], added: [String],
                           blank: Bool) -> [Row] {
        let on = Set(ticked)
        var options = multi.options.map { o -> Row in
            var row = Row(o.id, o.title, detail: o.detail, symbol: o.symbol, step: .tick(o.id), synonyms: o.synonyms,
                          isCurrent: on.contains(o.id))
            row.context = opener.context
            return row
        }
        options += added.map { Row(Self.addedPrefix + $0, $0, symbol: "tag", step: .tick(Self.addedPrefix + $0), isCurrent: true) }
        let shown = blank ? options : CommandMatch.rank(options, query, texts: \.texts)
        let ticks = CommandTicks(ids: ticked, added: added)
        let titles = ticked.compactMap { id in multi.options.first { $0.id == id }?.title } + added
        let doneTitle = multi.done?(ticks, titles)
            ?? (titles.isEmpty ? "Done: none ticked" : "Done: " + titles.joined(separator: ", "))
        var out = [Row(Self.doneID, doneTitle, symbol: "checkmark", step: multi.finish(ticks) ?? .back,
                       destructive: opener.destructive, undoable: opener.undoable, context: opener.context,
                       keepsSheet: opener.keepsSheet, onPhone: opener.onPhone)]
        let text = query.trimmingCharacters(in: .whitespaces)
        var addRow: Row?
        if let adds = multi.adds, !text.isEmpty {
            let folded = String(CommandMatch.fold(text))
            let exists = (multi.options.map(\.title) + added).contains { String(CommandMatch.fold($0)) == folded }
            if !exists { addRow = Row("#new", adds(text), symbol: "plus", step: .tick(Self.addedPrefix + text)) }
        }
        if let addRow, shown.isEmpty { out.append(addRow) }
        out += shown
        if let addRow, !shown.isEmpty { out.append(addRow) }
        return out
    }

    private func listed() -> [Section] {
        let blank = query.allSatisfy { $0 == " " }
        switch frames.last {
        case .pick(_, let pick)?:
            return [Section(kind: .all, title: nil, rows: blank ? pick.choices : CommandMatch.rank(pick.choices, query, texts: \.texts))]
        case .ask(let opener, let ask)?:
            var out: [Row] = []
            let text = query.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, let step = ask.step(for: text) {
                out.append(Row(opener.id + "#typed", ask.title(text), symbol: ask.symbol, step: step,
                               destructive: opener.destructive, undoable: opener.undoable, context: opener.context,
                               keepsSheet: opener.keepsSheet, onPhone: opener.onPhone))
            } else if text.isEmpty, let skip = ask.skip, let step = ask.step(for: "") {
                out.append(Row(opener.id + "#skip", skip, symbol: "arrow.right", step: step,
                               context: opener.context, keepsSheet: opener.keepsSheet, onPhone: opener.onPhone))
            }
            out += blank || !ask.initial.isEmpty && query == ask.initial
                ? ask.suggestions : CommandMatch.rank(ask.suggestions, query, texts: \.texts)
            return [Section(kind: .all, title: nil, rows: out)]
        case .multi(let opener, let multi, let ticked, let added)?:
            return [Section(kind: .all, title: nil, rows: multiRows(opener, multi, ticked: ticked, added: added, blank: blank))]
        case .confirm(let opener, let confirm)?:
            return [Section(kind: .all, title: nil, rows: [
                confirm.row(under: opener),
                Row(opener.id + "#cancel", confirm.cancel, symbol: "xmark", step: .back),
            ])]
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
        case (.text("\r"), [.command]): return .done
        case (.text(CommandKeys.backspace), [.command]): return .clear
        case (.text(CommandKeys.backspace), [.alternate]): return .deleteWord
        case (.text("v"), [.command]): return .paste
        default: return nil
        }
    }

    /// The ⌫ key, as a chord's text.
    static let backspace = "\u{8}"

    /// Everything the menu takes for itself while it's up: its own keys, and any shortcut the page behind could be
    /// listening for. Plain letters aren't here, because they're the typing.
    static let chords: [CommandChord] = {
        var out: [CommandChord] = [.init(.esc), .init(.text("\r")), .init(.text("\t")), .init(.text("\t"), .shift),
                                   .init(.text("\r"), .command), .init(.text(backspace), .command),
                                   .init(.text(backspace), .alternate)]
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
    /// A row whose step is `.confirm` asks in the palette, so counts as asking first (0.9).
    static func unguarded<Action>(_ rows: [CommandRow<Action>]) -> [CommandRow<Action>] {
        all(rows).filter {
            if case .confirm = $0.step { return false }
            return !$0.confirms && !$0.undoable && ($0.destructive || sounds($0.title) || sounds($0.search))
        }
    }

    /// Rows whose titles say they destroy something but that aren't marked `destructive`, so wouldn't be drawn red.
    static func unmarked<Action>(_ rows: [CommandRow<Action>]) -> [CommandRow<Action>] {
        all(rows).filter { !$0.destructive && sounds($0.title) }
    }
}

// MARK: - Forms: several answers, one step after another (0.9)

/// What a form's answers came to, by field id.
struct CommandAnswers: Equatable {
    fileprivate(set) var values: [String: [String]] = [:]
    fileprivate(set) var added: [String: [String]] = [:]

    init() {}

    /// A text field's answer; "" when skipped.
    func text(_ id: String) -> String { values[id]?.first ?? "" }
    /// A choice field's option id; nil when skipped.
    func choice(_ id: String) -> String? { values[id]?.first }
    /// A multi field's ticked option ids, in the options' order.
    func choices(_ id: String) -> [String] { values[id] ?? [] }
    /// A multi field's names typed in as new.
    func added(_ id: String) -> [String] { added[id] ?? [] }
}

/// A command that needs several answers, asked one after another inside the menu: "New duty…" then the title, when
/// it's due, how often, who. Each field is a typed step, a pick or a multi pick; Esc goes back one field with its
/// answer still there; the last answer runs `finish`. `form.step` goes on a row:
///
///     CommandRow("duty.new", "New duty…", symbol: "plus", step: CommandForm(fields: [
///         .text("title", "Title", prompt: "What needs doing?"),
///         .choice("due", "Due", prompt: "When?", options: dueOptions, skip: "No due date"),
///         .choice("who", "Person", prompt: "Who?", options: people, current: me),
///     ], finish: { a in .newDuty(title: a.text("title"), due: a.choice("due"), person: a.choice("who")) }).step)
struct CommandForm<Action: Equatable> {
    struct Field {
        enum Kind {
            case text(initial: String, skip: String?, valid: (String) -> Bool)
            case choice(options: [CommandOption], current: String?, skip: String?)
            case multi(options: [CommandOption], ticked: [String], adds: Bool)
        }
        var id: String
        /// Short, for the trail and the typed row: "Title", "Due".
        var label: String
        var prompt: String
        var kind: Kind

        /// Typed. `valid` says whether what's typed will do; `skip` lets it be left empty, under that title.
        static func text(_ id: String, _ label: String, prompt: String, initial: String = "", skip: String? = nil,
                         valid: @escaping (String) -> Bool = { !$0.isEmpty }) -> Field {
            Field(id: id, label: label, prompt: prompt, kind: .text(initial: initial, skip: skip, valid: valid))
        }

        /// One of a list. `current` is ticked and lit; `skip` adds a row for none.
        static func choice(_ id: String, _ label: String, prompt: String, options: [CommandOption],
                           current: String? = nil, skip: String? = nil) -> Field {
            Field(id: id, label: label, prompt: prompt, kind: .choice(options: options, current: current, skip: skip))
        }

        /// Several of a list; `adds` lets a new name be typed in.
        static func multi(_ id: String, _ label: String, prompt: String, options: [CommandOption],
                          ticked: [String] = [], adds: Bool = false) -> Field {
            Field(id: id, label: label, prompt: prompt, kind: .multi(options: options, ticked: ticked, adds: adds))
        }
    }

    var fields: [Field]
    var finish: (CommandAnswers) -> Action

    init(fields: [Field], finish: @escaping (CommandAnswers) -> Action) {
        self.fields = fields; self.finish = finish
    }

    /// The first field's step, for a row.
    var step: CommandRow<Action>.Step { step(at: 0, CommandAnswers()) }

    private func step(at i: Int, _ answers: CommandAnswers) -> CommandRow<Action>.Step {
        guard i < fields.count else { return .run(finish(answers)) }
        let field = fields[i]
        let next: (CommandAnswers) -> CommandRow<Action>.Step = { self.step(at: i + 1, $0) }
        func with(_ value: [String], added: [String] = []) -> CommandAnswers {
            var a = answers
            a.values[field.id] = value
            if !added.isEmpty { a.added[field.id] = added }
            return a
        }
        switch field.kind {
        case .text(let initial, let skip, let valid):
            return .ask(CommandAsk(prompt: field.prompt, initial: initial, skip: skip,
                                   title: { "\(field.label): “\($0)”" },
                                   then: { text in
                                       if text.isEmpty { return skip == nil ? nil : next(with([])) }
                                       return valid(text) ? next(with([text])) : nil
                                   }))
        case .choice(let options, let current, let skip):
            var choices = options.map { o in
                CommandRow<Action>(o.id, o.title, detail: o.detail, symbol: o.symbol, step: next(with([o.id])),
                                   synonyms: o.synonyms, isCurrent: o.id == current)
            }
            if let skip {
                choices.append(CommandRow<Action>("#skip", skip, symbol: "arrow.right", step: next(with([]))))
            }
            return .pick(CommandPick(prompt: field.prompt, choices: choices, searchable: false))
        case .multi(let options, let ticked, let adds):
            let noun = field.label.lowercased()
            return .multi(CommandMulti(prompt: field.prompt, options: options, ticked: ticked,
                                       adds: adds ? { "New \(noun) “\($0)”" } : nil,
                                       then: { t in next(with(t.ids, added: t.added)) }))
        }
    }
}

// MARK: - Settings as commands (0.9)

/// One setting, to be listed as a command of its own by `CommandSettings.rows`: a toggle, a choice, a number or text.
struct CommandSetting<Action: Equatable> {
    enum Kind {
        case toggle(isOn: Bool, set: (Bool) -> Action)
        /// `previews`: arrowing through the choices shows each, and Esc puts the old one back (a theme).
        case choice(options: [CommandOption], current: String, previews: Bool, set: (String) -> Action)
        case number(value: Double, range: ClosedRange<Double>, step: Double, unit: String, set: (Double) -> Action)
        case text(value: String, clearable: Bool, set: (String) -> Action)
    }
    var id: String
    var title: String
    var symbol: String
    var synonyms: [String]
    var kind: Kind

    static func toggle(_ id: String, _ title: String, symbol: String, isOn: Bool, synonyms: [String] = [],
                       set: @escaping (Bool) -> Action) -> CommandSetting {
        CommandSetting(id: id, title: title, symbol: symbol, synonyms: synonyms, kind: .toggle(isOn: isOn, set: set))
    }

    static func choice(_ id: String, _ title: String, symbol: String, options: [CommandOption], current: String,
                       previews: Bool = false, synonyms: [String] = [], set: @escaping (String) -> Action) -> CommandSetting {
        CommandSetting(id: id, title: title, symbol: symbol, synonyms: synonyms,
                       kind: .choice(options: options, current: current, previews: previews, set: set))
    }

    static func number(_ id: String, _ title: String, symbol: String, value: Double, range: ClosedRange<Double>,
                       step: Double = 1, unit: String = "", synonyms: [String] = [],
                       set: @escaping (Double) -> Action) -> CommandSetting {
        CommandSetting(id: id, title: title, symbol: symbol, synonyms: synonyms,
                       kind: .number(value: value, range: range, step: step, unit: unit, set: set))
    }

    static func text(_ id: String, _ title: String, symbol: String, value: String, clearable: Bool = true,
                     synonyms: [String] = [], set: @escaping (String) -> Action) -> CommandSetting {
        CommandSetting(id: id, title: title, symbol: symbol, synonyms: synonyms,
                       kind: .text(value: value, clearable: clearable, set: set))
    }
}

/// A list of settings as palette commands, each its own row: "Setting: Dark mode — turn off" (state "On"),
/// "Setting: Theme…" (a pick; typing finds "Setting: Theme: Sepia"), "Setting: Text size…" (a typed number with
/// smaller and larger), "Setting: Server address…" (typed, prefilled). Ids are "setting.<id>".
enum CommandSettings {
    static func rows<Action>(_ settings: [CommandSetting<Action>], prefix: String = "Setting") -> [CommandRow<Action>] {
        settings.map { row($0, prefix: prefix) }
    }

    /// A number as it's shown and typed: no ".0" on whole numbers.
    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e12 ? String(Int(value)) : String(value)
    }

    private static func row<Action>(_ s: CommandSetting<Action>, prefix: String) -> CommandRow<Action> {
        let id = "setting." + s.id
        let name = prefix.isEmpty ? s.title : "\(prefix): \(s.title)"
        let words = s.synonyms + ["setting", "preference"]
        switch s.kind {
        case .toggle(let isOn, let set):
            return .toggle(id, isOn: isOn, turnOn: "\(name) — turn on", turnOff: "\(name) — turn off",
                           symbol: s.symbol, action: set(!isOn), synonyms: words)
        case .choice(let options, let current, let previews, let set):
            let choices = options.map { o in
                CommandRow<Action>(o.id, o.title, detail: o.detail, symbol: o.symbol, step: .run(set(o.id)),
                                   synonyms: o.synonyms, preview: previews ? set(o.id) : nil, isCurrent: o.id == current)
            }
            var row = CommandRow<Action>(id, name + "…", symbol: s.symbol,
                                         step: .pick(CommandPick(prompt: "\(s.title)?", choices: choices,
                                                                 revert: previews ? set(current) : nil)),
                                         synonyms: words)
            row.state = options.first { $0.id == current }?.title
            return row
        case .number(let value, let range, let step, let unit, let set):
            let u = unit.isEmpty ? "" : " " + unit
            func clamp(_ v: Double) -> Double { min(range.upperBound, max(range.lowerBound, v)) }
            var suggestions: [CommandRow<Action>] = []
            if clamp(value - step) != value {
                suggestions.append(CommandRow(id + ".smaller", "Smaller: \(format(clamp(value - step)))\(u)",
                                              symbol: "minus", step: .run(set(clamp(value - step)))))
            }
            if clamp(value + step) != value {
                suggestions.append(CommandRow(id + ".larger", "Larger: \(format(clamp(value + step)))\(u)",
                                              symbol: "plus", step: .run(set(clamp(value + step)))))
            }
            let ask = CommandAsk<Action>(
                prompt: "\(s.title), \(format(range.lowerBound))–\(format(range.upperBound))\(u)",
                initial: format(value), suggestions: suggestions,
                nothing: "A number from \(format(range.lowerBound)) to \(format(range.upperBound)).",
                title: { "Set to \($0)\(u)" },
                make: { text in
                    guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), range.contains(v), v != value
                    else { return nil }
                    return set(v)
                })
            var row = CommandRow<Action>(id, name + "…", symbol: s.symbol, step: .ask(ask), synonyms: words)
            row.state = format(value) + u
            return row
        case .text(let value, let clearable, let set):
            let ask = CommandAsk<Action>(prompt: s.title, initial: value, skip: clearable && !value.isEmpty ? "Clear it" : nil,
                                         title: { "Set to “\($0)”" },
                                         make: { $0 == value ? nil : set($0) })
            var row = CommandRow<Action>(id, name + "…", symbol: s.symbol, step: .ask(ask), synonyms: words)
            row.state = value.isEmpty ? "Not set" : String(value.prefix(24))
            return row
        }
    }
}

// MARK: - Notices: Undo, failures and results, where you're looking (0.9)

/// One notice: what a command did, an Undo for it, what went wrong, or "Finish on the phone".
struct CommandNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        /// What a command did: "Renamed.", "3 moved to Inbox."
        case done
        /// The same, with Undo, and ⌘Z.
        case undo
        /// What went wrong, in `specs/WORDS.md`'s words.
        case failure
        /// It needs the phone's own screen: a picker, the share sheet, print, Face ID.
        case phone
    }

    let id: Int
    var kind: Kind
    var text: String
    var detail: String?
    var at: Date
    /// Seconds it shows for; nil until it's dismissed.
    var lasts: Double?

    var symbol: String {
        switch kind {
        case .done: return "checkmark.circle"
        case .undo: return "arrow.uturn.backward.circle"
        case .failure: return "exclamationmark.triangle"
        case .phone: return "iphone"
        }
    }

    func expired(_ now: Date) -> Bool { lasts.map { now.timeIntervalSince(at) >= $0 } ?? false }
}

/// The notices showing now, as a value: the host draws `showing` on the monitor (and the phone), ⌘Z takes the
/// latest Undo. Times are passed in, so tests can run the clock.
struct CommandNoticeBoard {
    /// How long each kind shows, in seconds.
    static func lasting(_ kind: CommandNotice.Kind) -> Double {
        switch kind {
        case .done: return 3.2
        case .undo: return 6
        case .failure: return 8
        case .phone: return 90
        }
    }

    /// The most that show at once; the oldest go first.
    static let cap = 3

    private(set) var all: [CommandNotice] = []
    private var undos: [Int: () -> Void] = [:]
    private var next = 1

    init() {}

    @discardableResult
    mutating func post(_ kind: CommandNotice.Kind, _ text: String, detail: String? = nil, now: Date = Date(),
                       lasts: Double? = nil, undo: (() -> Void)? = nil) -> Int {
        let id = next
        next += 1
        // One "finish on the phone" at a time: a newer one says what's wanted now.
        if kind == .phone { all.removeAll { $0.kind == .phone } }
        all.append(CommandNotice(id: id, kind: kind, text: text, detail: detail, at: now,
                                 lasts: lasts ?? Self.lasting(kind)))
        if let undo { undos[id] = undo }
        while all.count > Self.cap, let oldest = all.firstIndex(where: { $0.kind != .phone }) { drop(at: oldest) }
        return id
    }

    @discardableResult mutating func say(_ text: String, detail: String? = nil, now: Date = Date()) -> Int {
        post(.done, text, detail: detail, now: now)
    }

    @discardableResult mutating func fail(_ text: String, detail: String? = nil, now: Date = Date()) -> Int {
        post(.failure, text, detail: detail, now: now)
    }

    /// "Deleted 3 items." with Undo: `undo` is what Undo, or ⌘Z while it shows, does.
    @discardableResult mutating func undoable(_ text: String, detail: String? = nil, now: Date = Date(),
                                              undo: @escaping () -> Void) -> Int {
        post(.undo, text, detail: detail, now: now, undo: undo)
    }

    /// "Finish on the phone", with what to do there.
    @discardableResult mutating func phone(_ detail: String, text: String = "Finish on the phone",
                                           now: Date = Date()) -> Int {
        post(.phone, text, detail: detail, now: now)
    }

    mutating func dismiss(_ id: Int) {
        if let i = all.firstIndex(where: { $0.id == id }) { drop(at: i) }
    }

    /// The phone's part is done: its notice goes.
    mutating func finishedOnPhone() {
        all.removeAll { $0.kind == .phone }
    }

    /// Drops what has had its time. True if anything went.
    @discardableResult mutating func expire(_ now: Date = Date()) -> Bool {
        let gone = all.filter { $0.expired(now) }.map(\.id)
        for id in gone { dismiss(id) }
        return !gone.isEmpty
    }

    /// Oldest first, as they stack.
    var showing: [CommandNotice] { all }
    /// The newest notice with an Undo that's still showing.
    var latestUndo: CommandNotice? { all.last { $0.kind == .undo && undos[$0.id] != nil } }
    var canUndo: Bool { latestUndo != nil }
    /// When the next one is due to go.
    var nextExpiry: Date? { all.compactMap { n in n.lasts.map { n.at.addingTimeInterval($0) } }.min() }

    /// Takes the latest Undo off the board and hands it over to run. Nil when there's none.
    mutating func takeUndo(_ id: Int? = nil) -> (() -> Void)? {
        guard let notice = id.flatMap({ id in all.first { $0.id == id } }) ?? latestUndo, let undo = undos[notice.id]
        else { return nil }
        dismiss(notice.id)
        return undo
    }

    /// A palette row for the latest Undo, "Undo: Deleted 3 items", for an app's list: its action should call
    /// `CommandNotices.shared.undoLatest()`. Nil when there's nothing to undo.
    func undoRow<Action>(_ action: Action) -> CommandRow<Action>? {
        guard let n = latestUndo else { return nil }
        let what = n.text.hasSuffix(".") ? String(n.text.dropLast()) : n.text
        return CommandRow("notice.undo", "Undo: \(what)", detail: "⌘Z", symbol: "arrow.uturn.backward",
                          step: .run(action), synonyms: ["undo", "take back", "revert"])
    }

    private mutating func drop(at i: Int) {
        undos[all[i].id] = nil
        all.remove(at: i)
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
        // ⌘V: what's on the clipboard, typed. Lines become spaces' worth of nothing, as typing them would.
        if key == .paste {
            if menu != nil, let text = UIPasteboard.general.string { type(text.replacingOccurrences(of: "\n", with: " ")) }
            return
        }
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
            // Chosen on the monitor but finished on the phone (a picker, the share sheet): the monitor says so.
            let phone = onMonitor ? menu?.phoneNote : nil
            // It's going somewhere: the keyboard isn't handed back to what's being left. A row that runs over the
            // sheet isn't leaving it, so the composer gets its cursor back as it would from Esc.
            if !keeps { wasTyping = nil }
            dismiss()
            // On the next turn, not inside the key's own handling: changing things from there is what hung Quire.
            DispatchQueue.main.async { [weak self] in self?.gate(action, waited: 0, keepsSheet: keeps) }
            if let phone { CommandNotices.shared.handOff(phone) }
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
        case .text(CommandKeys.backspace): return UIKeyCommand.inputDelete
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
        case UIKeyCommand.inputDelete: input = .text(CommandKeys.backspace)
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
        // The window is the end of the chain: ⌘Z there is only heard when nothing nearer the keyboard takes it, so a
        // text field's own undo and an app's own ⌘Z come first.
        wrap(UIWindow.self) { CommandNotices.shared.canUndo && CommandRoute.heard == nil ? [undo] : [] }
    }

    /// ⌘Z for the latest Undo notice, while one shows (0.9).
    static let undo: UIKeyCommand = {
        let c = UIKeyCommand(title: "Undo", action: #selector(UIResponder.kitUndoKey(_:)), input: "z",
                             modifierFlags: .command)
        c.allowsAutomaticLocalization = false
        c.allowsAutomaticMirroring = false
        return c
    }()

    private static func wrap(_ type: AnyClass, extra: @escaping @MainActor () -> [UIKeyCommand] = { [] }) {
        let selector = #selector(getter: UIResponder.keyCommands)
        guard let method = class_getInstanceMethod(type, selector) else { return }
        // The class's own if it has one, or else what it inherits.
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (AnyObject) -> NSArray? = { responder in
            let own = original(responder, selector) as? [UIKeyCommand] ?? []
            // Mid-composition the keys belong to the input method.
            let composing = MainActor.assumeIsolated { (responder as? UITextInput)?.markedTextRange != nil }
            if composing { return own as NSArray }
            return MainActor.assumeIsolated { own + [toggle] + extra() } as NSArray
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

    @objc func kitUndoKey(_ command: UIKeyCommand) {
        MainActor.assumeIsolated { _ = CommandNotices.shared.undoLatest() }
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

// MARK: - Notices on the monitor (0.9)

/// The notices showing now, for the whole app: what commands did, Undo, failures, and "Finish on the phone". Post
/// here rather than to a phone-only toast, and put a `CommandNoticeStack` in the monitor's scene (and the phone's, if
/// it has no toasts of its own), so the result shows where the person is looking. ⌘Z runs the latest Undo while it
/// shows, unless the app or a text field takes ⌘Z first.
@MainActor
final class CommandNotices: ObservableObject {
    static let shared = CommandNotices()

    @Published private(set) var board = CommandNoticeBoard()
    private var timer: Task<Void, Never>?

    init() {}

    var showing: [CommandNotice] { board.showing }
    var canUndo: Bool { board.canUndo }

    /// "Renamed.", "Moved 3 to Inbox."
    @discardableResult func say(_ text: String, detail: String? = nil) -> Int {
        change(text) { $0.say(text, detail: detail) }
    }

    /// What went wrong: "Couldn't save. The server didn't answer."
    @discardableResult func fail(_ text: String, detail: String? = nil) -> Int {
        change(text) { $0.fail(text, detail: detail) }
    }

    /// "Deleted 3 items." with Undo, which ⌘Z runs too while it shows.
    @discardableResult func undoable(_ text: String, detail: String? = nil, undo: @escaping () -> Void) -> Int {
        change(text) { $0.undoable(text, detail: detail, undo: undo) }
    }

    /// "Finish on the phone", with what to do there. Goes by itself after a while; `finishedOnPhone()` takes it down.
    @discardableResult func phone(_ detail: String, text: String = "Finish on the phone") -> Int {
        change(text) { $0.phone(detail, text: text) }
    }

    func dismiss(_ id: Int) { change(nil) { $0.dismiss(id) } }

    /// The phone's part is done (the picker closed, Face ID answered).
    func finishedOnPhone() { change(nil) { $0.finishedOnPhone() } }

    /// Runs the latest Undo showing, as ⌘Z does. False when there's none.
    @discardableResult func undoLatest() -> Bool {
        guard let undo = change(nil, { $0.takeUndo() }) else { return false }
        undo()
        return true
    }

    /// Runs one notice's Undo: its button.
    func undo(_ id: Int) {
        change(nil) { $0.takeUndo(id) }?()
    }

    /// "Undo: Deleted 3 items" for the app's command list, while there's one to undo; its action should call
    /// `undoLatest()`.
    func undoRow<Action>(_ action: Action) -> CommandRow<Action>? { board.undoRow(action) }

    /// The host's part of `CommandRow.onPhone`: say so on the monitor, and take it down once a sheet has come up on
    /// the phone and gone again.
    func handOff(_ detail: String) {
        let id = phone(detail)
        watch(id, seen: false)
    }

    private func watch(_ id: Int, seen: Bool) {
        guard board.showing.contains(where: { $0.id == id }) else { return }
        let up = CommandScreen.sheetIsUp
        if seen && !up {
            dismiss(id)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.watch(id, seen: seen || up) }
    }

    private func change<T>(_ said: String?, _ body: (inout CommandNoticeBoard) -> T) -> T {
        let result = body(&board)
        board.expire()
        schedule()
        if let said { UIAccessibility.post(notification: .announcement, argument: said) }
        return result
    }

    private func schedule() {
        timer?.cancel()
        guard let due = board.nextExpiry else { return }
        let wait = max(0.05, due.timeIntervalSinceNow)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func tick() {
        board.expire()
        schedule()
    }
}

/// The notices, stacked: put it at the bottom of the monitor's scene. `z` scales it with the rest of the monitor.
/// The default card is in system materials; pass `card:` to draw them in the app's own design.
struct CommandNoticeStack<Card: View>: View {
    @ObservedObject private var notices: CommandNotices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let z: CGFloat
    private let card: (CommandNotice) -> Card

    @MainActor
    init(notices: CommandNotices? = nil, z: CGFloat = 1, @ViewBuilder card: @escaping (CommandNotice) -> Card) {
        self.notices = notices ?? .shared; self.z = z; self.card = card
    }

    var body: some View {
        VStack(spacing: 8 * z) {
            ForEach(notices.showing) { notice in
                card(notice)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: notices.showing.map(\.id))
    }
}

extension CommandNoticeStack where Card == CommandNoticeCard {
    @MainActor
    init(notices: CommandNotices? = nil, z: CGFloat = 1) {
        self.init(notices: notices, z: z) { CommandNoticeCard(notice: $0, z: z) }
    }
}

/// One notice in system materials: its symbol, its words, and Undo (⌘Z) when it has one. Failures are red.
struct CommandNoticeCard: View {
    let notice: CommandNotice
    var z: CGFloat = 1

    var body: some View {
        HStack(spacing: 12 * z) {
            Image(systemName: notice.symbol)
                .font(.system(size: 18 * z, weight: .medium))
                .foregroundStyle(notice.kind == .failure ? Color.red : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2 * z) {
                Text(notice.text).font(.system(size: 17 * z, weight: .medium)).foregroundStyle(.primary)
                if let detail = notice.detail {
                    Text(detail).font(.system(size: 14 * z)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8 * z)
            if notice.kind == .undo {
                Button { CommandNotices.shared.undo(notice.id) } label: {
                    HStack(spacing: 6 * z) {
                        Text("Undo").font(.system(size: 16 * z, weight: .semibold))
                        Text("⌘Z").font(.system(size: 13 * z)).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16 * z).padding(.vertical, 10 * z)
        .frame(maxWidth: 560 * z, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12 * z, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#endif
