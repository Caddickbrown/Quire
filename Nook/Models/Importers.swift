//
//  Importers.swift
//  Nook
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
        for case let file as URL in en where ["md", "txt"].contains(file.pathExtension.lowercased()) {
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
        var result = ImportResult()
        var toFile: [Entry] = []
        // date → how many entries with each key that day file still holds
        // unclaimed. A count rather than a set so an export that really does
        // carry two look-alike entries files both the first time, and skips
        // both — not just one — on a re-run.
        var filed: [String: [String: Int]] = [:]
        for prepared in preview.entries {
            let date = String(prepared.ts.prefix(10))
            if filed[date] == nil {
                var counts: [String: Int] = [:]
                for e in entries(for: date) {
                    counts[Self.importKey(ts: e.ts, title: e.suffix, body: e.body), default: 0] += 1
                }
                filed[date] = counts
            }
            let key = Self.importKey(ts: prepared.ts, title: prepared.title, body: prepared.body)
            if let remaining = filed[date]?[key], remaining > 0 {
                filed[date]?[key] = remaining - 1
                result.skipped += 1
                continue
            }

            var body = prepared.body
            for m in prepared.media {
                let scoped = m.url.startAccessingSecurityScopedResource()
                defer { if scoped { m.url.stopAccessingSecurityScopedResource() } }
                // Images go through saveAsset so Data Saver can downsample;
                // video/audio copy file-to-file so an export's movies never
                // sit in memory whole (importAsset also queues transcoding).
                let rel: String?
                if MediaKind(path: m.url.lastPathComponent) == .image {
                    rel = (try? Data(contentsOf: m.url))
                        .flatMap { saveAsset($0, ext: m.url.pathExtension.lowercased()) }
                } else {
                    rel = importAsset(from: m.url)
                }
                guard let rel else { continue }
                result.media += 1
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
            toFile.append(Self.makeEntry(timestamp: prepared.ts, title: prepared.title, body: body))
        }
        let appended = appendFiledEntries(toFile)
        result.entries = appended
        result.skipped += toFile.count - appended
        return result
    }

    /// The identity of an imported entry, stable across the media rewrite:
    /// timestamp + title + body with every `![](…)` link removed and the
    /// remaining whitespace collapsed (stripping a link leaves blank lines
    /// behind, and a link appended to the end leaves a trailing one).
    private static func importKey(ts: String, title: String, body: String) -> String {
        let stripped = body.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]*\)"#, with: " ", options: .regularExpression)
        let squashed = stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return "\(ts)\u{1}\(title.trimmingCharacters(in: .whitespacesAndNewlines))\u{1}\(squashed)"
    }
}
