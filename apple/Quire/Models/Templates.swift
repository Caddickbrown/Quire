//
//  Templates.swift
//  Quire
//
//  Entry templates and writing prompts.
//
//  Templates are plain markdown files in `<base>/.quire/templates/` — synced by
//  iCloud like everything else, hand-editable, invisible to jnl. The composer
//  inserts one into the body with `{{date}}` / `{{time}}` / `{{weekday}}`
//  substituted. Prompts are a bundled list; the composer shows one as its
//  placeholder when the setting is on, rotating daily (dice to reroll).
//

import Foundation

// MARK: - Templates (files under <base>/.quire/templates/)

extension JournalStore {
    private struct Template: Decodable { let name: String; let body: String }
    func templateNames() -> [String] {
        guard let core, let templates: [Template] = try? core.call("templates") else { return [] }
        return templates.map(\.name)
    }
    func templateBody(named name: String) -> String? {
        guard let core, let templates: [Template] = try? core.call("templates"),
              let template = templates.first(where: { $0.name == name }) else { return nil }
        return Self.substitute(template.body, date: Date())
    }
    @discardableResult
    func createTemplate(named requested: String = "New Template") -> String? {
        guard let core else { return nil }
        var name = requested, n = 2
        let names = Set(templateNames())
        while names.contains(name) { name = "\(requested) \(n)"; n += 1 }
        do {
            let _: Bool = try core.call("save_template", ["name": name, "body": "What made today worth writing about?\n\n- [ ] One thing to remember\n- [ ] One thing to let go\n\n{{weekday}} {{date}}\n"])
            return name
        } catch { lastWriteError = journalErrorMessage(error); return nil }
    }
    func deleteTemplate(named name: String) {
        do { if let core { let _: Bool = try core.call("delete_template", ["name": name]) } }
        catch { lastWriteError = journalErrorMessage(error) }
    }
    #if os(macOS)
    func revealTemplates() {
        guard let core, let baseURL, let sidecar = try? core.sidecar(write: true) else { return }
        let dir = baseURL.appendingPathComponent(sidecar + "/templates")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspaceReveal(dir)
    }
    #endif

    /// Fill `{{date}}` / `{{time}}` / `{{weekday}}` (pure, testable).
    nonisolated static func substitute(_ template: String, date: Date) -> String {
        // `{{date}}`/`{{time}}` are ISO-shaped and match the header format on
        // disk, so they must not follow the locale: a Japanese or Buddhist
        // calendar would render a different year, and a 12-hour locale a
        // different clock.
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd"
        let dateStr = iso.string(from: date)
        iso.dateFormat = "HH:mm"
        let timeStr = iso.string(from: date)
        // `{{weekday}}` is prose, so it stays in the reader's language.
        let display = DateFormatter()
        display.locale = .current
        display.dateFormat = "EEEE"
        let weekday = display.string(from: date)
        return template
            .replacingOccurrences(of: "{{date}}", with: dateStr)
            .replacingOccurrences(of: "{{time}}", with: timeStr)
            .replacingOccurrences(of: "{{weekday}}", with: weekday)
    }
}

#if os(macOS)
import AppKit
private func NSWorkspaceReveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
#endif

// MARK: - Writing prompts

/// A bundled deck of composer prompts. Deterministic per day (everyone's
/// "prompt of the day" is stable across relaunches), with a reroll that walks
/// the deck.
enum PromptDeck {
    static let enabledKey = "writingPrompts"

    static let prompts: [String] = [
        "What surprised you today?",
        "What would you tell yourself a year ago?",
        "Describe where you are right now — all five senses.",
        "What's the smallest thing that made you smile lately?",
        "What are you avoiding writing about?",
        "Who did you last have a real conversation with?",
        "What did you almost do today?",
        "What's changed since this time last month?",
        "Write about something you're looking forward to.",
        "What's a question you can't answer yet?",
        "What did you notice on the way somewhere today?",
        "What would you do with a free afternoon tomorrow?",
        "What's worth remembering about this week?",
        "Describe today in exactly three sentences.",
        "What are you carrying that you could put down?",
        "What did you learn the hard way recently?",
        "Write the first paragraph of the story of today.",
        "What sound, smell, or taste took you somewhere else?",
        "What do you want more of? Less of?",
        "Who deserves a thank-you you haven't sent?",
    ]

    /// The prompt for a given day, plus `offset` rerolls.
    static func prompt(for date: Date = Date(), offset: Int = 0) -> String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        let index = ((day + offset) % prompts.count + prompts.count) % prompts.count
        return prompts[index]
    }
}
