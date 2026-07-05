//
//  SettingsView.swift
//  Jibber
//
//  Choose where journal files live: a custom folder you pick, otherwise iCloud
//  Drive, otherwise on-device. Pointing this at an existing jnl notes folder
//  makes both tools share the same files.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Storage", value: store.storageMode.label)
                    LabeledContent("Location") {
                        Text(store.storagePath)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Journal folder")
                } footer: {
                    Text("Jibber stores inbox.md and journal/YYYY/MM/DD.md here. Point this at an existing jnl folder to share files with the jnl CLI.")
                }

                Section {
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
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.setCustomFolder(url)
                }
            }
        }
    }
}
