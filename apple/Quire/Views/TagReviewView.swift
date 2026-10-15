//
//  TagReviewView.swift
//  Quire
//
//  Find near-duplicate tags (e.g. @tags vs @Tags, or a one-character typo) and
//  merge a group into the variant you pick — renaming every occurrence.
//

import SwiftUI

struct TagReviewView: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [JournalStore.TagGroup] = []
    @State private var choices: [String: String] = [:]   // group.id → tag to keep
    @State private var loading = true

    private var pendingMerges: Int {
        groups.reduce(0) { total, g in
            guard let keep = choices[g.id] else { return total }
            return total + g.variants.filter { $0.tag != keep }.count
        }
    }

    /// Groups still awaiting a decision (no tag chosen yet).
    private var remaining: Int { groups.filter { choices[$0.id] == nil }.count }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Scanning tags…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if groups.isEmpty {
                    ContentUnavailableView(
                        "No similar tags",
                        systemImage: "checkmark.seal",
                        description: Text("Your tags look clean — nothing to merge.")
                    )
                } else {
                    List {
                        Section {
                            Text("Pick the tag to keep in each group, then Apply — the rest merge into it. Groups you leave untouched are unchanged.")
                                .font(.callout).foregroundStyle(.secondary)
                        } footer: {
                            Text("Remaining: \(remaining) of \(groups.count)")
                                .font(.callout.monospacedDigit())
                        }
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.variants, id: \.tag) { variant in
                                    Button {
                                        if choices[group.id] == variant.tag { choices[group.id] = nil }
                                        else { choices[group.id] = variant.tag }
                                    } label: {
                                        HStack {
                                            Image(systemName: choices[group.id] == variant.tag
                                                  ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(choices[group.id] == variant.tag
                                                                 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                            Text(variant.tag)
                                            Spacer()
                                            Text("\(variant.count)")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                                Button {
                                    // Persist the choice and drop it locally — no
                                    // rescan, so it's instant.
                                    choices[group.id] = nil
                                    store.ignoreTagGroup(group)
                                    withAnimation { groups.removeAll { $0.id == group.id } }
                                } label: {
                                    Label("Not a match — ignore", systemImage: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                            } header: {
                                Text(group.caseOnly
                                     ? "Different case"
                                     : "Similar spelling — merge only if they mean the same")
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingMerges > 0 ? "Apply (\(pendingMerges))" : "Done") { apply() }
                }
            }
            .task {
                groups = await store.similarTagGroupsAsync()
                loading = false
            }
        }
        .frame(minWidth: 400, minHeight: 460)
    }

    /// Collect every chosen merge and process them in one background pass.
    private func apply() {
        let merges: [(from: String, to: String)] = groups.flatMap { g -> [(from: String, to: String)] in
            guard let keep = choices[g.id] else { return [] }
            return g.variants.filter { $0.tag != keep }.map { (from: $0.tag, to: keep) }
        }
        dismiss()
        if !merges.isEmpty {
            Task { store.mergeTags(merges) }
        }
    }
}
