//
//  SettingsView.swift
//  Quire
//
//  Appearance, writing font, date format, the journal folder, and maintenance
//  actions (jnl cleanup / export / open). Shown as a sidebar section.
//

import SwiftUI
import UniformTypeIdentifiers

/// The pages the settings are split into on the phone; each shows only its own sections.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case looks, reminders, privacy, display, journal, folder, media, maintenance, help
    var id: String { rawValue }
}

struct SettingsView: View {
    /// nil shows everything (the earlier single page); a group shows just its own sections.
    var group: SettingsGroup? = nil
    private func shows(_ g: SettingsGroup) -> Bool { group == nil || group == g }

    @EnvironmentObject private var store: JournalStore
    @ObservedObject private var externalDisplay = ExternalDisplayModel.shared
    /// The strip of keys along the bottom of the monitor (also `?`).
    @AppStorage(ShortcutHints.key) private var showMonitorHints = true
    @AppStorage("colorScheme") private var colorSchemeRaw: String = AppColorScheme.auto.rawValue
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage("accentColor") private var accentRaw: String = AccentTheme.blue.rawValue
    @AppStorage("highlightTags") private var highlightTags = true
    @AppStorage("firstWeekday") private var firstWeekday = 1
    @AppStorage("showWeekNumbers") private var showWeekNumbers = false
    @AppStorage(ExternalTheme.key) private var externalThemeRaw = ExternalTheme.followPhone
    @AppStorage(ExternalDisplayModel.autoDimKey) private var dimWithExternalDisplay = false
    @AppStorage(ExternalDisplayModel.dimLevelKey) private var externalDisplayDimLevel = ExternalDisplayModel.dimFloor
    @AppStorage(ExternalTextSize.key) private var externalTextSizeRaw = ExternalTextSize.regular.rawValue
    @AppStorage("inboxSwipeLeft") private var swipeLeftRaw = SwipeAction.file.rawValue
    @AppStorage("inboxSwipeRight") private var swipeRightRaw = SwipeAction.delete.rawValue
    @AppStorage("splitTags") private var splitTagsRaw: String = ""
    @AppStorage("dataSaver") private var dataSaver = false
    @AppStorage(JournalStore.backupIntervalKey) private var backupIntervalRaw = BackupInterval.off.rawValue
    @AppStorage(JournalStore.backupKeepKey) private var backupKeepCount = 10
    @AppStorage("typewriterScroll") private var typewriterScroll = false
    @AppStorage("focusParagraph") private var focusParagraph = false
    @AppStorage(PromptDeck.enabledKey) private var promptsOn = false
    @AppStorage("wordGoalEnabled") private var wordGoalEnabled = false
    @AppStorage("wordGoal") private var wordGoal = 750
    @AppStorage(ReminderScheduler.enabledKey) private var reminderOn = false
    @AppStorage(ReminderScheduler.hourKey) private var reminderHour = ReminderScheduler.defaultHour
    @AppStorage(ReminderScheduler.minuteKey) private var reminderMinute = 0
    @AppStorage(ResurfacingScheduler.enabledKey) private var weeklyResurfaceOn = false
    @AppStorage(ResurfacingScheduler.weekdayKey) private var weeklyWeekday = ResurfacingScheduler.defaultWeekday
    @AppStorage(ResurfacingScheduler.hourKey) private var weeklyHour = ResurfacingScheduler.defaultHour
    @AppStorage(AppLockManager.enabledKey) private var appLockOn = false
    @AppStorage(AppLockManager.graceKey) private var appLockGrace = 0.0
    @AppStorage(SpotlightIndexer.enabledKey) private var spotlightOn = false
    @AppStorage(JournalStore.autoTranscribeKey) private var autoTranscribe = false

    static let shortcuts: [(action: String, keys: String)] = [
        ("New entry", "⌘N"),
        ("Save", "⌘S"),
        ("Bold / italic selection", "⌘B / ⌘I"),
        ("Write", "⌘1"),
        ("Inbox", "⌘2"),
        ("Journal", "⌘3"),
        ("Tags", "⌘4"),
        ("Search everything", "⌘⇧F"),
        ("Random entry (Archive)", "⌘R"),
        ("Settings", "⌘,"),
    ]

