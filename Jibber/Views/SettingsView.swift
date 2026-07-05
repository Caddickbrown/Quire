//
//  SettingsView.swift
//  Jibber
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
    @AppStorage("splitTags") private var splitTagsRaw: String = ""

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

    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDoc = ExportDocument(text: "")
    @State private var showingCleanup = false
    @State private var cleanupMessage = ""
    @State private var showingNothingToExport = false

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
                Picker("Date format", selection: $dateStyleRaw) {
                    ForEach(DateStyle.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
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
                Button {
                    showingImporter = true
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                if store.storageMode == .custom {
                    Button(role: .destructive) {
                        store.useDefaultFolder()
                    } label: {
                        Label("Use iCloud / Default", systemImage: "arrow.uturn.backward")
                    }
                }
                #if os(macOS)
                Button {
                    store.revealInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "magnifyingglass")
                }
                #endif
            } header: {
                Text("Journal folder")
            } footer: {
                Text("Jibber stores inbox.md and journal/YYYY/MM/DD.md here. Point this at an existing jnl folder to share files with the jnl CLI.")
            }

            Section {
                TextField("e.g. work private", text: $splitTagsRaw)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } header: {
                Text("Split tags")
            } footer: {
                Text("Entries containing these @tags file into <folder>/<tag>.md instead of the date journal (jnl JNL_SPLIT_TAGS). Space or comma separated.")
            }

            Section {
                Button {
                    let r = store.cleanup()
                    cleanupMessage = "Formatted \(r.formatted) file(s), reordered \(r.reordered)."
                    showingCleanup = true
                } label: {
                    Label("Clean Up", systemImage: "wand.and.sparkles")
                }
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

            Section("How to") {
                DisclosureGroup("Import as separate entries") {
                    Text("""
                    In Write, the ⋯ menu has "Import as separate entries". Paste text \
                    containing multiple entries, then choose it to split them into individual \
                    inbox drafts.

                    • If the text has [YYYY-MM-DD HH:MM:SS] headers, each header + its lines \
                    becomes its own draft (paste a whole inbox.md and it splits cleanly).
                    • If there are no headers, the whole text stays a single draft.

                    The drafts land in the Inbox; file them from there.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                DisclosureGroup("Split journals (tag routing)") {
                    Text("""
                    Add tag names to "Split tags" above (e.g. work private). When you file a \
                    draft that contains that @tag, it's written to <folder>/<tag>.md instead of \
                    the dated journal, and shows up under "Split journals" at the top of Archive. \
                    Routing happens when you file, so tag the draft first, then file it.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.setCustomFolder(url)
            }
        }
        .fileExporter(isPresented: $showingExporter,
                      document: exportDoc,
                      contentType: .plainText,
                      defaultFilename: "jibber-export.md") { _ in }
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
