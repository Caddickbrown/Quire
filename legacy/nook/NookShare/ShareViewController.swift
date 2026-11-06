//
//  ShareViewController.swift
//  NookShareExtension
//
//  The share extension: text, URLs, and media shared from any app become a new
//  inbox draft. A small compose step lets you add a line of context and tags
//  before saving (with an "always save without asking" toggle that restores
//  the original zero-tap behaviour).
//
//  The extension never touches the journal itself — it can't reach a custom
//  folder's security-scoped bookmark — so everything lands in the App Group's
//  `PendingShare/` handoff (a `pending.md` of jnl-format drafts plus an
//  `assets/` folder), which the app drains into the inbox on its next launch
//  or foreground (`JournalStore.drainPendingShares`). Media is copied
//  file-to-file (never buffered — extensions have a tight memory budget) and
//  named here so the drafts' `![](assets/…)` links are already correct once
//  the app moves the files into `<base>/assets/`.
//
//  Deliberately self-contained: writing one `[timestamp] title\nbody` block
//  needs no shared model code.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

private let appGroupID = "group.com.caddickbrown.nook"
private let skipComposeKey = "shareComposeSkip"

/// What the attachments boiled down to, before anything is committed.
struct CapturedShare {
    var title: String
    var text: String            // shared text/URLs, editable in the compose step
    var mediaLinks: [String]    // "assets/<uuid>.<ext>" markdown targets
    var mediaFiles: [URL]       // the copies in PendingShare/assets (deleted on cancel)
}

#if os(iOS)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { await run() }
    }

    private func show(_ compose: ShareComposeView) {
        let host = UIHostingController(rootView: compose)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
#else
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 380))
    }

    // Without this the macOS sheet came up empty and nothing was ever
    // captured: `loadView` alone builds the view, it doesn't start the work.
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await run() }
    }

    private func show(_ compose: ShareComposeView) {
        let host = NSHostingView(rootView: compose)
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        preferredContentSize = NSSize(width: 460, height: 380)
    }
}
#endif

