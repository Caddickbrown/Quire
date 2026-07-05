//
//  InboxView.swift
//  Jibber
//
//  The inbox: unfiled drafts. Mirrors jnl's `review` flow reduced to list rows —
//  each draft can be Filed (into its day's archive), Edited, or Deleted.
//

import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var store: JournalStore

    var body: some View {
        Group {
            if store.inboxDrafts.isEmpty {
                ContentUnavailableView(
                    "Inbox is empty",
                    systemImage: "tray",
                    description: Text("Drafts you write appear here until you file them.")
                )
            } else {
                List {
                    ForEach(store.inboxDrafts) { draft in
                        NavigationLink {
                            EntryDetailView(entry: draft, source: .inbox)
                        } label: {
                            DraftRow(draft: draft)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                store.fileDraft(draft)
                            } label: {
                                Label("File", systemImage: "archivebox")
                            }
                            .tint(.green)
                            Button(role: .destructive) {
                                store.deleteDraft(draft)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Inbox")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if store.inboxDrafts.count >= 2 {
                Button {
                    store.sortInbox()
                } label: {
                    Label("Sort by date", systemImage: "arrow.up.arrow.down")
                }
            }
        }
    }
}

private struct DraftRow: View {
    let draft: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(draft.preview.isEmpty ? "(empty)" : draft.preview)
                .lineLimit(1)
                .font(.body)
            HStack(spacing: 8) {
                Text(draft.ts)
                Text("·")
                Text("\(draft.wordCount) words")
                if !draft.tags.isEmpty {
                    Text("·")
                    Text(draft.tags.joined(separator: " "))
                        .foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
