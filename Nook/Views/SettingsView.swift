//
//  SettingsView.swift
//  Nook
//
//  Appearance, writing font, date format, the journal folder, and maintenance
//  actions (jnl cleanup / export / open). Shown as a sidebar section.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("colorScheme") private var colorSchemeRaw: String = AppColorScheme.auto.rawValue
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage("accentColor") private var accentRaw: String = AccentTheme.blue.rawValue
    @AppStorage("highlightTags") private var highlightTags = true
    @AppStorage("firstWeekday") private var firstWeekday = 1
    @AppStorage("showWeekNumbers") private var showWeekNumbers = false
    @AppStorage("inboxSwipeLeft") private var swipeLeftRaw = SwipeAction.file.rawValue
    @AppStorage("inboxSwipeRight") private var swipeRightRaw = SwipeAction.delete.rawValue
    @AppStorage("splitTags") private var splitTagsRaw: String = ""
    @AppStorage("dataSaver") private var dataSaver = false
    @AppStorage(JournalStore.backupIntervalKey) private var backupIntervalRaw = BackupInterval.off.rawValue
    @AppStorage(JournalStore.backupKeepKey) private var backupKeepCount = 10

    static let shortcuts: [(action: String, keys: String)] = [
        ("New entry", "⌘N"),
        ("Save", "⌘S"),
        ("Write", "⌘1"),
        ("Inbox", "⌘2"),
        ("Archive", "⌘3"),
        ("Tags", "⌘4"),
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
         "Sort file by date" reorders inbox.md. Drafts are grouped by date.
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
         Wrap text in __double underscores__ to italicise it while editing. Preview mode \
         renders markdown (bold, italics, links, lists) with your media inline. An entry's \
         ⋯ menu has "Copy text" to put its title + body on the clipboard.
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
         containing that @tag, it's written to <folder>/<tag>.md instead of the dated \
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
         split tag into its <tag>.md file — so adding a split tag later pulls matching \
         history out too. Clear Orphan Media deletes asset files no entry references any \
         more. Export combines all filed entries into one markdown file (drafts still in \
         the Inbox aren't included until you file them).
         """),
        ("Storage, iCloud & jnl",
         """
         By default your journal lives in iCloud so it syncs across devices, with a local \
         fallback when iCloud is off. Point "Journal folder" at any folder — including an \
         existing jnl notes folder — to share the same inbox.md and journal/YYYY/MM/DD.md \
         files with the jnl CLI. The Stats sheet breaks size into text vs media.
         """),
    ]

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

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $colorSchemeRaw) {
                    ForEach(AppColorScheme.allCases) { scheme in
                        Text(scheme.displayName).tag(scheme.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Writing font", selection: $writingFontRaw) {
                    ForEach(WritingFont.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("Text size", selection: $fontSize) {
                    ForEach(Theme.fontSizes, id: \.self) { s in
                        Text("\(Int(s)) px").tag(Double(s))
                    }
                }
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

            #if os(iOS)
            Section {
                Picker("Swipe left", selection: $swipeLeftRaw) {
                    ForEach(SwipeAction.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Swipe right", selection: $swipeRightRaw) {
                    ForEach(SwipeAction.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } header: {
                Text("Inbox swipe")
            }
            #endif

            Section {
                SplitTagsEditor(raw: $splitTagsRaw)
            } header: {
                Text("Split tags")
            } footer: {
                Text("Entries containing these @tags file into <folder>/<tag>.md instead of the date journal (jnl JNL_SPLIT_TAGS). Space or comma separated.")
            }

            Section {
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
                Text("Journal folder")
            } footer: {
                Text("Nook stores inbox.md and journal/YYYY/MM/DD.md here. Point this at an existing jnl folder to share files with the jnl CLI.")
            }

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
                Text("Backup")
            } footer: {
                Text("Copies everything (inbox, journal, split journals, and assets) into a timestamped folder in the backup location. Automatic backups run in the background and prune down to the number you keep; “On every change” waits for a pause in writing and won't run more than once every five minutes.")
            }

            Section {
                Toggle("Data Saver", isOn: $dataSaver)
                LabeledContent("Data saved",
                               value: ByteCountFormatter.string(fromByteCount: Int64(store.dataSaved), countStyle: .file))
                if let p = store.mediaProgress {
                    LabeledContent("Compressing", value: "\(p.done)/\(p.total)")
                }
            } header: {
                Text("Media")
            } footer: {
                Text("Compresses attached media to save space — photos (longest edge 2048 px), videos (720p H.264) and voice memos (low-bitrate AAC). The original format is kept so links stay valid; videos re-encode in the background after attaching. Existing media isn't touched until you run “Compress Existing Media” below. The tally is merged across your devices.")
            }

            Section {
                buttonRow {
                    cleanUpButton
                    compressMediaButton
                    mergeExSplitButton
                    tagReviewButton
                    clearOrphanButton
                    exportButton
                }
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Export combines all filed entries into one markdown file. Drafts still in the Inbox aren't included until you file them.")
            }

            Section("Keyboard shortcuts") {
                ForEach(Self.shortcuts, id: \.action) { s in
                    HStack {
                        Text(s.action)
                        Spacer()
                        Text(s.keys)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button { showingChangelog = true } label: {
                    Label("What's New", systemImage: "sparkles")
                }
            } header: {
                Text("About")
            } footer: {
                Text("Every release and what changed in it.")
            }

            Section("How to") {
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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

    private var chooseFolderButton: some View {
        Button { showingImporter = true } label: { Label("Choose Folder…", systemImage: "folder") }
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
    private var cleanUpButton: some View {
        Button {
            let r = store.cleanup()
            cleanupMessage = "Formatted \(r.formatted), reordered \(r.reordered), removed \(r.deduped) duplicate(s), extracted \(r.extracted) to split journals."
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
                cleanupMessage = total == 0
                    ? "No new media to compress."
                    : "Compressed \(r.images) photo(s), \(r.videos) video(s), \(r.audios) audio — saved \(ByteCountFormatter.string(fromByteCount: Int64(r.bytesSaved), countStyle: .file))."
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
    private var clearOrphanButton: some View {
        Button {
            orphanCount = store.orphanAssets().count
            if orphanCount == 0 { showingNoOrphans = true } else { showingOrphanConfirm = true }
        } label: {
            Label("Clear Orphan Media", systemImage: "photo.badge.exclamationmark")
        }
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
                      defaultFilename: "nook-export.md") { _ in }
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
