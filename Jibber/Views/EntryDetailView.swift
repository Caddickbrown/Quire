//
//  EntryDetailView.swift
//  Jibber
//
//  Edit a single entry — an inbox draft, a filed archive entry, or a split-journal
//  entry. Uses the same title + date-picker + body layout as the composer, and
//  writes back through the JournalStore to the correct file.
//

import SwiftUI
import UniformTypeIdentifiers

enum EntrySource: Hashable {
    case inbox
    case archive(date: String)
    case journal(name: String)   // a tag-routed split journal (<base>/<name>.md)
}

struct EntryDetailView: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let entry: Entry
    let source: EntrySource

    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    @AppStorage("highlightTags") private var highlightTags = true

    @State private var title: String
    @State private var date: Date
    @State private var text: String
    @State private var baselineRaw: String
    @State private var mode: EntryViewMode = .edit
    @State private var showingImagePicker = false

    enum EntryViewMode: String, CaseIterable, Identifiable {
        case edit = "Edit", preview = "Preview", raw = "Raw"
        var id: String { rawValue }
    }

    init(entry: Entry, source: EntrySource) {
        self.entry = entry
        self.source = source
        _title = State(initialValue: entry.suffix)
        _date = State(initialValue: JournalStore.date(from: entry.ts) ?? Date())
        _text = State(initialValue: entry.body)
        _baselineRaw = State(initialValue: entry.raw)
    }

    private var size: CGFloat { CGFloat(fontSize) }
    private var font: Font { Theme.font(writingFontRaw, size: size) }
    private var currentEntry: Entry {
        JournalStore.makeEntry(timestamp: JournalStore.ts(from: date), title: title, body: text)
    }
    private var composedRaw: String { currentEntry.raw }
    private var isDirty: Bool { composedRaw != baselineRaw }
    private var navTitle: String {
        let d = Theme.displayDate(String(JournalStore.ts(from: date).prefix(10)), style: dateStyleRaw)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? d : "\(d) · \(t)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if mode == .edit {
                HStack(spacing: 12) {
                    TextField("Title", text: $title)
                        .font(font.weight(.semibold))
                        .textFieldStyle(.plain)
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            #if os(macOS)
                            .datePickerStyle(.field)
                            #else
                            .datePickerStyle(.compact)
                            #endif
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider()
            }

            switch mode {
            case .preview:
                MediaPreview(text: text, font: font, textColor: Theme.bodyText(colorScheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .raw:
                ScrollView {
                    Text(composedRaw)
                        .font(.system(size: size, design: .monospaced))
                        .foregroundStyle(Theme.bodyText(colorScheme))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .edit:
                WritingTextEditor(text: $text,
                                  fontRaw: writingFontRaw,
                                  size: size,
                                  textColor: Theme.bodyText(colorScheme),
                                  lineSpacing: Theme.lineSpacing(for: size),
                                  highlightTags: highlightTags)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Begin writing")
                                .font(font)
                                .foregroundStyle(Theme.placeholder(colorScheme))
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: 1520)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
        .navigationTitle(navTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(isPresented: $showingImagePicker,
                      allowedContentTypes: [.image, .movie, .audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { attachImage(url) }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Mode", selection: $mode) {
                    ForEach(EntryViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Menu {
                    Button {
                        showingImagePicker = true
                    } label: {
                        Label("Attach Media", systemImage: "paperclip")
                    }
                    RecordButton { data in attachAudioData(data) }
                    Button {
                        promoteFirstLine()
                    } label: {
                        Label("Promote first line to title", systemImage: "arrow.up.to.line")
                    }
                    .disabled(!hasFirstBodyLine)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
                .help("Save (⌘S)")
                if case .inbox = source {
                    Button {
                        save()
                        store.fileDraft(currentEntry)
                        dismiss()
                    } label: {
                        Label("File", systemImage: "archivebox")
                    }
                    .help("File into the archive")
                }
                Button(role: .destructive) {
                    delete()
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func save() {
        guard isDirty else { return }
        switch source {
        case .inbox:
            store.updateDraft(entry, newText: composedRaw)
        case .archive(let date):
            store.updateFiledEntry(date: date, original: entry, newText: composedRaw)
        case .journal(let name):
            store.updateJournalEntry(name: name, original: entry, newText: composedRaw)
        }
        baselineRaw = composedRaw
    }

    private var hasFirstBodyLine: Bool {
        text.split(separator: "\n", omittingEmptySubsequences: true).first != nil
    }

    private func promoteFirstLine() {
        var lines = text.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return }
        title = lines[idx].trimmingCharacters(in: .whitespaces)
        lines.remove(at: idx)
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attachImage(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        insertMedia(data, ext: ext)
    }

    private func attachAudioData(_ data: Data) { insertMedia(data, ext: "m4a") }

    private func insertMedia(_ data: Data, ext: String) {
        guard let rel = store.saveAsset(data, ext: ext) else { return }
        let md = "![](\(rel))"
        text = text.isEmpty ? md : text + "\n\n" + md
    }

    private func delete() {
        switch source {
        case .inbox:
            store.deleteDraft(entry)
        case .archive(let date):
            store.deleteFiledEntry(date: date, entry: entry)
        case .journal(let name):
            store.deleteJournalEntry(name: name, entry: entry)
        }
    }
}
