//
//  EntryDetailView.swift
//  Jibber
//
//  Read/edit a single entry — an inbox draft or a filed archive entry. Saving
//  writes back through the JournalStore to the correct file.
//

import SwiftUI

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

    @State private var draftText: String
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue

    init(entry: Entry, source: EntrySource) {
        self.entry = entry
        self.source = source
        _draftText = State(initialValue: entry.raw)
    }

    private var size: CGFloat { CGFloat(fontSize) }
    private var isDirty: Bool { draftText != entry.raw }
    private var navTitle: String {
        let d = Theme.displayDate(entry.date, style: dateStyleRaw)
        return entry.suffix.isEmpty ? d : "\(d) · \(entry.suffix)"
    }

    var body: some View {
        TextEditor(text: $draftText)
            .font(Theme.font(writingFontRaw, size: size))
            .foregroundStyle(Theme.bodyText(colorScheme))
            .lineSpacing(Theme.lineSpacing(for: size))
            .scrollContentBackground(.hidden)
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .navigationTitle(navTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup {
                    if case .inbox = source {
                        Button {
                            store.fileDraft(entry)
                            dismiss()
                        } label: {
                            Label("File", systemImage: "archivebox")
                        }
                    }
                    Button {
                        save()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .disabled(!isDirty)
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
        switch source {
        case .inbox:
            store.updateDraft(entry, newText: draftText)
        case .archive(let date):
            store.updateFiledEntry(date: date, original: entry, newText: draftText)
        case .journal(let name):
            store.updateJournalEntry(name: name, original: entry, newText: draftText)
        }
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
