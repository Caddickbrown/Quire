//
//  Importers.swift
//  Quire
//
//  One-time importers (Settings → Maintenance): a Day One JSON export, and a
//  generic folder of dated markdown/text files (Obsidian daily notes and the
//  like). Everything becomes ordinary filed entries — timestamp headers from
//  the export's dates, photos/videos copied through the normal asset path,
//  Day One tags mapped to @tags — so the on-disk format is untouched.
//

import Foundation

// MARK: - Day One JSON export

/// The slice of Day One's `Journal.json` we read. Every field optional — the
/// format has grown over the years and older exports miss keys.
private struct DayOneJSON: Decodable {
    var entries: [DayOneEntry]?

    struct DayOneEntry: Decodable {
        var creationDate: String?
        var timeZone: String?
        var text: String?
        var tags: [String]?
        var starred: Bool?
        var photos: [DayOneMedia]?
        var videos: [DayOneMedia]?
        var audios: [DayOneMedia]?
    }

    struct DayOneMedia: Decodable {
        var identifier: String?
        var md5: String?
        var type: String?
    }
}

/// One entry ready to file: the jnl timestamp, the body (still carrying
/// `dayone-moment://` links), and the media files to copy into assets/.
struct PreparedImportEntry {
    var ts: String
    var title: String
    var body: String
    /// moment identifier → source file URL (resolved against the export folder).
    var media: [(identifier: String, url: URL)] = []
}

struct ImportPreview {
    var entries: [PreparedImportEntry] = []
    var mediaCount = 0
    var firstDate: String? { entries.map(\.ts).min().map { String($0.prefix(10)) } }
    var lastDate: String?  { entries.map(\.ts).max().map { String($0.prefix(10)) } }
}

enum JournalImporter {

    /// Parse a Day One export. `url` may be the `Journal.json` itself or the
    /// unzipped export folder containing it (plus `photos/`, `videos/`).
    static func prepareDayOne(at url: URL) -> ImportPreview? {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var jsonURL = url
        var folder = url.deletingLastPathComponent()
        if url.hasDirectoryPath {
            folder = url
            // Prefer Journal.json by name — an export folder also carries a
            // metadata.json that must never win the "first .json" race.
            guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return nil }
            let jsons = items.filter { $0.pathExtension.lowercased() == "json" }
            guard let json = jsons.first(where: { $0.lastPathComponent == "Journal.json" })
                ?? jsons.first(where: { $0.lastPathComponent.lowercased() != "metadata.json" })
                ?? jsons.first else { return nil }
            jsonURL = json
        }
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode(DayOneJSON.self, from: data),
              let entries = decoded.entries else { return nil }

        let iso = ISO8601DateFormatter()
        var preview = ImportPreview()
        for e in entries {
            guard let created = e.creationDate, let date = iso.date(from: created) else { continue }
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
            stamp.locale = Locale(identifier: "en_US_POSIX")
            if let tz = e.timeZone, let zone = TimeZone(identifier: tz) { stamp.timeZone = zone }
            var body = (e.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // Day One escapes markdown punctuation (\. \! \(); unescape it.
            for ch in ["!", ".", "(", ")", "[", "]", "#", "-", "*", "_"] {
                body = body.replacingOccurrences(of: "\\\(ch)", with: ch)
            }

            var prepared = PreparedImportEntry(ts: stamp.string(from: date),
                                               title: (e.starred ?? false) ? "*" : "",
                                               body: body)
            for (kind, list) in [("photos", e.photos), ("videos", e.videos), ("audios", e.audios)] {
                for m in list ?? [] {
                    guard let id = m.identifier, let md5 = m.md5 else { continue }
                    let ext = m.type ?? (kind == "photos" ? "jpeg" : kind == "videos" ? "mov" : "m4a")
                    let file = folder.appendingPathComponent(kind).appendingPathComponent("\(md5).\(ext)")
                    if fm.fileExists(atPath: file.path) {
                        prepared.media.append((identifier: id, url: file))
                        preview.mediaCount += 1
                    }
                }
            }
            if let tags = e.tags, !tags.isEmpty {
                let cleaned = tags.compactMap(sanitizeTag).map { "@\($0)" }
                if !cleaned.isEmpty { prepared.body += "\n\n" + cleaned.joined(separator: " ") }
            }
            guard !prepared.body.isEmpty || !prepared.media.isEmpty else { continue }
            preview.entries.append(prepared)
        }
        return preview.entries.isEmpty ? nil : preview
    }

