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
}

struct EntryDetailView: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let entry: Entry
    let source: EntrySource

    @State private var draftText: String
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)

    init(entry: Entry, source: EntrySource) {
        self.entry = entry
        self.source = source
        _draftText = State(initialValue: entry.raw)
    }

    private var size: CGFloat { CGFloat(fontSize) }
    private var isDirty: Bool { draftText != entry.raw }

    var body: some View {
        TextEditor(text: $draftText)
            .font(.custom(Theme.writingFont, size: size))
            .foregroundStyle(Theme.bodyText(colorScheme))
            .lineSpacing(Theme.lineSpacing(for: size))
            .scrollContentBackground(.hidden)
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .navigationTitle(entry.ts)
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
        }
    }

    private func delete() {
        switch source {
        case .inbox:
            store.deleteDraft(entry)
        case .archive(let date):
            store.deleteFiledEntry(date: date, entry: entry)
        }
    }
}