    static let howTos: [(title: String, body: String)] = [
        ("Writing & autosave",
         """
         Write in the composer — a title line (optional) and the body. Everything \
         autosaves continuously into an inbox draft, so you never press Save. Start a \
         fresh entry with ⌘N. The ⋯ menu can "Promote first line to title" or "Discard" \
         a draft you don't want to keep.
         """),
        ("The Inbox — filing drafts",
         """
         Drafts live in the Inbox until you file them into the dated journal. File from \
         the ⋯/context menu, or (on iPhone/iPad) swipe a row — swipe directions are \
         configurable in Settings → Inbox swipe. "File All" files every draft at once; \
         "Sort file by date" reorders drafts in inbox/YYYY/MM/DD.md. Drafts are grouped by date.
         """),
        ("The Journal — browsing",
         """
         The Journal lists every filed entry grouped under date headers; pick one to open \
         it beside the list (macOS) or push to it (iOS). Search filters entries, the Sort \
         menu flips newest/oldest, and Random (⌘R) jumps to a surprise entry. The mini \
         calendar in the sidebar jumps to a specific day.
         """),
        ("Tags & Tag Review",
         """
         The Tags section is a rail of coloured chips — tap one to see its entries \
         (inbox drafts show an "Inbox" badge). Search filters the rail; Random picks a \
         tag. Settings → Tag Review finds tags that differ only by case (@tags/@Tags) or \
         a single letter, and merges the ones you choose in one pass.
         """),
        ("Photos, video & audio",
         """
         Attach media from the ⋯ menu — on iOS pick from your Photo Library or Choose \
         File; on macOS pick a file — or drag a photo or file onto the editor. Record a voice \
         memo with the mic button (a Stop banner appears while recording), or "Record \
         Video" from the ⋯ menu. Files are copied into an assets/ folder and stored as \
         ![](assets/…) links — switch to Preview to see them inline. Rows show a small \
         photo/mic/film/paperclip badge for what they contain; browse everything under \
         Assets.
         """),
        ("Formatting & copying",
         """
         Wrap text in __double underscores__ to italicise it, **double asterisks** to \
         bold, or `backticks` for code — all render live while editing, and ⌘B/⌘I wrap \
         the selection for you. Pressing ↩ inside a "- ", "1. " or "- [ ]" line continues \
         the list (↩ on an empty item ends it), and Preview draws "- [ ]" lines as \
         tappable checkboxes that write the ✓ back into the markdown. Preview renders \
         markdown (bold, italics, links, lists) with your media inline. An entry's ⋯ menu \
         has "Copy text" to put its title + body on the clipboard.
         """),
        ("Search everything",
         """
         The Search section (⌘⇧F) looks across the inbox, journal and split journals at \
         once. Plain words match anywhere; quotes match an "exact phrase"; and operators \
         narrow it down: tag:work · before:2026-03 · after:2025 · has:image (or video / \
         audio / media) · is:starred. Every clause must match.
         """),
        ("Voice memo transcription",
         """
         An entry with a voice memo can be transcribed from the ⋯ menu — the words are \
         recognised on this device (nothing is uploaded) and inserted beneath the audio \
         link as ordinary text, so the memo becomes searchable and taggable. The \
         recording itself stays attached.
         """),
        ("Templates & prompts",
         """
         Templates (Settings → Templates) are markdown files inserted from the composer's \
         ⋯ menu — a morning-pages skeleton, a weekly review with checkboxes, anything. \
         {{date}}, {{time}} and {{weekday}} fill in when inserted. Writing prompts \
         (Settings → Writing) show a question in the empty composer; the ⋯ menu deals a \
         new one.
         """),
        ("Importing another journal",
         """
         Settings → Maintenance → "Import from Day One" reads a Day One JSON export \
         (unzip it first, then pick the folder or its Journal.json): dates, text, photos \
         and tags all come across as ordinary filed entries. "Import Markdown Folder" \
         does the same for a folder of dated .md/.txt files (Obsidian daily notes work). \
         You'll see a count before anything is written, and re-running an import skips \
         entries that are already in place.
         """),
        ("Calendar, timer & focus",
         """
         The sidebar calendar marks days that have entries; swipe or use the arrows to \
         change month, and "Today" jumps back. The timer (bottom of the sidebar) counts \
         down a writing session — set its length in its menu. Focus mode (⌘⌥F) hides the \
         sidebar so it's just you and the page.
         """),
        ("Split journals (tag routing)",
         """
         Add tag names to "Split tags" above (e.g. work private). When you file a draft \
         containing that @tag, it's written to <folder>/split/<tag>/YYYY/MM/DD.md instead of the dated \
         journal and appears under "Split Journals". Routing happens at filing time, so \
         tag the draft first, then file it.
         """),
        ("Import as separate entries",
         """
         In Write, the ⋯ menu has "Import as separate entries". Paste text containing \
         multiple entries to split them into individual inbox drafts. Text with \
         [YYYY-MM-DD HH:MM:SS] headers splits per header (paste a whole inbox.md and it \
         separates cleanly); headerless text becomes a single draft.
         """),
        ("Backup",
         """
         Choose a backup folder above, then "Back Up Now" copies your whole journal \
         (inbox, journal, split journals, assets) into a timestamped folder there. \
         Everything is plain files, so a backup is a full, openable copy.
         """),
        ("Maintenance",
         """
         Clean Up normalises punctuation (… and straight quotes), reorders entries by \
         time, removes exact duplicates, and retroactively moves any entry matching a \
         split tag into split/<tag>/YYYY/MM/DD.md — so adding a split tag later pulls matching \
         history out too. Clear Orphan Media deletes asset files no entry references any \
         more. Export combines all filed entries into one markdown file (drafts still in \
         the Inbox aren't included until you file them).
         """),
        ("Storage, iCloud & jnl",
         """
         By default your journal lives in iCloud so it syncs across devices, with a local \
         fallback when iCloud is off. Point "Journal folder" at any folder — including an \
         existing jnl notes folder — to share inbox/YYYY/MM/DD.md and journal/YYYY/MM/DD.md \
         files with the jnl CLI. Changes from other devices or the CLI appear as they \
         sync; for a local folder, edits saved directly into an existing day file show up \
         when Quire next comes to the foreground. The Stats sheet breaks size into text vs \
         media.
         """),
    ]

