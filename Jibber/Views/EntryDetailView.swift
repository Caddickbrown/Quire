//
//  EntryDetailView.swift
//  Jibber
//
//  Edit a single entry — an inbox draft, a filed archive entry, or a split-journal
//  entry. Same title + date-picker + body layout as the composer, autosaving
//  continuously. Edit / Preview modes; controls are inline (not in the window
//  toolbar) so they don't shift the layout when shown in a split pane.
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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
    @State private var showingVideoRecorder = false
    @State private var saveTask: Task<Void, Never>?
    @StateObject private var recorder = AudioRecorder()
    @FocusState private var bodyFocused: Bool

    enum EntryViewMode: String, CaseIterable, Identifiable {
        case edit = "Edit", preview = "Preview"
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

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()

            if mode == .preview {
                VStack(alignment: .leading, spacing: 0) {
                    if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack {
                            Text(title).font(font.weight(.bold))
                            Spacer()
                            Text(Theme.displayDate(String(JournalStore.ts(from: date).prefix(10)), style: dateStyleRaw))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 2)
                    }
                    MediaPreview(text: text, font: font, textColor: Theme.bodyText(colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editArea
            }
        }
        .overlay(alignment: .bottom) {
            if recorder.isRecording {
                RecordingBanner(elapsed: recorder.elapsedString) { toggleRecord() }
            }
        }
        .frame(maxWidth: 1520)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
        .fileImporter(isPresented: $showingImagePicker,
                      allowedContentTypes: [.image, .movie, .audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { attachFile(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { attachFile(url) }
            return !urls.isEmpty
        }
        .sheet(isPresented: $showingVideoRecorder) {
            VideoRecorderView { url in
                if let rel = store.importAsset(from: url) {
                    let md = "![](\(rel))"
                    text = text.isEmpty ? md : text + "\n\n" + md
                }
            }
        }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: date) { _, _ in scheduleSave() }
        .onDisappear { flush() }
    }

    // MARK: Controls (inline, so they don't reshuffle the window toolbar)

    private var controlBar: some View {
        HStack(spacing: 18) {
            Picker("Mode", selection: $mode) {
                ForEach(EntryViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()

            Button {
                toggleRecord()
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic")
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
            }
            .help(recorder.isRecording ? "Stop recording" : "Record audio")

            Menu {
                Button { showingImagePicker = true } label: { Label("Attach Media", systemImage: "paperclip") }
                Button { showingVideoRecorder = true } label: { Label("Record Video", systemImage: "video") }
                Button { copyText() } label: { Label("Copy text", systemImage: "doc.on.doc") }
                Button { promoteFirstLine() } label: { Label("Promote first line to title", systemImage: "arrow.up.to.line") }
                    .disabled(!hasFirstBodyLine)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .fixedSize()

            if case .inbox = source {
                Button {
                    flush()
                    store.fileDraft(currentEntry)
                    dismiss()
                } label: {
                    Label("File", systemImage: "archivebox").labelStyle(.iconOnly)
                }
                .help("File into the archive")
            }
            Button(role: .destructive) {
                delete()
                dismiss()
            } label: {
                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
            }
            .help("Delete")
        }
        .buttonStyle(.borderless)
        #if os(iOS)
        .imageScale(.large)
        #endif
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var editArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Title", text: $title)
                    .font(font.weight(.semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { bodyFocused = true }
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.caption).foregroundStyle(.secondary)
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
            .padding(.vertical, 8)

            Divider()

            WritingTextEditor(text: $text,
                              fontRaw: writingFontRaw,
                              size: size,
                              textColor: Theme.bodyText(colorScheme),
                              lineSpacing: Theme.lineSpacing(for: size),
                              highlightTags: highlightTags)
                .focused($bodyFocused)
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

    // MARK: Autosave

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    /// `reindex: false` (the debounced path) writes the file without rebuilding
    /// the whole index — so typing doesn't trigger a folder-wide re-render. The
    /// final flush reindexes so lists refresh once you leave.
    private func commit(reindex: Bool = false) {
        guard isDirty else { return }
        switch source {
        case .inbox:            store.updateDraft(entry, newText: composedRaw, reindex: reindex)
        case .archive(let d):   store.updateFiledEntry(date: d, original: entry, newText: composedRaw, reindex: reindex)
        case .journal(let n):   store.updateJournalEntry(name: n, original: entry, newText: composedRaw, reindex: reindex)
        }
        baselineRaw = composedRaw
    }

    private func flush() {
        saveTask?.cancel()
        commit(reindex: true)
    }

    // MARK: Media / helpers

    private var hasFirstBodyLine: Bool {
        text.split(separator: "\n", omittingEmptySubsequences: true).first != nil
    }

    private func promoteFirstLine() {
        var lines = text.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        title = lines[idx].trimmingCharacters(in: .whitespaces)
        lines.remove(at: idx)
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attachFile(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        insertMedia(data, ext: ext)
    }

    private func insertMedia(_ data: Data, ext: String) {
        guard let rel = store.saveAsset(data, ext: ext) else { return }
        let md = "![](\(rel))"
        text = text.isEmpty ? md : text + "\n\n" + md
    }

    /// Copy the entry's title + body to the clipboard.
    private func copyText() {
        let combined = [title.trimmingCharacters(in: .whitespacesAndNewlines), text]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = combined
        #endif
    }

    private func toggleRecord() {
        if recorder.isRecording {
            if let data = recorder.stop() { insertMedia(data, ext: "m4a") }
        } else {
            Task { await recorder.start() }
        }
    }

    private func delete() {
        switch source {
        case .inbox:            store.deleteDraft(entry)
        case .archive(let d):   store.deleteFiledEntry(date: d, entry: entry)
        case .journal(let n):   store.deleteJournalEntry(name: n, entry: entry)
        }
    }
}