    /// Parse a folder of markdown/text files. A `YYYY-MM-DD` anywhere in the
    /// filename dates the file; files already carrying `[timestamp]` headers
    /// split into their own entries; anything else becomes one entry at noon.
    static func prepareMarkdownFolder(at url: URL) -> ImportPreview? {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.creationDateKey]) else { return nil }

        let nameDate = try! NSRegularExpression(pattern: #"(\d{4}-\d{2}-\d{2})"#)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        stamp.locale = Locale(identifier: "en_US_POSIX")

        var preview = ImportPreview()
        // Several files on one date fan out +1s from noon, so their order is
        // stable instead of piling onto a shared 12:00:00.
        var perDate: [String: Int] = [:]
        // By path, not in the order the directory happens to list them: the
        // offsets are part of each entry's timestamp, and a second import of
        // the same folder must give every file the one it had the first time,
        // or nothing matches and everything is filed twice.
        let files = (en.allObjects as? [URL] ?? [])
            .filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // Files already in the jnl shape import entry-by-entry, verbatim.
            let parsed = JournalParser.parseEntries(content)
            if !parsed.isEmpty {
                for e in parsed {
                    preview.entries.append(PreparedImportEntry(ts: e.ts, title: e.suffix, body: e.body))
                }
                continue
            }

            let name = file.deletingPathExtension().lastPathComponent
            var date: String?
            let range = NSRange(name.startIndex..., in: name)
            if let m = nameDate.firstMatch(in: name, range: range), let r = Range(m.range(at: 1), in: name) {
                let candidate = String(name[r])
                if stamp.date(from: candidate) != nil { date = candidate }
            }
            if date == nil,
               let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate {
                date = stamp.string(from: created)
            }
            guard let date else { continue }
            let offset = perDate[date, default: 0]
            perDate[date] = offset + 1
            preview.entries.append(PreparedImportEntry(
                ts: String(format: "%@ 12:%02d:%02d", date, offset / 60, offset % 60),
                title: name == date ? "" : name,
                body: content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return preview.entries.isEmpty ? nil : preview
    }

    /// "Deep Thoughts" → "deep-thoughts"; must start with a letter to be a tag.
    static func sanitizeTag(_ raw: String) -> String? {
        let lowered = raw.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard let first = lowered.first, first.isLetter else { return nil }
        return lowered
    }
}

// MARK: - Committing an import

extension JournalStore {
    struct ImportResult { var entries = 0; var skipped = 0; var media = 0 }

    /// File a prepared import into the archive: copy each entry's media through
    /// the normal asset path (rewriting its `dayone-moment://` links), then
    /// append the entries to their day files. Re-running the same import is
    /// safe — an entry already in its day file is skipped, media and all.
    ///
    /// The skip has to happen *before* the media copy: every copy takes a fresh
    /// `assets/<uuid>` name, so the rewritten text of a re-import never matches
    /// what the first run wrote, and comparing finished entries (which is all
    /// `appendFiledEntries` can do) would duplicate every entry with a photo —
    /// and re-copy the photo. So entries are matched on what survives the
    /// rewrite instead: the timestamp, the title, and the body with its media
    /// links stripped out.
    @discardableResult
    func commitImport(_ preview: ImportPreview) -> ImportResult {
        guard let base = baseURL, let dir = newAssetsDirectory else {
            lastWriteError = "The journal folder is unavailable."
            return ImportResult()
        }
        let outcome = Self.runImport(preview, base: base, assetsDir: dir,
                                     dataSaver: UserDefaults.standard.bool(forKey: "dataSaver"), progress: { _ in })
        return finishImport(outcome)
    }

    /// `commitImport` off the main actor, with `importProgress` moving as it
    /// goes. A five-year Day One export froze the app for minutes: every
    /// distinct date read the whole journal again, and the media was copied on
    /// the main actor.
    @discardableResult
    func commitImportAsync(_ preview: ImportPreview) async -> ImportResult {
        guard let base = baseURL, let dir = newAssetsDirectory else {
            lastWriteError = "The journal folder is unavailable."
            return ImportResult()
        }
        guard importProgress == nil else { return ImportResult() }
        let total = preview.entries.count
        setImportProgress((0, total))
        defer { setImportProgress(nil) }
        let dataSaver = UserDefaults.standard.bool(forKey: "dataSaver")
        let outcome = await Task.detached(priority: .userInitiated) { [weak self] in
            Self.runImport(preview, base: base, assetsDir: dir, dataSaver: dataSaver) { done in
                Task { @MainActor [weak self] in
                    // Never after the end: these arrive in order, but the last
                    // may land once the import has returned.
                    guard let self, self.importProgress != nil else { return }
                    self.setImportProgress((done, total))
                }
            }
        }.value
        return finishImport(outcome)
    }

    private func finishImport(_ outcome: ImportOutcome) -> ImportResult {
        if let error = outcome.error { lastWriteError = error }
        noteImported(compressed: outcome.compressed, saved: outcome.saved, transcode: outcome.transcode,
                     reload: outcome.result.entries > 0 || outcome.result.media > 0)
        return outcome.result
    }

    /// What an import did, and what the store still has to note on the main
    /// actor: the Data Saver ledger and the videos to compress afterwards.
    struct ImportOutcome {
        var result = ImportResult()
        var error: String?
        var compressed: [String] = []
        var saved = 0
        var transcode: [String] = []
    }

    /// The import itself, against one reading of the journal. Nothing here
    /// touches the store, so it runs anywhere.
    nonisolated static func runImport(
        _ preview: ImportPreview, base: URL, assetsDir: URL, dataSaver: Bool, progress: (Int) -> Void
    ) -> ImportOutcome {
        var out = ImportOutcome()
        let core = CoreJournal(base: base)
        // date → how many entries with each key that day file still holds
        // unclaimed. A count rather than a set so an export that really does
        // carry two look-alike entries files both the first time, and skips
        // both — not just one — on a re-run.
        var filed: [String: [String: Int]] = [:]
        do {
            for e in try core.load() where e.source == "journal" {
                let entry = e.entry
                filed[e.date, default: [:]][importKey(ts: entry.ts, title: entry.suffix, body: entry.body), default: 0] += 1
            }
        } catch {
            out.error = journalErrorMessage(error)
            return out
        }
        var toFile: [(date: String, raw: String)] = []
        for (n, prepared) in preview.entries.enumerated() {
            defer { if (n + 1) % 10 == 0 || n + 1 == preview.entries.count { progress(n + 1) } }
            let date = String(prepared.ts.prefix(10))
            let key = importKey(ts: prepared.ts, title: prepared.title, body: prepared.body)
            if let remaining = filed[date]?[key], remaining > 0 {
                filed[date]?[key] = remaining - 1
                out.result.skipped += 1
                continue
            }

            var body = prepared.body
            for m in prepared.media {
                let scoped = m.url.startAccessingSecurityScopedResource()
                defer { if scoped { m.url.stopAccessingSecurityScopedResource() } }
                // Images are stored through Data Saver's downsampler;
                // video/audio copy file-to-file so an export's movies never
                // sit in memory whole (and are queued for transcoding after).
                var stored: URL?
                if MediaKind(path: m.url.lastPathComponent) == .image {
                    if let data = try? Data(contentsOf: m.url),
                       let image = storeAsset(data, ext: m.url.pathExtension.lowercased(), into: assetsDir, dataSaver: dataSaver) {
                        stored = image.url
                        if image.saved > 0 {
                            // By its ledger key (the path under assets/), as the store records it.
                            out.compressed.append(ledgerKey(assetRelPath: relativePath(of: image.url, under: base)))
                            out.saved += image.saved
                        }
                    }
                } else if let copy = copyAsset(from: m.url, into: assetsDir) {
                    stored = copy
                    out.transcode.append(relativePath(of: copy, under: base))
                }
                guard let stored else { continue }
                let rel = relativePath(of: stored, under: base)
                out.result.media += 1
                let link = "![](\(rel))"
                let moment = "![](dayone-moment://\(m.identifier))"
                if body.contains(moment) {
                    body = body.replacingOccurrences(of: moment, with: link)
                } else if let range = body.range(of: #"!\[[^\]]*\]\(dayone-moment:[^)]*\#(m.identifier)[^)]*\)"#,
                                                 options: .regularExpression) {
                    body.replaceSubrange(range, with: link)
                } else {
                    body += (body.isEmpty ? "" : "\n\n") + link
                }
            }
            guard let entry = JournalParser.parseEntries(makeText(ts: prepared.ts, title: prepared.title, body: body)).first else { continue }
            toFile.append((entry.date, entry.raw))
        }
        // Appended day by day, skipping any whose exact text is already there.
        var appended = 0
        for (date, entries) in Dictionary(grouping: toFile, by: \.date) {
            do {
                let count: Int = try core.call("insert", ["file": "journal/" + date.replacingOccurrences(of: "-", with: "/") + ".md",
                                                          "raws": entries.map(\.raw)])
                appended += count
            } catch { out.error = out.error ?? journalErrorMessage(error) }
        }
        out.result.entries = appended
        out.result.skipped += toFile.count - appended
        return out
    }

    /// The identity of an imported entry, stable across the media rewrite:
    /// timestamp + title + body with every `![](…)` link removed and the
    /// remaining whitespace collapsed (stripping a link leaves blank lines
    /// behind, and a link appended to the end leaves a trailing one).
    private nonisolated static func importKey(ts: String, title: String, body: String) -> String {
        let squashed = MediaLinks.strippingLinks(body)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return "\(ts)\u{1}\(title.trimmingCharacters(in: .whitespacesAndNewlines))\u{1}\(squashed)"
    }
}
