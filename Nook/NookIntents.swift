//
//  NookIntents.swift
//  Nook
//
//  App Intents: add journal entries (and query the inbox) from Shortcuts, Siri,
//  and Spotlight without opening the app. They write straight to the journal
//  folder via JournalStore's headless helpers.
//
//  Also declares:
//  - OpenNewDraftIntent  — opens the app directly to the Write screen.
//    Used by the widget "New Draft" link and home screen quick actions.
//  - Home screen quick actions are registered dynamically on launch in
//    NookApp (UIApplicationShortcutItem).
//

import AppIntents
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Add entry (background, no open)

/// Add a new draft to the Nook inbox.
struct AddJournalEntryIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Journal Entry"
    static var description = IntentDescription("Adds a new draft to your Nook inbox.")
    static var openAppWhenRun = false

    @Parameter(title: "Entry", requestValueDialog: "What do you want to write?")
    var body: String

    @Parameter(title: "Title")
    var title: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$body) to Nook") {
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

// MARK: - Inbox count (background)

/// Report how many drafts are waiting in the inbox.
struct InboxCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Inbox Draft Count"
    static var description = IntentDescription("Returns how many drafts are waiting in your Nook inbox.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = JournalStore.inboxDraftCount()
        return .result(value: count,
                       dialog: count == 1 ? "1 draft in your inbox." : "\(count) drafts in your inbox.")
    }
}

// MARK: - Open Write screen (opens app)

/// Opens Nook directly to a blank Write screen. Used by the widget
/// "New Draft" link and the home screen long-press quick action.
struct OpenNewDraftIntent: AppIntent {
    static var title: LocalizedStringResource = "New Draft"
    static var description = IntentDescription("Opens Nook to a blank Write screen.")
    // openAppWhenRun = true is the default — keep it so the app launches.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Post a notification the app's NavigationModel listens to.
        NotificationCenter.default.post(name: .nookOpenWrite, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let nookOpenWrite = Notification.Name("com.caddickbrown.nook.openWrite")
}

// MARK: - Siri / Spotlight shortcuts

/// Phrases exposed to Siri / Spotlight.
struct NookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenNewDraftIntent(),
            phrases: [
                "New draft in \(.applicationName)",
                "Write in \(.applicationName)",
                "Open \(.applicationName) to write",
                "Start a new entry in \(.applicationName)",
            ],
            shortTitle: "New Draft",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: AddJournalEntryIntent(),
            phrases: [
                "Add a journal entry to \(.applicationName)",
                "New entry in \(.applicationName)",
            ],
            shortTitle: "Add Entry",
            systemImageName: "plus.square"
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

// MARK: - Home screen quick actions (iOS only)

#if canImport(UIKit)
enum NookQuickAction: String {
    case newDraft   = "com.caddickbrown.nook.newDraft"
    case openInbox  = "com.caddickbrown.nook.openInbox"

    var shortcutItem: UIApplicationShortcutItem {
        switch self {
        case .newDraft:
            return UIApplicationShortcutItem(
                type: rawValue,
                localizedTitle: "New Draft",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil"),
                userInfo: nil
            )
        case .openInbox:
            return UIApplicationShortcutItem(
                type: rawValue,
                localizedTitle: "Inbox",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "tray"),
                userInfo: nil
            )
        }
    }

    /// Register both quick actions. Call from `application(_:didFinishLaunchingWithOptions:)`.
    static func register() {
        UIApplication.shared.shortcutItems = [
            NookQuickAction.newDraft.shortcutItem,
            NookQuickAction.openInbox.shortcutItem,
        ]
    }

    /// Handle a shortcut item; returns true if handled.
    @MainActor
    static func handle(_ item: UIApplicationShortcutItem, nav: NavigationModel) -> Bool {
        switch NookQuickAction(rawValue: item.type) {
        case .newDraft:
            nav.requestNewEntry()
            return true
        case .openInbox:
            nav.section = .inbox
            return true
        case nil:
            return false
        }
    }
}
#endif
