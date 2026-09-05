//
//  PDFExport.swift
//  Nook
//
//  Typeset PDF export — a year or the whole journal from Settings, one day
//  from the day view. Each day becomes one PDF page sized to its content
//  (fixed Letter width), rendered through ImageRenderer so the text stays
//  vector. Images render inline; video and audio become captioned lines.
//

import SwiftUI
import UniformTypeIdentifiers

enum PDFExporter {
    static let pageWidth: CGFloat = 612   // US Letter width in points
    /// PDF's own ceiling on a page dimension (200 inches). A day long enough to
    /// exceed it is sliced across several pages rather than silently truncated.
    static let maxPageHeight: CGFloat = 14_400

    /// Render days (oldest first) into a single PDF. Runs on the main actor
    /// (ImageRenderer requires it) but yields between days so a big journal
    /// doesn't freeze the UI.
    @MainActor
    static func makePDF(days: [(date: String, entries: [Entry])],
                        store: JournalStore,
                        dateStyleRaw: String,
                        fontRaw: String,
                        fontSize: CGFloat) async -> Data? {
        guard !days.isEmpty else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }

        for day in days.sorted(by: { $0.date < $1.date }) {
            let page = DayPDFPage(date: day.date,
                                  entries: day.entries,
                                  dateStyleRaw: dateStyleRaw,
                                  fontRaw: fontRaw,
                                  fontSize: fontSize)
                .environmentObject(store)
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)
            renderer.render { size, draw in
                let content = max(size.height, 100)
                // One page per day while the day fits; past the PDF limit the
                // same rendering is cut into equal slices.
                let slices = max(1, Int((content / maxPageHeight).rounded(.up)))
                let pageHeight = slices == 1 ? content : maxPageHeight
                for slice in 0..<slices {
                    var box = CGRect(origin: .zero,
                                     size: CGSize(width: pageWidth, height: pageHeight))
                    ctx.beginPage(mediaBox: &box)
                    // The renderer draws the whole day with its top at
                    // y = content (PDF space is y-up), so shifting it down by a
                    // page at a time brings each slice into the box; slice 0
                    // needs pageHeight - content, which is 0 in the common case.
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: pageHeight * CGFloat(slice + 1) - content)
                    draw(ctx)
                    ctx.restoreGState()
                    ctx.endPDFPage()
                }
            }
            await Task.yield()
        }
        ctx.closePDF()
        return data as Data
    }
}

/// One day, one page: the day header then each entry with its media.
private struct DayPDFPage: View {
    @EnvironmentObject private var store: JournalStore
    let date: String
    let entries: [Entry]
    let dateStyleRaw: String
    let fontRaw: String
    let fontSize: CGFloat

    private var font: Font { Theme.font(fontRaw, size: fontSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Theme.sectionDate(date, style: dateStyleRaw))
                .font(Theme.font(fontRaw, size: fontSize * 1.3).weight(.bold))
            Rectangle().fill(Color.secondary.opacity(0.4)).frame(height: 1)
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(String(entry.ts.suffix(8).prefix(5)))
                            .font(.system(size: fontSize * 0.7).monospacedDigit())
                            .foregroundStyle(.secondary)
                        if entry.isStarred {
                            Image(systemName: "star.fill")
                                .font(.system(size: fontSize * 0.6))
                                .foregroundStyle(.secondary)
                        }
                        if !entry.displayTitle.isEmpty {
                            Text(entry.displayTitle)
                                .font(font.weight(.bold))
                        }
                    }
                    PDFEntryBody(text: entry.body, font: font)
                }
            }
        }
        .padding(40)
        .frame(width: PDFExporter.pageWidth, alignment: .leading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .foregroundStyle(Color(red: 0.15, green: 0.15, blue: 0.15))
    }
}

/// A print-friendly body: markdown text and inline images; video/audio noted
/// as captioned lines (a PDF can't play them).
private struct PDFEntryBody: View {
    @EnvironmentObject private var store: JournalStore
    let text: String
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parseMediaSegments(text).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let t):
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Text((try? AttributedString(
                            markdown: trimmed,
                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                        )) ?? AttributedString(trimmed))
                        .font(font)
                    }
                case .image(let path, let caption):
                    media(path, caption: caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func media(_ path: String, caption: String) -> some View {
        switch MediaKind(path: path) {
        case .image:
            if let url = store.assetURL(forRelative: path),
               let image = RowThumbnail.load(url, side: 1200) {
                VStack(spacing: 4) {
                    image.resizable().scaledToFit()
                        .frame(maxHeight: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if !caption.isEmpty {
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                placeholder("photo", path)
            }
        case .video: placeholder("video", path)
        case .audio: placeholder("voice memo", path)
        }
    }

    private func placeholder(_ kind: String, _ path: String) -> some View {
        Label("[\(kind): \((path as NSString).lastPathComponent)]",
              systemImage: kind == "video" ? "film" : kind == "photo" ? "photo" : "waveform")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A minimal PDF document for `fileExporter`.
struct PDFExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