    private enum MaintenanceAction: String, Identifiable {
        case fileAll, transfer, conflicts
        var id: String { rawValue }
        var title: String {
            switch self { case .fileAll: return "File every draft?"; case .transfer: return "File transfer.md?"; case .conflicts: return "Merge conflict copies?" }
        }
    }
    @State private var maintenanceAction: MaintenanceAction?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDoc = ExportDocument(text: "")
    @State private var showingCleanup = false
    @State private var cleanupMessage = ""
    @State private var showingNothingToExport = false
    @State private var showingBackupPicker = false
    @State private var backupMessage: String?
    @State private var showingTagReview = false
    @State private var showingChangelog = false
    @State private var expandedHowTos: Set<String> = []
    @State private var orphanCount = 0
    @State private var showingOrphanConfirm = false
    @State private var showingNoOrphans = false
    @State private var orphanCleared: Int?
    @State private var showingReminderDenied = false
    @State private var templateNames: [String] = []
    @State private var showingDayOnePicker = false
    @State private var showingFolderPicker = false
    @State private var pendingImport: ImportPreview?
    @State private var showingImportConfirm = false
    @State private var showingNothingToImport = false
    @State private var showingPDFSheet = false
    @State private var showingRestore = false

    var body: some View {
        QSettingsContainer {
            if shows(.looks) {
            Section {
                // On the iPhone these belong to the earlier look (Nook's light/dark switch,
                // Lato, eight accent colours, week options); Quire's themes replace them.
                if group == nil {
                Picker("Theme", selection: $colorSchemeRaw) {
                    ForEach(AppColorScheme.allCases) { scheme in
                        Text(scheme.displayName).tag(scheme.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Writing font", selection: $writingFontRaw) {
                    ForEach(WritingFont.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                }
                Picker("Text size", selection: $fontSize) {
                    ForEach(Theme.fontSizes, id: \.self) { s in
                        Text("\(Int(s)) px").tag(Double(s))
                    }
                }
                if group == nil {
                Picker("Date format", selection: $dateStyleRaw) {
                    ForEach(DateStyle.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                accentPicker
                Toggle("Highlight @tags", isOn: $highlightTags)
                Picker("Start week on", selection: $firstWeekday) {
                    Text("Sunday").tag(1)
                    Text("Monday").tag(2)
                    Text("Saturday").tag(7)
                }
                Toggle("Show week numbers", isOn: $showWeekNumbers)
                }
            } header: {
                QLabel("Appearance")
            }
            .qRowBackground()
            }

            if shows(.looks) {
            Section {
                if group == nil {
                Toggle("Typewriter scrolling", isOn: $typewriterScroll)
                Toggle("Focus current paragraph", isOn: $focusParagraph)
                }
                Toggle("Writing prompts", isOn: $promptsOn)
                if group == nil {
                Toggle("Transcribe voice memos automatically", isOn: $autoTranscribe)
                }
                // onChange sits on the controls, not the Section: a modified
                // Section is no longer a Section to the enclosing Form.
                Toggle("Daily word goal", isOn: $wordGoalEnabled)
                    .onChange(of: wordGoalEnabled) { _, _ in store.reload() }
                if wordGoalEnabled {
                    Stepper("Goal: \(wordGoal) words", value: $wordGoal, in: 50...5000, step: 50)
                        .onChange(of: wordGoal) { _, _ in store.reload() }
                }
            } header: {
                QLabel("Writing")
            } footer: {
                Text("Typewriter scrolling keeps the line you're typing centred; focus dims everything but the current paragraph. Prompts show a question in the empty composer. The word goal counts everything dated today and shows a quiet ring by the timer.")
            }
            .qRowBackground()
            }

            if shows(.reminders) {
            Section {
                Toggle("Daily reminder", isOn: $reminderOn)
                    .onChange(of: reminderOn) { _, on in
                        if on {
                            Task {
                                if await ReminderScheduler.requestPermission() {
                                    refreshReminder()
                                } else {
                                    reminderOn = false
                                    showingReminderDenied = true
                                }
                            }
                        } else {
                            refreshReminder()
                        }
                    }
                if reminderOn {
                    DatePicker("Remind me at", selection: reminderTimeBinding,
                               displayedComponents: .hourAndMinute)
                        .onChange(of: reminderHour) { _, _ in refreshReminder() }
                        .onChange(of: reminderMinute) { _, _ in refreshReminder() }
                }
                Toggle("Weekly \u{201C}From your journal\u{201D}", isOn: $weeklyResurfaceOn)
                    .onChange(of: weeklyResurfaceOn) { _, on in
                        if on {
                            Task {
                                if await ReminderScheduler.requestPermission() {
                                    ResurfacingScheduler.settingsChanged(store: store)
                                } else {
                                    weeklyResurfaceOn = false
                                    showingReminderDenied = true
                                }
                            }
                        } else {
                            ResurfacingScheduler.settingsChanged(store: store)
                        }
                    }
                if weeklyResurfaceOn {
                    Picker("On", selection: $weeklyWeekday) {
                        Text("Sunday").tag(1); Text("Monday").tag(2); Text("Tuesday").tag(3)
                        Text("Wednesday").tag(4); Text("Thursday").tag(5)
                        Text("Friday").tag(6); Text("Saturday").tag(7)
                    }
                    .onChange(of: weeklyWeekday) { _, _ in ResurfacingScheduler.settingsChanged(store: store) }
                    Picker("Around", selection: $weeklyHour) {
                        ForEach(6..<23, id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .onChange(of: weeklyHour) { _, _ in ResurfacingScheduler.settingsChanged(store: store) }
                }
            } header: {
                QLabel("Reminder")
            } footer: {
                Text("The daily reminder fires only on days you haven't written yet — an entry before the reminder time quietly cancels it — and takes a quick line right in the banner. The weekly note resurfaces one entry (starred first, then this day in past years); tapping it opens the entry.")
            }
            .qRowBackground()
            }

            if shows(.privacy) {
            Section {
                Toggle("Require Face ID / Touch ID", isOn: $appLockOn)
                    .onChange(of: appLockOn) { _, _ in AppLockManager.shared.preferenceChanged() }
                    .disabled(!AppLockManager.canAuthenticate() && !appLockOn)
                if appLockOn {
                    Picker("Relock", selection: $appLockGrace) {
                        Text("Immediately").tag(0.0)
                        Text("After 1 minute").tag(60.0)
                        Text("After 5 minutes").tag(300.0)
                        Text("After 15 minutes").tag(900.0)
                    }
                }
                Toggle("Show entries in Spotlight", isOn: $spotlightOn)
                    .onChange(of: spotlightOn) { _, _ in
                        SpotlightIndexer.scheduleReindex(source: { store.spotlightSource() })
                    }
            } header: {
                QLabel("Privacy")
            } footer: {
                Text("The lock covers the app only — your files stay plain markdown on disk and remain readable in \(fileBrowserName). Spotlight indexing (off by default) lets system search find entry titles and text; results open the entry in Quire.")
            }
            .qRowBackground()
            }

            #if os(iOS)
            if shows(.display) {
            Section {
                Picker("Theme", selection: $externalThemeRaw) {
                    Text("Same as phone").tag(ExternalTheme.followPhone)
                    ForEach(ExternalTheme.all) { Text($0.name).tag($0.id) }
                }
                Toggle("Pause external display", isOn: Binding(get: { externalDisplay.isPaused }, set: { value in
                    if externalDisplay.isPaused != value { externalDisplay.togglePause() }
                })).disabled(!externalDisplay.isConnected)
                Picker("Text size", selection: $externalTextSizeRaw) {
                    ForEach(ExternalTextSize.allCases) { Text($0.label).tag($0.rawValue) }
                }
                // onChange sits on the controls, not the Section: a modified
                // Section is no longer a Section to the enclosing Form.
                Toggle("Show key hints on the monitor", isOn: $showMonitorHints)
                Toggle("Dim this screen", isOn: $dimWithExternalDisplay)
                    .onChange(of: dimWithExternalDisplay) { _, _ in
                        ExternalDisplayModel.shared.autoDimPreferenceChanged()
                    }
                if dimWithExternalDisplay {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Dim to")
                            Spacer()
                            Text("\(Int(externalDisplayDimLevel * 100))%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $externalDisplayDimLevel,
                               in: ExternalDisplayModel.dimFloor...0.5)
                    }
                    .onChange(of: externalDisplayDimLevel) { _, _ in
                        ExternalDisplayModel.shared.autoDimPreferenceChanged()
                    }
                }
            } header: {
                QLabel("External display")
            } footer: {
                Text("Connected to a monitor, Quire shows your writing on it instead of mirroring, and the keys are the terminal app's, printed along the bottom of the monitor. ↑↓ or j/k browse, Return opens, Esc goes back; n writes, / searches, i inbox, j journal, l look back, r a random entry. In a list: f files, e edits, * stars, t sets the date and time, d deletes. While writing: ^J files, ^S saves, ^T date and time, ^F focus, ^P a prompt, ^D discards, Esc is done. ⌥⌘± changes text size, ⌥⌘T the theme, ⌥⌘P pauses. These controls leave the device's appearance alone. Dimming this screen never affects what's up there, and turning it down saves power; it's restored when you unplug.")
            }
            .qRowBackground()
            }

            if group == nil {
            Section {
                Picker("Swipe left", selection: $swipeLeftRaw) {
                    ForEach(SwipeAction.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Swipe right", selection: $swipeRightRaw) {
                    ForEach(SwipeAction.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } header: {
                QLabel("Inbox swipe")
            }
            .qRowBackground()
            }
            #endif

            if shows(.journal) {
            Section {
                SplitTagsEditor(raw: $splitTagsRaw)
            } header: {
                QLabel("Split tags")
            } footer: {
                Text("Entries containing these @tags file into <folder>/split/<tag>/YYYY/MM/DD.md instead of the date journal (jnl JNL_SPLIT_TAGS). Space or comma separated.")
            }
            .qRowBackground()
            }

            if shows(.journal) {
            Section {
                ForEach(templateNames, id: \.self) { name in
                    HStack {
                        Label(name, systemImage: "doc.on.doc.fill")
                        Spacer()
                        Button(role: .destructive) {
                            store.deleteTemplate(named: name)
                            templateNames = store.templateNames()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .destructiveAction()
                        .help("Delete template")
                    }
                }
                buttonRow {
                    Button {
                        store.createTemplate()
                        templateNames = store.templateNames()
                    } label: {
                        Label("New Template", systemImage: "plus")
                    }
                    #if os(macOS)
                    Button { store.revealTemplates() } label: {
                        Label("Show in Finder", systemImage: "magnifyingglass")
                    }
                    #endif
                }
            } header: {
                QLabel("Templates")
            } footer: {
                Text("Plain markdown files in <folder>/.quire/templates/ — edit them here or in any editor; they sync with the journal. Insert one from the composer's ⋯ menu; {{date}}, {{time}} and {{weekday}} fill in on insert.")
            }
            .qRowBackground()
            }

            if shows(.folder) {
            Section {
                if let message = store.storageUnavailableMessage {
                    Label {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
                LabeledContent("Storage", value: store.storageMode.label)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location").foregroundStyle(.secondary)
                    Text(store.storagePath)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttonRow {
                    chooseFolderButton
                    if store.storageMode == .custom { useDefaultButton }
                    #if os(macOS)
                    showInFinderButton
                    #endif
                }
            } header: {
                QLabel("Journal folder")
            } footer: {
                Text(store.unavailableFolder == nil
                     ? "Quire stores drafts in inbox/YYYY/MM/DD.md and filed entries in journal/YYYY/MM/DD.md. Older jnl drafts and split journals are migrated on open; their originals are kept in .quire/migration/."
                     : "Quire won't save anything while the folder is missing, so nothing ends up in a second journal. Plug the drive back in and locate the folder, or take the default back — your entries stay where they are either way.")
            }
            .qRowBackground()
            }

            if shows(.folder) {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Backup folder").foregroundStyle(.secondary)
                    Text(store.backupFolderPath ?? "Not set")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttonRow {
                    chooseBackupButton
                    backupNowButton
                    restoreButton
                    #if os(macOS)
                    showBackupInFinderButton
                    #endif
                }
                Picker("Automatic backup", selection: $backupIntervalRaw) {
                    ForEach(BackupInterval.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .disabled(store.backupFolderName == nil)
                if backupIntervalRaw != BackupInterval.off.rawValue {
                    Stepper("Keep last \(backupKeepCount) backups",
                            value: $backupKeepCount, in: 1...50)
                }
                LabeledContent("Last backup") {
                    if store.backupRunning {
                        Text("Backing up…").foregroundStyle(.secondary)
                    } else if let last = store.lastBackupAt {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
            } header: {
                QLabel("Backup")
            } footer: {
                Text("Copies everything (inbox, journal, split journals, and assets) into a timestamped folder in the backup location. Automatic backups run in the background and prune down to the number you keep; “On every change” waits for a pause in writing and won't run more than once every five minutes.")
            }
            .qRowBackground()
            }

            if shows(.media) {
            Section {
                Toggle("Data Saver", isOn: $dataSaver)
                LabeledContent("Data saved",
                               value: ByteCountFormatter.string(fromByteCount: Int64(store.dataSaved), countStyle: .file))
                if let p = store.mediaProgress {
                    LabeledContent("Compressing", value: "\(p.done)/\(p.total)")
                }
            } header: {
                QLabel("Media")
            } footer: {
                Text("Compresses attached media to save space — photos (longest edge 2048 px), videos (720p H.264) and voice memos (low-bitrate AAC). The original format is kept so links stay valid; videos re-encode in the background after attaching. Existing media isn't touched until you run “Compress Existing Media” below. The tally is merged across your devices.")
            }
            .qRowBackground()
            }

            if shows(.maintenance) {
            Section {
                buttonRow {
                    cleanUpButton
                    Button("Sort Inbox") { store.sortInbox() }
                    Button("File All Drafts…") { maintenanceAction = .fileAll }
                    Button("File transfer.md…") { maintenanceAction = .transfer }
                    Button("Merge Conflict Copies…") { maintenanceAction = .conflicts }
                    compressMediaButton
                    transcribeAllButton
                    mergeExSplitButton
                    tagReviewButton
                    clearOrphanButton
                    exportButton
                    exportPDFButton
                    importDayOneButton
                    importFolderButton
                }
            } header: {
                QLabel("Maintenance")
            } footer: {
                Text("Export combines all filed entries into one markdown file (Export PDF typesets them instead). Import brings a Day One JSON export or a folder of dated markdown/text files in as ordinary filed entries — photos and tags included; re-running an import never duplicates. Drafts still in the Inbox aren't included in exports until you file them.")
            }
            .qRowBackground()
            }

            if shows(.help) {
            Section {
                ForEach(Self.shortcuts, id: \.action) { s in
                    HStack {
                        Text(s.action)
                        Spacer()
                        Text(s.keys)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                QLabel("Keyboard shortcuts")
            }
            .qRowBackground()
            }

            if shows(.help) {
            Section {
                Button { showingChangelog = true } label: {
                    Label("What's New", systemImage: "sparkles")
                }
            } header: {
                QLabel("About")
            } footer: {
                Text("Every release and what changed in it.")
            }
            .qRowBackground()
            }

            if shows(.help) {
            Section {
                ForEach(Self.howTos, id: \.title) { item in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedHowTos.contains(item.title) },
                        set: { open in
                            if open { expandedHowTos.insert(item.title) }
                            else { expandedHowTos.remove(item.title) }
                        }
                    )) {
                        Text(item.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(item.title)
                        #if os(macOS)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if expandedHowTos.contains(item.title) { expandedHowTos.remove(item.title) }
                                else { expandedHowTos.insert(item.title) }
                            }
                        #endif
                    }
                }
            } header: {
                QLabel("How to")
            }
            .qRowBackground()
            }
        }
        .formStyle(.grouped)
        .qFormSkin()
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: store.revision) { templateNames = store.templateNames() }
        .confirmationDialog(maintenanceAction?.title ?? "Maintenance", isPresented: Binding(get: { maintenanceAction != nil }, set: { if !$0 { maintenanceAction = nil } }), titleVisibility: .visible, presenting: maintenanceAction) { action in
            Button("Continue") {
                switch action {
                case .fileAll: cleanupMessage = "Filed \(store.fileAllDrafts()) drafts."
                case .transfer: cleanupMessage = "Filed \(store.fileTransfer()) entries from transfer.md."
                case .conflicts: cleanupMessage = "Merged \(store.mergeConflictCopies()) entries from conflict copies."
                }
                maintenanceAction = nil; showingCleanup = true
            }
            Button("Cancel", role: .cancel) { maintenanceAction = nil }
        }
        .alert("Backup", isPresented: Binding(
            get: { backupMessage != nil },
            set: { if !$0 { backupMessage = nil } }
        )) {
            Button("OK") { }
        } message: {
            Text(backupMessage ?? "")
        }
        .sheet(isPresented: $showingTagReview) {
            TagReviewView().environmentObject(store)
        }
        .sheet(isPresented: $showingChangelog) {
            ChangelogView()
        }
        .sheet(isPresented: $showingPDFSheet) {
            PDFExportSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $showingRestore) {
            RestoreSheet()
                .environmentObject(store)
        }
        .alert("Notifications are off", isPresented: $showingReminderDenied) {
            Button("OK") { }
        } message: {
            Text("Allow notifications for Quire in System Settings to use the daily reminder.")
        }
        .alert("Import \(pendingImport?.entries.count ?? 0) entries?", isPresented: $showingImportConfirm) {
            Button("Import") { runImport() }
            Button("Cancel", role: .cancel) { pendingImport = nil; endImportAccess() }
        } message: {
            if let p = pendingImport {
                Text("\(p.entries.count) entr\(p.entries.count == 1 ? "y" : "ies")\(p.mediaCount > 0 ? " and \(p.mediaCount) media file\(p.mediaCount == 1 ? "" : "s")" : ""), \(p.firstDate ?? "?") to \(p.lastDate ?? "?"). They'll be filed straight into the journal by date; entries already there are skipped.")
            }
        }
        .alert("Nothing to import", isPresented: $showingNothingToImport) {
            Button("OK") { }
        } message: {
            Text("No entries were found there. For Day One, pick the unzipped export folder or its Journal.json; for a folder import, files need a YYYY-MM-DD in their name or a creation date.")
        }
        .alert("Clear orphan media?", isPresented: $showingOrphanConfirm) {
            Button("Delete \(orphanCount)", role: .destructive) {
                orphanCleared = store.deleteOrphanAssets()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(orphanCount) media file\(orphanCount == 1 ? "" : "s") in assets/ \(orphanCount == 1 ? "is" : "are") not referenced by any entry. Delete \(orphanCount == 1 ? "it" : "them")?")
        }
        .alert("No orphan media", isPresented: $showingNoOrphans) {
            Button("OK") { }
        } message: {
            Text("Every media file is referenced by an entry.")
        }
        .alert("Orphan media cleared", isPresented: Binding(
            get: { orphanCleared != nil },
            set: { if !$0 { orphanCleared = nil } }
        )) {
            Button("OK") { }
        } message: {
            Text("Deleted \(orphanCleared ?? 0) unused media file\((orphanCleared ?? 0) == 1 ? "" : "s").")
        }
        .alert("Cleanup complete", isPresented: $showingCleanup) {
            Button("OK") { }
        } message: {
            Text(cleanupMessage)
        }
        .alert("Nothing to export", isPresented: $showingNothingToExport) {
            Button("OK") { }
        } message: {
            Text("Export only includes filed entries. File some drafts from the Inbox first.")
        }
    }

    /// A group of action buttons: laid out horizontally (wrapping) on macOS to
    /// save vertical space; stacked as full-width rows on iOS.
    @ViewBuilder
    private func buttonRow<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        #if os(macOS)
        FlowLayout(spacing: 8) { content() }
            .buttonStyle(.bordered)
        #else
        content()
        #endif
    }

    /// A row of tappable colour swatches for the app-wide accent.
    private var accentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accent colour")
            HStack(spacing: 12) {
                ForEach(AccentTheme.allCases) { theme in
                    Button {
                        accentRaw = theme.rawValue
                    } label: {
                        Circle()
                            .fill(theme.color)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().strokeBorder(.primary.opacity(0.8),
                                                      lineWidth: accentRaw == theme.rawValue ? 2.5 : 0)
                                    .padding(-3)
                            )
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .opacity(accentRaw == theme.rawValue ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(theme.displayName)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Doubles as the recovery action: when the remembered folder can't be
    /// reached, picking it again (or wherever it moved to) mints a fresh
    /// bookmark and unblocks writing.
    private var chooseFolderButton: some View {
        let missing = store.unavailableFolder != nil
        return Button { showingImporter = true } label: {
            Label(missing ? "Locate Folder…" : "Choose Folder…",
                  systemImage: missing ? "folder.badge.questionmark" : "folder")
        }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.setCustomFolder(url)
                }
            }
    }
    private var useDefaultButton: some View {
        Button(role: .destructive) { store.useDefaultFolder() } label: {
            Label("Use iCloud / Default", systemImage: "arrow.uturn.backward")
        }
    }
    private var chooseBackupButton: some View {
        Button { showingBackupPicker = true } label: { Label("Choose Backup Folder…", systemImage: "folder") }
            .fileImporter(isPresented: $showingBackupPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.setBackupFolder(url)
                }
            }
    }
    private var backupNowButton: some View {
        Button {
            Task { backupMessage = await store.runBackup().message }
        } label: {
            Label("Back Up Now", systemImage: "externaldrive.badge.timemachine")
        }
        .disabled(store.backupFolderName == nil || store.backupRunning)
    }
    private var restoreButton: some View {
        Button { showingRestore = true } label: {
            Label("Restore…", systemImage: "clock.arrow.circlepath")
        }
        .disabled(store.backupFolderName == nil || store.backupRunning)
    }
    private var cleanUpButton: some View {
        Button {
            let r = store.cleanup()
            cleanupMessage = "Moved \(r.moved) to their day, formatted \(r.formatted), reordered \(r.reordered), removed \(r.deduped) duplicate(s), extracted \(r.extracted) to split journals."
            showingCleanup = true
        } label: {
            Label("Clean Up", systemImage: "wand.and.sparkles")
        }
    }
    private var mergeExSplitButton: some View {
        Button {
            let r = store.mergeExSplitJournals()
            cleanupMessage = r.journals == 0
                ? "No ex-split journals to merge. (Only split files whose @tag is no longer configured are merged.)"
                : "Merged \(r.entries) entr\(r.entries == 1 ? "y" : "ies") from \(r.journals) journal(s) back into the main journal."
            showingCleanup = true
        } label: {
            Label("Merge Ex-Split Journals into Journal", systemImage: "arrow.triangle.merge")
        }
    }
    private var compressMediaButton: some View {
        Button {
            Task {
                let r = await store.compressExistingMedia()
                let total = r.images + r.videos + r.audios
                let converted = r.converted == 0 ? "" : "Converted \(r.converted) HEIC photo(s) to JPEG. "
                cleanupMessage = total == 0
                    ? (converted.isEmpty ? "No new media to compress." : converted)
                    : converted + "Compressed \(r.images) photo(s), \(r.videos) video(s), \(r.audios) audio — saved \(ByteCountFormatter.string(fromByteCount: Int64(r.bytesSaved), countStyle: .file))."
                showingCleanup = true
            }
        } label: {
            if store.mediaProgress != nil {
                Label("Compressing…", systemImage: "photo.badge.arrow.down")
            } else {
                Label("Compress Existing Media", systemImage: "photo.badge.arrow.down")
            }
        }
        .disabled(store.mediaProgress != nil)
    }
    private var tagReviewButton: some View {
        Button { showingTagReview = true } label: { Label("Tag Review", systemImage: "checkmark.seal") }
    }
    private var transcribeAllButton: some View {
        Button {
            Task {
                let r = await store.transcribeAllMemos()
                cleanupMessage = r.done == 0 && r.failed == 0
                    ? "No untranscribed voice memos."
                    : "Transcribed \(r.done) memo\(r.done == 1 ? "" : "s")\(r.failed > 0 ? "; \(r.failed) failed" : "")."
                showingCleanup = true
            }
        } label: {
            Label("Transcribe All Voice Memos", systemImage: "text.quote")
        }
        .disabled(store.mediaProgress != nil)
    }
    private var clearOrphanButton: some View {
        Button {
            orphanCount = store.orphanAssets().count
            if orphanCount == 0 { showingNoOrphans = true } else { showingOrphanConfirm = true }
        } label: {
            Label("Clear Orphan Media", systemImage: "photo.badge.exclamationmark")
        }
        .destructiveAction()
    }
    private var exportButton: some View {
        Button {
            let md = store.exportMarkdown()
            if md.isEmpty {
                showingNothingToExport = true
            } else {
                exportDoc = ExportDocument(text: md)
                showingExporter = true
            }
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        .fileExporter(isPresented: $showingExporter,
                      document: exportDoc,
                      contentType: .plainText,
                      defaultFilename: "quire-export.md") { _ in }
    }

    // MARK: Import / PDF export

    /// Root of the folder being imported. Security-scoped access is held from
    /// pick to commit, so the media copy can still read the export's photos.
    @State private var importRoot: URL?

    private func endImportAccess() {
        importRoot?.stopAccessingSecurityScopedResource()
        importRoot = nil
    }

    private var exportPDFButton: some View {
        Button { showingPDFSheet = true } label: {
            Label("Export PDF…", systemImage: "doc.richtext")
        }
    }

    private var importDayOneButton: some View {
        Button { showingDayOnePicker = true } label: {
            Label("Import from Day One…", systemImage: "square.and.arrow.down")
        }
        .fileImporter(isPresented: $showingDayOnePicker,
                      allowedContentTypes: [.json, .folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                importRoot = url.startAccessingSecurityScopedResource() ? url : nil
                prepareImport(JournalImporter.prepareDayOne(at: url))
            }
        }
    }

    private var importFolderButton: some View {
        Button { showingFolderPicker = true } label: {
            Label("Import Markdown Folder…", systemImage: "square.and.arrow.down.on.square")
        }
        .fileImporter(isPresented: $showingFolderPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                importRoot = url.startAccessingSecurityScopedResource() ? url : nil
                prepareImport(JournalImporter.prepareMarkdownFolder(at: url))
            }
        }
    }

    private func prepareImport(_ preview: ImportPreview?) {
        if let preview {
            pendingImport = preview
            showingImportConfirm = true
        } else {
            endImportAccess()
            showingNothingToImport = true
        }
    }

    private func runImport() {
        guard let preview = pendingImport else { return }
        pendingImport = nil
        let r = store.commitImport(preview)
        endImportAccess()
        cleanupMessage = "Imported \(r.entries) entr\(r.entries == 1 ? "y" : "ies")"
            + (r.media > 0 ? " and \(r.media) media file\(r.media == 1 ? "" : "s")" : "")
            + (r.skipped > 0 ? "; skipped \(r.skipped) already present" : "")
            + "."
        showingCleanup = true
    }

    // MARK: Reminder helpers

    private func refreshReminder() {
        let s = store.stats()
        ReminderScheduler.refresh(hasEntryToday: s.hasEntryToday, streak: s.currentStreak)
    }

    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: reminderHour, minute: reminderMinute,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                reminderHour = c.hour ?? ReminderScheduler.defaultHour
                reminderMinute = c.minute ?? 0
            }
        )
    }

    private var fileBrowserName: String {
        #if os(macOS)
        return "Finder"
        #else
        return "Files"
        #endif
    }
    #if os(macOS)
    private var showInFinderButton: some View {
        Button { store.revealInFinder() } label: { Label("Show in Finder", systemImage: "magnifyingglass") }
    }
    private var showBackupInFinderButton: some View {
        Button { store.revealBackupFolder() } label: { Label("Show in Finder", systemImage: "magnifyingglass") }
            .disabled(store.backupFolderName == nil)
    }
    #endif
}

/// Settings → Backup → Restore: pick a timestamped copy and swap it in. A
/// safety copy of the current journal is always taken first, so a restore is
/// itself restorable.
struct RestoreSheet: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.dismiss) private var dismiss

    @State private var backups: [JournalStore.BackupCopy] = []
    @State private var loaded = false
    @State private var confirming: JournalStore.BackupCopy?
    @State private var restoring = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView("Reading backups…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if backups.isEmpty {
                    ContentUnavailableView(
                        "No backups yet",
                        systemImage: "externaldrive.badge.timemachine",
                        description: Text("Run \u{201C}Back Up Now\u{201D} (or turn on automatic backups) and copies will appear here.")
                    )
                } else {
                    List(backups) { copy in
                        Button {
                            confirming = copy
                        } label: {
                            HStack {
                                Label {
                                    if let date = copy.date {
                                        Text(date.formatted(date: .abbreviated, time: .shortened))
                                    } else {
                                        Text(copy.name)
                                    }
                                } icon: {
                                    Image(systemName: "externaldrive")
                                }
                                Spacer()
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(restoring)
                    }
                }
            }
            .navigationTitle("Restore")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Button("Done") { dismiss() }.disabled(restoring) }
        }
        .task {
            backups = await store.listBackups()
            loaded = true
        }
        .alert("Restore this backup?", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        )) {
            Button("Restore", role: .destructive) {
                if let copy = confirming { run(copy) }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Your current journal is saved as a new backup first, then replaced by \(confirming?.date?.formatted(date: .abbreviated, time: .shortened) ?? confirming?.name ?? "this copy").")
        }
        .alert("Restore", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil; dismiss() } }
        )) {
            Button("OK") { }
        } message: {
            Text(message ?? "")
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func run(_ copy: JournalStore.BackupCopy) {
        confirming = nil
        restoring = true
        Task { @MainActor in
            defer { restoring = false }
            message = await store.restoreBackup(named: copy.name).message
        }
    }
}

/// Scope picker for Settings → Export PDF: one year or the whole journal.
struct PDFExportSheet: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)

    @State private var scope = "all"
    @State private var making = false
    @State private var doc: PDFExportDocument?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Include", selection: $scope) {
                    Text("Everything").tag("all")
                    ForEach(store.yearsWithEntries(), id: \.self) { Text($0).tag($0) }
                }
                Button {
                    export()
                } label: {
                    Label(making ? "Rendering…" : "Export PDF", systemImage: "doc.richtext")
                }
                .disabled(making)
            }
            .formStyle(.grouped)
            .navigationTitle("Export PDF")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Button("Done") { dismiss() } }
            .fileExporter(isPresented: Binding(
                get: { doc != nil },
                set: { if !$0 { doc = nil } }
            ), document: doc, contentType: .pdf,
               defaultFilename: scope == "all" ? "quire-journal.pdf" : "quire-\(scope).pdf") { _ in
                dismiss()
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 220)
        #endif
    }

    private func export() {
        making = true
        Task { @MainActor in
            defer { making = false }
            var days = store.allEntriesByDay()
            if scope != "all" { days = days.filter { $0.date.hasPrefix(scope) } }
            let data = await PDFExporter.makePDF(days: days,
                                                 store: store,
                                                 dateStyleRaw: dateStyleRaw,
                                                 fontRaw: writingFontRaw,
                                                 fontSize: CGFloat(fontSize))
            if let data { doc = PDFExportDocument(data: data) }
        }
    }
}

/// A minimal plain-text document for exporting the combined journal.
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
