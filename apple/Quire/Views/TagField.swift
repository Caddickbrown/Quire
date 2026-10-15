//
//  TagField.swift
//  Quire
//
//  An editable chip field for the split-tags setting: each tag is a little
//  capsule you can tap to edit or delete, plus a field to add new ones. Backed
//  by a space-separated string (the "splitTags" preference).
//

import SwiftUI

struct SplitTagsEditor: View {
    @Binding var raw: String
    @State private var newTag = ""
    @Environment(\.accent) private var accent

    private var tags: [String] {
        raw.split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        chip(tag)
                    }
                }
            }
            TextField("Add a tag…", text: $newTag)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit(addTag)
        }
        .padding(.vertical, 2)
    }

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Button {
                editTag(tag)   // tap the label to edit it
            } label: {
                Text("@\(tag)")
            }
            .buttonStyle(.plain)

            Button {
                removeTag(tag)  // tap the × to delete
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(accent.opacity(0.15), in: Capsule())
    }

    private func addTag() {
        let t = sanitized(newTag)
        guard !t.isEmpty else { return }
        var current = tags
        if !current.contains(t) { current.append(t) }
        raw = current.joined(separator: " ")
        newTag = ""
    }

    private func removeTag(_ tag: String) {
        raw = tags.filter { $0 != tag }.joined(separator: " ")
    }

    /// Pull a tag back into the add field for editing (removing it from the list).
    private func editTag(_ tag: String) {
        removeTag(tag)
        newTag = tag
    }

    private func sanitized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
    }
}

/// A minimal wrapping (flow) layout that packs subviews left-to-right and wraps
/// to the next line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
    }
}
