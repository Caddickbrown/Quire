//
//  TagReviewView.swift
//  Jibber
//
//  Find near-duplicate tags (e.g. @tags vs @Tags, or a one-character typo) and
//  merge a group into the variant you pick — renaming every occurrence.
//

import SwiftUI

struct TagReviewView: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [[(tag: String, count: Int)]] = []
    @State private var lastMerge: String?

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "No similar tags",
                        systemImage: "checkmark.seal",
                        description: Text("Your tags look clean — nothing to merge.")
                    )
                } else {
                    List {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            Section {
                                ForEach(group, id: \.tag) { variant in
                                    Button {
                                        merge(group, into: variant.tag)
                                    } label: {
                                        HStack {
                                            Text(variant.tag).foregroundStyle(.tint)
                                            Spacer()
                                            Text("\(variant.count)")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                            Image(systemName: "arrow.down.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            } header: {
                                Text("Keep one — the others merge into it")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tag Review")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let lastMerge {
                    Text(lastMerge)
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 16)
                }
            }
            .onAppear { groups = store.similarTagGroups() }
        }
        .frame(minWidth: 380, minHeight: 420)
    }

    private func merge(_ group: [(tag: String, count: Int)], into canonical: String) {
        var renamed = 0
        for variant in group where variant.tag != canonical {
            renamed += store.renameTag(from: variant.tag, to: canonical)
        }
        groups = store.similarTagGroups()
        withAnimation { lastMerge = "Merged into \(canonical)" }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { lastMerge = nil }
        }
    }
}