extension ShareViewController {
    private func run() async {
        guard let captured = await ShareCapture.collect(
            items: extensionContext?.inputItems as? [NSExtensionItem] ?? []) else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        let defaults = UserDefaults(suiteName: appGroupID)
        if defaults?.bool(forKey: skipComposeKey) == true {
            ShareCapture.save(captured, editedText: captured.text, tags: "")
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        show(ShareComposeView(
            captured: captured,
            onSave: { [weak self] edited, tags, skipNextTime in
                UserDefaults(suiteName: appGroupID)?.set(skipNextTime, forKey: skipComposeKey)
                ShareCapture.save(captured, editedText: edited, tags: tags)
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                ShareCapture.discard(captured)
                self?.extensionContext?.cancelRequest(withError: NSError(
                    domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }))
    }
}

// MARK: - Compose step

/// A small pre-save form: the shared text (editable), a tag line, what media
/// came along, and Save/Cancel.
struct ShareComposeView: View {
    let captured: CapturedShare
    let onSave: (_ editedText: String, _ tags: String, _ skipNextTime: Bool) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var tags = ""
    @State private var skipNextTime = false

    init(captured: CapturedShare,
         onSave: @escaping (String, String, Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.captured = captured
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: captured.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Text("Save to Nook").font(.headline)
                Spacer()
                Button("Save") { onSave(text, tags, skipNextTime) }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && captured.mediaLinks.isEmpty)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Add a line of context…")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            TextField("Tags (work, travel…)", text: $tags)
                .textFieldStyle(.roundedBorder)
            if !captured.mediaLinks.isEmpty {
                Label("\(captured.mediaLinks.count) attachment\(captured.mediaLinks.count == 1 ? "" : "s") will be included",
                      systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Always save without asking", isOn: $skipNextTime)
                .font(.caption)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

// MARK: - Capture, save, discard

enum ShareCapture {
    /// Read the attachments: text/URLs into the editable body, media copied
    /// into the handoff's assets folder. Nothing is written to pending.md yet.
    static func collect(items: [NSExtensionItem]) async -> CapturedShare? {
        var textParts: [String] = []
        var mediaLinks: [String] = []
        var mediaFiles: [URL] = []
        var title = ""

        for item in items {
            if title.isEmpty, let t = item.attributedTitle?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty { title = t }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    if let url = await loadURL(provider) { textParts.append(url.absoluteString) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                            || provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                            || provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                    if let (rel, file) = await loadMedia(provider) {
                        mediaLinks.append("![](\(rel))")
                        mediaFiles.append(file)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let text = await loadText(provider), !text.isEmpty { textParts.append(text) }
                }
            }
            // Some apps only supply the text as attributedContentText.
            if textParts.isEmpty, let t = item.attributedContentText?.string
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                textParts.append(t)
            }
        }

        let text = textParts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !title.isEmpty || !mediaLinks.isEmpty else { return nil }
        return CapturedShare(title: title, text: text, mediaLinks: mediaLinks, mediaFiles: mediaFiles)
    }

    /// Commit: compose the final body (edited text, then media links, then a
    /// tag line) and append it to pending.md.
    static func save(_ captured: CapturedShare, editedText: String, tags: String) {
        var parts: [String] = []
        let text = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(text) }
        parts.append(contentsOf: captured.mediaLinks)
        let tagTokens = tags
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { sanitizeTag(String($0)) }
            .map { "@\($0)" }
        if !tagTokens.isEmpty { parts.append(tagTokens.joined(separator: " ")) }
        appendDraft(title: captured.title, body: parts.joined(separator: "\n\n"))
    }

    /// Cancel: remove the media copies so nothing orphaned drains later.
    static func discard(_ captured: CapturedShare) {
        for file in captured.mediaFiles { try? FileManager.default.removeItem(at: file) }
    }

    /// "Deep Thoughts" → "deep-thoughts"; a tag must start with a letter.
    private static func sanitizeTag(_ raw: String) -> String? {
        let lowered = raw.lowercased()
            .replacingOccurrences(of: "@", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard let first = lowered.first, first.isLetter else { return nil }
        return lowered
    }

    // MARK: Attachment loading

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                cont.resume(returning: item as? URL ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                if let s = item as? String { cont.resume(returning: s) }
                else if let d = item as? Data { cont.resume(returning: String(data: d, encoding: .utf8)) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    /// Copy a shared image/movie/audio into the handoff's assets folder and
    /// return the relative link path plus the copy's URL. File-to-file, never
    /// a Data buffer — an extension has a tight memory budget and a shared
    /// video can be gigabytes.
    private static func loadMedia(_ provider: NSItemProvider) async -> (rel: String, file: URL)? {
        let typeID = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first { $0.conforms(to: .image) || $0.conforms(to: .movie) || $0.conforms(to: .audio) }
        guard let type = typeID else { return nil }
        let ext = (type.preferredFilenameExtension ?? "dat").lowercased()
        guard let dir = pendingDir?.appendingPathComponent("assets", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(ext)"
        let dest = dir.appendingPathComponent(name)
        let copied: Bool = await withCheckedContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // The provider's file dies when this closure returns; copy now.
                guard let url else { cont.resume(returning: false); return }
                cont.resume(returning: (try? FileManager.default.copyItem(at: url, to: dest)) != nil)
            }
        }
        return copied ? ("assets/\(name)", dest) : nil
    }

    // MARK: App Group handoff

    private static var pendingDir: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("PendingShare", isDirectory: true)
    }

    /// Append one jnl-format draft to pending.md (the same header shape the
    /// app writes: `[YYYY-MM-DD HH:MM:SS] title` then the body).
    private static func appendDraft(title: String, body: String) {
        guard let dir = pendingDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pending.md")

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        var header = "[\(f.string(from: Date()))]"
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { header += " " + t }
        let block = body.isEmpty ? header : header + "\n" + body

        var out = block + "\n"
        if let existing = try? String(contentsOf: file, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var trimmed = existing
            while trimmed.hasSuffix("\n") { trimmed.removeLast() }
            out = trimmed + "\n\n" + out
        }
        try? Data(out.utf8).write(to: file, options: .atomic)
    }
}
