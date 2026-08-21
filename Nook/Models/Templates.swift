//
//  Templates.swift
//  Nook
//
//  Entry templates and writing prompts.
//
//  Templates are plain markdown files in `<base>/.nook/templates/` — synced by
//  iCloud like everything else, hand-editable, invisible to jnl. The composer
//  inserts one into the body with `{{date}}` / `{{time}}` / `{{weekday}}`
//  substituted. Prompts are a bundled list; the composer shows one as its
//  placeholder when the setting is on, rotating daily (dice to reroll).
//

import Foundation

// MARK: - Templates (files under <base>/.nook/templates/)

extension JournalStore {
    private var templatesDirURL: URL? {
        baseURL?.appendingPathComponent(".nook", isDirectory: true)
            .appendingPathComponent("templates", isDirectory: true)
    }

    /// Template names (file basenames, sorted), read live from disk.
    func templateNames() -> [String] {
        guard let dir = templatesDirURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return items
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// A template's content with `{{date}}`, `{{time}}` and `{{weekday}}` filled in.
    func templateBody(named name: String) -> String? {
        guard let dir = templatesDirURL,
              let raw = try? String(contentsOf: dir.appendingPathComponent("\(name).md"), encoding: .utf8)
        else { return nil }
        return Self.substitute(raw, date: Date())
    }

    /// Create a starter template the user can edit (in-app or in any editor).
    /// Returns the name it was created under (suffixed if taken).
    @discardableResult
    func createTemplate(named requested: String = "New Template") -> String? {
        guard let dir = templatesDirURL else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = requested
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name).md").path) {
            name = "\(requested) \(n)"; n += 1
        }
        let starter = """
        What made today worth writing about?

        - [ ] One thing to remember
        - [ ] One thing to let go

        {{weekday}} {{date}}
        """
        try? Data(starter.utf8).write(to: dir.appendingPathComponent("\(name).md"), options: .atomic)
        return name
    }

    func deleteTemplate(named name: String) {
        guard let dir = templatesDirURL else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(name).md"))
    }

    #if os(macOS)
    func revealTemplates() {
        guard let dir = templatesDirURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspaceReveal(dir)
    }
    #endif

    /// Fill `{{date}}` / `{{time}}` / `{{weekday}}` (pure, testable).
    nonisolated static func substitute(_ template: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "yyyy-MM-dd"
        let dateStr = f.string(from: date)
        f.dateFormat = "HH:mm"
        let timeStr = f.string(from: date)
        f.dateFormat = "EEEE"
        let weekday = f.string(from: date)
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
