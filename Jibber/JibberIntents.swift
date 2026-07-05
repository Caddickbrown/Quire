//
//  JibberIntents.swift
//  Jibber
//
//  App Intents: add journal entries (and query the inbox) from Shortcuts, Siri,
//  and Spotlight without opening the app. They write straight to the journal
//  folder via JournalStore's headless helpers.
//

import AppIntents

/// Add a new draft to the Jibber inbox.
struct AddJournalEntryIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Journal Entry"
    static var description = IntentDescription("Adds a new draft to your Jibber inbox.")
    static var openAppWhenRun = false

    @Parameter(title: "Entry", requestValueDialog: "What do you want to write?")
    var body: String

    @Parameter(title: "Title")
    var title: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$body) to Jibber") {
            \.$title
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let added = try JournalStore.quickAddDraft(title: title ?? "", body: body)
        return .result(dialog: added
                       ? "Added to your journal inbox."
                       : "There was nothing to add.")
    }
}

/// Report how many drafts are waiting in the inbox.
struct InboxCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Inbox Draft Count"
    static var description = IntentDescription("Returns how many drafts are waiting in your Jibber inbox.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = JournalStore.inboxDraftCount()
        return .result(value: count,
                       dialog: count == 1 ? "1 draft in your inbox." : "\(count) drafts in your inbox.")
    }
}

/// Phrases exposed to Siri / Spotlight.
struct JibberShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddJournalEntryIntent(),
            phrases: [
                "Add a journal entry to \(.applicationName)",
                "New entry in \(.applicationName)",
                "Write in \(.applicationName)",
            ],
            shortTitle: "Add Entry",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: InboxCountIntent(),
            phrases: [
                "How many drafts are in \(.applicationName)",
                "\(.applicationName) inbox count",
            ],
            shortTitle: "Inbox Count",
            systemImageName: "tray"
        )
    }
}
