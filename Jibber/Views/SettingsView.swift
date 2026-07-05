//
//  SettingsView.swift
//  Jibber
//
//  Choose where journal files live: a custom folder you pick, otherwise iCloud
//  Drive, otherwise on-device. Pointing this at an existing jnl notes folder
//  makes both tools share the same files.
//
//  Content-only: on macOS it's shown in the Settings window (⌘,); on iOS it's
//  wrapped in a sheet with a Done button by RootView.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: JournalStore
    @State private var showingImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Journal folder")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Storage").foregroundStyle(.secondary)
                    Spacer()
                    Text(store.storageMode.label).fontWeight(.medium)
                }
                Text(store.storagePath)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Text("Jibber stores inbox.md and journal/YYYY/MM/DD.md here. Point this at an existing jnl folder to share files with the jnl CLI.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.setCustomFolder(url)
            }
        }
    }
}
