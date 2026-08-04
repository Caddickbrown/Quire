//
//  ChangelogView.swift
//  Nook
//
//  A "What's New" screen showing the whole release history — every section of
//  CHANGELOG.md, not just the pending one. The markdown file is copied into the
//  app bundle as a resource, so the screen and the repo can never drift apart:
//  update CHANGELOG.md and the app shows it.
//
//  Only the release sections are shown. The file's title and its maintainer
//  "how to update this file" block sit above the first `## ` heading and aren't
//  part of the history, so the parser skips them.
//

import SwiftUI

// MARK: - Model

struct ChangelogRelease: Identifiable {
    let id = UUID()
    /// "Unreleased", or a milestone like "2026-07-30 — Widget".
    let title: String
    let buckets: [Bucket]

    /// A run of items under one `### Added` / `### Fixed` heading. An empty
    /// `name` holds the prose paragraphs that sit directly under a release.
    struct Bucket: Identifiable {
        let id = UUID()
        let name: String
        let items: [String]
    }
}

// MARK: - Parsing

enum ChangelogParser {
    static func loadBundled() -> [ChangelogRelease] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return parse(text)
    }

    /// Line-based walk: `##` opens a release, `###` opens a bucket, `-` opens an
    /// item, and an unbroken run of following lines continues whatever is open
    /// (the file hard-wraps its bullets). A blank line or `---` closes it.
    static func parse(_ text: String) -> [ChangelogRelease] {
        var releases: [ChangelogRelease] = []
        var title: String?
        var buckets: [ChangelogRelease.Bucket] = []
        var bucketName = ""
        var items: [String] = []
        var continuing = false

        func closeBucket() {
            if !items.isEmpty {
                buckets.append(ChangelogRelease.Bucket(name: bucketName, items: items))
            }
            items = []
        }
        func closeRelease() {
            closeBucket()
            // A nil title means we're still in the preamble above the first
            // release heading — that content is dropped rather than shown.
            if let title, !buckets.isEmpty {
                releases.append(ChangelogRelease(title: title, buckets: buckets))
            }
            buckets = []
            bucketName = ""
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("## ") {
                closeRelease()
                title = heading(String(raw.dropFirst(3)))
                continuing = false
            } else if raw.hasPrefix("### ") {
                closeBucket()
                bucketName = line.replacingOccurrences(of: "### ", with: "")
                continuing = false
            } else if line.isEmpty || line == "---" {
                continuing = false
            } else if raw.hasPrefix("- ") {
                items.append(String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continuing = true
            } else if continuing, !items.isEmpty {
                items[items.count - 1] += " " + line
            } else if title != nil {
                items.append(line)          // a prose paragraph under the release
                continuing = true
            }
        }
        closeRelease()
        return releases
    }

    /// "[Unreleased]" → "Unreleased"; dated milestones pass through unchanged.
    private static func heading(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }
}

// MARK: - View

struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var releases: [ChangelogRelease] = []

    var body: some View {
        NavigationStack {
            Group {
                if releases.isEmpty {
                    ContentUnavailableView(
                        "No changelog",
                        systemImage: "doc.text",
                        description: Text("CHANGELOG.md wasn't found in the app bundle.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("What's New")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
        .task { releases = ChangelogParser.loadBundled() }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(releases) { release in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(release.title)
                            .font(.title3.weight(.semibold))
                        ForEach(release.buckets) { bucket in
                            bucketView(bucket)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func bucketView(_ bucket: ChangelogRelease.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !bucket.name.isEmpty {
                Text(bucket.name)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Self.tint(for: bucket.name))
            }
            ForEach(Array(bucket.items.enumerated()), id: \.offset) { _, item in
                if bucket.name.isEmpty {
                    // Prose under a release heading — no bullet.
                    Text(inline(item))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(inline(item))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private static func tint(for bucket: String) -> Color {
        switch bucket {
        case "Added":      return .green
        case "Changed":    return .blue
        case "Fixed":      return .orange
        case "Removed":    return .red
        case "Security":   return .purple
        default:           return .secondary
        }
    }

    /// Render the bold/code/link markup the changelog uses inside a bullet.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}
