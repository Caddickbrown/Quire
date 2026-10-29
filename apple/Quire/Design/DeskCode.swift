//
//  DeskCode.swift
//  Quire
//
//  Hidden mode: the monitor dressed as VS Code on Windows (Dark Modern, the
//  default since 2023). The desk mode's pages, recast as a code editor: the
//  entry is the day file it lives in, shown in its real on-disk form with line
//  numbers; a list is the Explorer, with the selected entry open in a preview
//  tab; Today is a README; settings is the Settings tab. Paused, locked or
//  loading, it is an empty editor with VS Code's watermark, and no journal text.
//  Chosen as a monitor theme (`ExternalTheme.vsCode`); the phone is untouched.
//

#if os(iOS)

import SwiftUI

// MARK: - Palette and sizes

/// VS Code's Dark Modern colours, and Dark+ for the markdown tokens.
private enum VS {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: a)
    }
    static let chrome = hex(0x181818)
    static let border = hex(0x2B2B2B)
    static let editor = hex(0x1F1F1F)
    static let text = hex(0xCCCCCC)
    static let bright = hex(0xFFFFFF)
    static let dim = hex(0x9D9D9D)
    static let icon = hex(0x868686)
    static let lineNumber = hex(0x6E7681)
    static let blue = hex(0x0078D4)
    static let selection = hex(0x37373D)
    static let hover = hex(0x2A2D2E)
    static let currentLine = hex(0x282828)
    static let input = hex(0x313131)
    static let inputBorder = hex(0x3C3C3C)
    static let heading = hex(0x569CD6)
    static let listMark = hex(0x6796E6)
    static let string = hex(0xCE9178)
    static let number = hex(0xB5CEA8)
    static let quote = hex(0x6A9955)
    static let markdown = hex(0x519ABA)
    static let caret = hex(0xAEAFAD)
}

/// VS Code's pixel sizes at 100%, scaled to the monitor and the text-size setting.
private struct VSScale {
    let z: CGFloat
    init(height: CGFloat, scale: CGFloat) { z = max(1, height / 1080) * scale * 1.1 }
    var ui: CGFloat { 13 * z }
    var small: CGFloat { 11 * z }
    var code: CGFloat { 15 * z }
    var lineHeight: CGFloat { code * 1.5 }
    var titleBar: CGFloat { 32 * z }
    var activity: CGFloat { 48 * z }
    var tabs: CGFloat { 35 * z }
    var crumbs: CGFloat { 22 * z }
    var row: CGFloat { 22 * z }
    var status: CGFloat { 22 * z }
    var taskbar: CGFloat { 48 * z }
    var mono: Font { .system(size: code, design: .monospaced) }
}

// MARK: - What the editor shows

private struct VSTreeRow: Identifiable {
    enum Kind { case open, closed, file }
    let id: String
    let depth: Int
    let name: String
    let kind: Kind
}

private struct VSFile {
    var path: [String]          // folders under the workspace root
    var name: String
    var lines: [String]
    /// Line and column of the caret, both from 0.
    var caret: (line: Int, col: Int)?
    var preview = false
    var tree: [VSTreeRow]
    var selectedRow: String?
}

private enum VSPage {
    case empty
    case file(VSFile)
    case settings
}

private enum VSFiles {
    static let tops = ["assets", "inbox", "journal"]

    /// The workspace's top folders, `open` expanded with `children` beneath it.
    static func tree(open: String?, children: [VSTreeRow]) -> [VSTreeRow] {
        var rows = [VSTreeRow(id: ".quire", depth: 0, name: ".quire", kind: .closed)]
        for top in tops {
            rows.append(VSTreeRow(id: top, depth: 0, name: top, kind: top == open ? .open : .closed))
            if top == open { rows += children }
        }
        rows.append(VSTreeRow(id: "README.md", depth: 0, name: "README.md", kind: .file))
        rows.append(VSTreeRow(id: "transfer.md", depth: 0, name: "transfer.md", kind: .file))
        return rows
    }

    /// An entry as its day file: `top/YYYY/MM/DD.md`, opened in the tree.
    /// `inTitle` puts the caret on the header line, after the title.
    static func entry(top: String, date: Date, title: String, text: String, starred: Bool, caret: Int?,
                      inTitle: Bool = false) -> VSFile {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", parts.year ?? 2000)
        let month = String(format: "%02d", parts.month ?? 1)
        let name = String(format: "%02d.md", parts.day ?? 1)
        var header = "[" + stamp.string(from: date) + "]"
        if !title.isEmpty { header += " " + title }
        let titleEnd = header.count
        if starred && !Entry.hasStarMarker(title) { header += " *" }
        let body = text.components(separatedBy: "\n")
        var caretAt: (Int, Int)?
        if inTitle {
            caretAt = (0, titleEnd)
        } else if let caret {
            let utf16 = text.utf16
            let offset = min(max(0, caret), utf16.count)
            let before = String(utf16.prefix(offset)) ?? ""
            let lines = before.components(separatedBy: "\n")
            caretAt = (lines.count, lines.last?.count ?? 0)   // +1 for the header line, so count not count-1
        }
        let children = [
            VSTreeRow(id: "\(top)/\(year)", depth: 1, name: year, kind: .open),
            VSTreeRow(id: "\(top)/\(year)/\(month)", depth: 2, name: month, kind: .open),
            VSTreeRow(id: "\(top)/\(year)/\(month)/\(name)", depth: 3, name: name, kind: .file),
        ]
        return VSFile(path: [top, year, month], name: name, lines: [header] + body, caret: caretAt,
                      tree: tree(open: top, children: children), selectedRow: "\(top)/\(year)/\(month)/\(name)")
    }

    /// A list as folders of files, the selected entry open in a preview tab.
    static func browse(listTitle: String, rows: [ExternalRow], selected: Int) -> VSFile {
        let top = listTitle == "Inbox" ? "inbox" : "journal"
        var children: [VSTreeRow] = []
        var year = "", month = ""
        var selectedID: String?
        for (i, row) in rows.enumerated() {
            let y = String(row.date.prefix(4)), m = String(row.date.dropFirst(5).prefix(2))
            if y != year { year = y; month = ""; children.append(VSTreeRow(id: "\(top)/\(y)", depth: 1, name: y, kind: .open)) }
            if m != month { month = m; children.append(VSTreeRow(id: "\(top)/\(y)/\(m)", depth: 2, name: m, kind: .open)) }
            let id = "\(top)/\(row.id)/\(i)"
            children.append(VSTreeRow(id: id, depth: 3, name: fileName(row), kind: .file))
            if i == selected { selectedID = id }
        }
        guard rows.indices.contains(selected) else {
            return VSFile(path: [top], name: "", lines: [], tree: tree(open: top, children: children))
        }
        let row = rows[selected]
        let header = "[\(row.date)\(row.time.isEmpty ? "" : " " + row.time + ":00")]" + (row.title.isEmpty ? "" : " " + row.title)
            + (row.starred ? " *" : "")
        return VSFile(path: [top, String(row.date.prefix(4)), String(row.date.dropFirst(5).prefix(2))],
                      name: fileName(row), lines: [header] + row.body.components(separatedBy: "\n"),
                      preview: true, tree: tree(open: top, children: children), selectedRow: selectedID)
    }

    /// `29-a-walk-by-the-river.md`, or `29-0812.md` untitled.
    static func fileName(_ row: ExternalRow) -> String {
        let day = String(row.date.suffix(2))
        let slug = row.title.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").prefix(6).joined(separator: "-")
        let rest = slug.isEmpty ? row.time.replacingOccurrences(of: ":", with: "") : String(slug.prefix(40))
        return rest.isEmpty ? day + ".md" : "\(day)-\(rest).md"
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
}

// MARK: - The window

struct DeskCode: View {
    let store: JournalStore?
    let hints: [ShortcutHint]
    let scale: CGFloat
    @ObservedObject private var model = ExternalDisplayModel.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @ObservedObject private var settings = ExternalSettingsModel.shared

    var body: some View {
        GeometryReader { geo in
            let s = VSScale(height: geo.size.height, scale: scale)
            Group {
                // Journal text never reaches the monitor while paused or locked.
                if let store, !model.isPaused, !appLock.showsVeil {
                    VSLive(content: model.content, settingsOpen: settings.isOpen, hints: hints, s: s)
                        .environmentObject(store)
                } else {
                    VSWindow(page: .empty, hints: [], s: s)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }
}

/// Turns what the desk would show into a file in the editor.
private struct VSLive: View {
    let content: ExternalDisplayContent
    let settingsOpen: Bool
    let hints: [ShortcutHint]
    let s: VSScale
    @EnvironmentObject private var store: JournalStore
    @AppStorage(QuirePrompts.offsetKey, store: QuirePrompts.defaults) private var promptOffset = 0

    var body: some View {
        VSWindow(page: page, hints: hints, s: s)
    }

    private var page: VSPage {
        if settingsOpen { return .settings }
        switch content {
        case .idle:
            return .file(readme)
        case .browsing(let listTitle, let rows, let selected, _, _):
            return .file(VSFiles.browse(listTitle: listTitle, rows: rows, selected: selected))
        case .composing(let title, let date, let text, let caret, let inTitle):
            return .file(VSFiles.entry(top: "inbox", date: date, title: title, text: text, starred: false,
                                       caret: caret ?? text.utf16.count, inTitle: inTitle))
        case .editing(let title, let date, let text, let caret, let isStarred, let isDraft, let inTitle):
            return .file(VSFiles.entry(top: isDraft ? "inbox" : "journal", date: date, title: title, text: text, starred: isStarred,
                                       caret: caret ?? text.utf16.count, inTitle: inTitle))
        case .reading(let title, let date, let text, let isStarred):
            return .file(VSFiles.entry(top: "journal", date: date, title: title, text: text, starred: isStarred, caret: nil))
        }
    }

    /// Today, as a README at the workspace root.
    private var readme: VSFile {
        let stats = store.stats()
        let drafts = store.inboxDrafts.count
        var lines = ["# Today", "", QDate.longDay(), "",
                     "- \(stats.currentStreak) day streak",
                     "- \(stats.entries) entries",
                     "- \(stats.words) words",
                     "- \(drafts) \(drafts == 1 ? "draft" : "drafts") waiting", "",
                     "## Begin a new entry (`n`)", "",
                     "> " + QuirePrompts.prompt(offset: promptOffset)]
        if let past = store.qOnThisDay().first {
            lines += ["", "## On this day · " + String(past.date.prefix(4)), ""]
            lines += past.entries.prefix(2).map { "- " + ($0.qTitle.isEmpty ? "Untitled" : $0.qTitle) }
        }
        return VSFile(path: [], name: "README.md", lines: lines, tree: VSFiles.tree(open: nil, children: []), selectedRow: "README.md")
    }
}

private struct VSWindow: View {
    let page: VSPage
    let hints: [ShortcutHint]
    let s: VSScale

    private var file: VSFile? { if case .file(let f) = page { return f } else { return nil } }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                VSTitleBar(s: s)
                HStack(spacing: 0) {
                    VSActivityBar(s: s)
                    VSExplorer(tree: file?.tree ?? VSFiles.tree(open: nil, children: []), selected: file?.selectedRow, s: s)
                        .frame(width: min(max(geo.size.width * 0.17, 220 * s.z), 340 * s.z))
                    editorGroup
                }
                VSStatusBar(caret: file?.caret, showsFile: file != nil && !(file?.name.isEmpty ?? true), hints: hints, s: s)
                VSTaskbar(s: s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(VS.editor)
        .foregroundStyle(VS.text)
    }

    @ViewBuilder private var editorGroup: some View {
        switch page {
        case .empty:
            VSWatermark(s: s).frame(maxWidth: .infinity, maxHeight: .infinity).background(VS.editor)
        case .file(let f) where f.name.isEmpty:
            VSWatermark(s: s).frame(maxWidth: .infinity, maxHeight: .infinity).background(VS.editor)
        case .file(let f):
            VStack(spacing: 0) {
                VSTabs(name: f.name, italic: f.preview, settings: false, s: s)
                VSCrumbs(path: f.path, name: f.name, s: s)
                VSEditor(file: f, s: s)
            }
        case .settings:
            VStack(spacing: 0) {
                VSTabs(name: "Settings", italic: false, settings: true, s: s)
                VSSettings(s: s)
            }
        }
    }
}

// MARK: - Chrome

private struct VSTitleBar: View {
    let s: VSScale

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: s.ui, weight: .bold)).foregroundStyle(VS.hex(0x3EA6FF))
                .frame(width: s.activity)
            ForEach(["File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Help"], id: \.self) {
                Text($0).font(.system(size: s.ui)).padding(.horizontal, 7 * s.z)
            }
            Spacer(minLength: 8 * s.z)
            HStack(spacing: 14 * s.z) {
                Image(systemName: "arrow.left"); Image(systemName: "arrow.right")
            }
            .font(.system(size: s.small)).foregroundStyle(VS.icon).padding(.trailing, 8 * s.z)
            HStack(spacing: 6 * s.z) {
                Image(systemName: "magnifyingglass").font(.system(size: s.small))
                Text("notes").font(.system(size: s.ui))
            }
            .foregroundStyle(VS.dim)
            .frame(maxWidth: 34 * s.ui).frame(height: 22 * s.z)
            .background(VS.hex(0x2A2A2A), in: RoundedRectangle(cornerRadius: 6 * s.z))
            .overlay(RoundedRectangle(cornerRadius: 6 * s.z).stroke(VS.inputBorder, lineWidth: 1))
            Spacer(minLength: 8 * s.z)
            HStack(spacing: 16 * s.z) {
                Image(systemName: "sidebar.left"); Image(systemName: "rectangle.bottomthird.inset.filled")
                Image(systemName: "sidebar.right"); Image(systemName: "rectangle.split.2x2")
            }
            .font(.system(size: s.ui, weight: .light)).foregroundStyle(VS.text).padding(.trailing, 14 * s.z)
            ForEach(["minus", "square.on.square", "xmark"], id: \.self) {
                Image(systemName: $0).font(.system(size: s.small * 0.95, weight: .ultraLight))
                    .frame(width: 46 * s.z, height: s.titleBar)
            }
        }
        .lineLimit(1)
        .frame(height: s.titleBar)
        .background(VS.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(VS.border).frame(height: 1) }
    }
}

private struct VSActivityBar: View {
    let s: VSScale

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(["doc.on.doc", "magnifyingglass", "arrow.triangle.branch", "play", "square.grid.2x2"].enumerated()), id: \.offset) { i, name in
                icon(name, active: i == 0)
            }
            Spacer()
            icon("person.crop.circle", active: false)
            icon("gearshape", active: false)
        }
        .frame(width: s.activity)
        .background(VS.chrome)
        .overlay(alignment: .trailing) { Rectangle().fill(VS.border).frame(width: 1) }
    }

    private func icon(_ name: String, active: Bool) -> some View {
        Image(systemName: name).font(.system(size: 22 * s.z, weight: .light))
            .foregroundStyle(active ? VS.hex(0xD7D7D7) : VS.icon)
            .frame(width: s.activity, height: s.activity)
            .overlay(alignment: .leading) { if active { Rectangle().fill(VS.blue).frame(width: 2 * s.z) } }
    }
}

private struct VSExplorer: View {
    let tree: [VSTreeRow]
    let selected: String?
    let s: VSScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EXPLORER").font(.system(size: s.small)).tracking(0.3)
                Spacer()
                Image(systemName: "ellipsis").font(.system(size: s.ui))
            }
            .padding(.horizontal, 20 * s.z).frame(height: 35 * s.z)
            section("NOTES", open: true)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tree) { row($0).id($0.id) }
                    }
                }
                .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
                .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            }
            Spacer(minLength: 0)
            section("OUTLINE", open: false)
            section("TIMELINE", open: false)
        }
        .background(VS.chrome)
        .overlay(alignment: .trailing) { Rectangle().fill(VS.border).frame(width: 1) }
        .lineLimit(1)
    }

    private func section(_ title: String, open: Bool) -> some View {
        HStack(spacing: 4 * s.z) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: s.small * 0.8, weight: .semibold))
                .frame(width: 16 * s.z)
            Text(title).font(.system(size: s.small, weight: .bold))
            Spacer()
        }
        .padding(.leading, 2 * s.z).frame(height: s.row)
        .overlay(alignment: .top) { if !open { Rectangle().fill(VS.border).frame(height: 1) } }
    }

    private func row(_ row: VSTreeRow) -> some View {
        let on = row.id == selected
        return HStack(spacing: 6 * s.z) {
            switch row.kind {
            case .open, .closed:
                Image(systemName: row.kind == .open ? "chevron.down" : "chevron.right")
                    .font(.system(size: s.small * 0.8, weight: .semibold)).frame(width: 16 * s.z)
            case .file:
                Text("M↓").font(.system(size: s.small * 0.75, weight: .heavy)).foregroundStyle(VS.markdown)
                    .frame(width: 16 * s.z)
            }
            Text(row.name).font(.system(size: s.ui))
            Spacer(minLength: 0)
        }
        .padding(.leading, (8 + CGFloat(row.depth) * 8) * s.z)
        .frame(height: s.row)
        .background(on ? VS.selection : Color.clear)
        .overlay { if on { Rectangle().stroke(VS.blue, lineWidth: 1) } }
        .overlay(alignment: .leading) {
            // VS Code's indent guides.
            HStack(spacing: 0) {
                ForEach(0..<row.depth, id: \.self) { d in
                    Rectangle().fill(VS.hex(0x585858, 0.4)).frame(width: 1)
                        .padding(.leading, d == 0 ? 15 * s.z : 7 * s.z)
                }
            }
        }
    }
}

private struct VSTabs: View {
    let name: String
    let italic: Bool
    let settings: Bool
    let s: VSScale

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6 * s.z) {
                if settings {
                    Image(systemName: "gearshape").font(.system(size: s.ui))
                } else {
                    Text("M↓").font(.system(size: s.small * 0.75, weight: .heavy)).foregroundStyle(VS.markdown)
                }
                Text(name).font(.system(size: s.ui)).italic(italic)
                Image(systemName: "xmark").font(.system(size: s.small * 0.85)).padding(.leading, 6 * s.z)
            }
            .foregroundStyle(VS.bright)
            .padding(.horizontal, 12 * s.z)
            .frame(height: s.tabs)
            .background(VS.editor)
            .overlay(alignment: .top) { Rectangle().fill(VS.blue).frame(height: 1) }
            .overlay(alignment: .trailing) { Rectangle().fill(VS.border).frame(width: 1) }
            Spacer(minLength: 0)
            HStack(spacing: 14 * s.z) {
                if !settings { Image(systemName: "rectangle.split.2x1") }
                Image(systemName: "ellipsis")
            }
            .font(.system(size: s.ui)).foregroundStyle(VS.text).padding(.trailing, 12 * s.z)
        }
        .frame(height: s.tabs)
        .background(VS.chrome.overlay(alignment: .bottom) { Rectangle().fill(VS.border).frame(height: 1) })
        .lineLimit(1)
    }
}

private struct VSCrumbs: View {
    let path: [String]
    let name: String
    let s: VSScale

    var body: some View {
        HStack(spacing: 4 * s.z) {
            ForEach(Array(path.enumerated()), id: \.offset) { _, part in
                Text(part)
                Image(systemName: "chevron.right").font(.system(size: s.small * 0.7))
            }
            Text("M↓").font(.system(size: s.small * 0.7, weight: .heavy)).foregroundStyle(VS.markdown)
            Text(name)
            Spacer(minLength: 0)
        }
        .font(.system(size: s.ui * 0.95)).foregroundStyle(VS.hex(0xA9A9A9))
        .lineLimit(1)
        .padding(.leading, 18 * s.z)
        .frame(height: s.crumbs)
        .background(VS.editor)
    }
}

private struct VSStatusBar: View {
    let caret: (line: Int, col: Int)?
    let showsFile: Bool
    let hints: [ShortcutHint]
    let s: VSScale
    @AppStorage(ShortcutHints.key) private var showHints = true

    var body: some View {
        HStack(spacing: 0) {
            Text("><").font(.system(size: s.small, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 10 * s.z).frame(maxHeight: .infinity).background(VS.blue)
            item { Image(systemName: "arrow.triangle.branch"); Text("main") }
            item { Image(systemName: "xmark.circle"); Text("0"); Image(systemName: "exclamationmark.triangle"); Text("0") }
            // The keys that work, dressed as extension items.
            if showHints {
                ForEach(hints) { hint in item { Text(hint.key); Text(hint.label) } }
            }
            Spacer(minLength: 8 * s.z)
            if showsFile {
                item { Text("Ln \((caret?.line ?? 0) + 1), Col \((caret?.col ?? 0) + 1)") }
                item { Text("Spaces: 4") }
                item { Text("UTF-8") }
                item { Text("CRLF") }
                item { Text("{ }"); Text("Markdown") }
            }
            item { Image(systemName: "bell") }
        }
        .font(.system(size: s.small * 1.05))
        .lineLimit(1)
        .frame(height: s.status)
        .background(VS.chrome)
        .overlay(alignment: .top) { Rectangle().fill(VS.border).frame(height: 1) }
    }

    private func item<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 4 * s.z) { content() }.padding(.horizontal, 6 * s.z)
    }
}

/// Windows 11's taskbar under the maximised window, in its light mode: Start
/// and the pinned apps in the middle (Teams open with a notification, VS Code
/// open and in front), the tray and clock right.
private struct VSTaskbar: View {
    let s: VSScale

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"; return f
    }()
    private static let ink = VS.hex(0x1A1A1A)

    private enum Running { case no, open, front }
    private var d: CGFloat { 24 * s.z }

    var body: some View {
        ZStack {
            HStack(spacing: 4 * s.z) {
                // Drawn look-alikes: the right colours and rough shapes to
                // read at a glance, not the companies' artwork.
                app { startLogo }
                app { VSIcon.files(d) }
                app { VSIcon.browser(d) }
                app { VSIcon.assistant(d) }
                app { VSIcon.calculator(d) }
                app { VSIcon.notepad(d) }
                app { VSIcon.mail(d) }
                app(.open, badge: 1) { VSIcon.chat(d) }
                app { VSIcon.sheets(d) }
                app(.front) { VSIcon.editor(d) }
            }
            HStack(spacing: 0) {
                Spacer()
                Image(systemName: "chevron.up").font(.system(size: s.small)).padding(.horizontal, 10 * s.z)
                HStack(spacing: 10 * s.z) {
                    Image(systemName: "wifi"); Image(systemName: "speaker.wave.2.fill")
                }
                .font(.system(size: s.ui)).padding(.horizontal, 10 * s.z)
                TimelineView(.everyMinute) { t in
                    VStack(alignment: .trailing, spacing: 2 * s.z) {
                        Text(Self.time.string(from: t.date))
                        Text(Self.day.string(from: t.date))
                    }
                    .font(.system(size: s.small * 1.05))
                }
                .padding(.horizontal, 10 * s.z)
                Image(systemName: "bell").font(.system(size: s.ui)).padding(.leading, 6 * s.z).padding(.trailing, 14 * s.z)
            }
        }
        .foregroundStyle(Self.ink)
        .lineLimit(1)
        .frame(height: s.taskbar)
        .background(VS.hex(0xEEF0F3))
        .overlay(alignment: .top) { Rectangle().fill(VS.hex(0xD9D9D9)).frame(height: 1) }
        .environment(\.colorScheme, .light)
    }

    /// The four blue panes.
    private var startLogo: some View {
        let pane = 9.5 * s.z, gap = 1.2 * s.z
        let fill = LinearGradient(colors: [VS.hex(0x2BA6F5), VS.hex(0x0067C0)], startPoint: .topLeading, endPoint: .bottomTrailing)
        return Grid(horizontalSpacing: gap, verticalSpacing: gap) {
            GridRow { Rectangle().fill(fill).frame(width: pane, height: pane); Rectangle().fill(fill).frame(width: pane, height: pane) }
            GridRow { Rectangle().fill(fill).frame(width: pane, height: pane); Rectangle().fill(fill).frame(width: pane, height: pane) }
        }
    }

    private func app<C: View>(_ running: Running = .no, badge: Int = 0, @ViewBuilder _ icon: () -> C) -> some View {
        icon()
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 9 * s.z, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 14 * s.z, height: 14 * s.z)
                        .background(VS.hex(0xC42B1C), in: Circle())
                        .overlay(Circle().stroke(VS.hex(0xEEF0F3), lineWidth: 1.5 * s.z))
                        .offset(x: 6 * s.z, y: -6 * s.z)
                }
            }
            .frame(width: 40 * s.z, height: 40 * s.z)
            .background(running == .front ? VS.hex(0xFFFFFF, 0.8) : .clear, in: RoundedRectangle(cornerRadius: 4 * s.z))
            .overlay(alignment: .bottom) {
                switch running {
                case .no: EmptyView()
                case .open: Capsule().fill(VS.hex(0x868686)).frame(width: 6 * s.z, height: 3 * s.z).padding(.bottom, 1 * s.z)
                case .front: Capsule().fill(VS.hex(0x005FB8)).frame(width: 16 * s.z, height: 3 * s.z).padding(.bottom, 1 * s.z)
                }
            }
    }
}

/// Taskbar icons in the spirit of the usual Windows apps, drawn from plain
/// shapes. Each is a `d`-point square.
private enum VSIcon {
    private static func c(_ v: UInt32) -> Color { VS.hex(v) }
    private static func grad(_ a: UInt32, _ b: UInt32, _ from: UnitPoint = .top, _ to: UnitPoint = .bottom) -> LinearGradient {
        LinearGradient(colors: [c(a), c(b)], startPoint: from, endPoint: to)
    }

    /// A manila folder: darker back with a tab, lighter front, a blue band.
    static func files(_ d: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: d * 0.08, topTrailingRadius: d * 0.08)
                .fill(c(0xE3A21A)).frame(width: d * 0.42, height: d * 0.2).offset(y: d * 0.12)
            RoundedRectangle(cornerRadius: d * 0.08).fill(c(0xE8A923))
                .frame(width: d * 0.92, height: d * 0.62).offset(y: d * 0.2)
            RoundedRectangle(cornerRadius: d * 0.08).fill(grad(0xFFD86B, 0xF6BE33))
                .frame(width: d * 0.92, height: d * 0.5).offset(y: d * 0.36)
            Rectangle().fill(grad(0x3FA2E8, 0x1E78D0, .leading, .trailing))
                .frame(width: d * 0.36, height: d * 0.08).offset(x: d * 0.48, y: d * 0.72)
        }
        .frame(width: d, height: d, alignment: .topLeading).offset(x: d * 0.04)
    }

    /// A globe-ish wave: a blue-to-green disc with a turned-in curl.
    static func browser(_ d: CGFloat) -> some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [c(0x1A7FD4), c(0x2EC5E8), c(0x46C66A), c(0x1A7FD4)], center: .center))
            Circle().fill(grad(0x0F4F9A, 0x1B78C8)).frame(width: d * 0.56, height: d * 0.56)
                .offset(x: d * 0.12, y: d * 0.06)
            Circle().fill(c(0x55D3F2)).frame(width: d * 0.26, height: d * 0.26)
                .offset(x: d * 0.1, y: d * 0.08)
        }
        .frame(width: d * 0.9, height: d * 0.9).clipShape(Circle())
    }

    /// Two soft lozenges crossing, in a sunset gradient.
    static func assistant(_ d: CGFloat) -> some View {
        let fill = LinearGradient(colors: [c(0x2C8BF2), c(0x8E5CF0), c(0xE96AA8), c(0xF5A04B)],
                                  startPoint: .bottomLeading, endPoint: .topTrailing)
        return ZStack {
            Capsule().fill(fill).frame(width: d * 0.42, height: d * 0.86).rotationEffect(.degrees(35)).offset(x: -d * 0.12)
            Capsule().fill(fill).frame(width: d * 0.42, height: d * 0.86).rotationEffect(.degrees(35)).offset(x: d * 0.14)
                .opacity(0.9)
        }
        .frame(width: d, height: d)
    }

    /// A dark slab: a display strip and a little keypad with one blue key.
    static func calculator(_ d: CGFloat) -> some View {
        let key = d * 0.16
        return VStack(spacing: d * 0.06) {
            RoundedRectangle(cornerRadius: d * 0.03).fill(c(0x6B6B6B)).frame(height: d * 0.14)
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: d * 0.06) {
                    ForEach(0..<3, id: \.self) { col in
                        RoundedRectangle(cornerRadius: d * 0.03)
                            .fill(row == 1 && col == 2 ? c(0x4CA6F0) : c(0x9A9A9A))
                            .frame(width: key, height: key)
                    }
                }
            }
        }
        .padding(d * 0.1)
        .frame(width: d * 0.78, height: d * 0.92)
        .background(grad(0x4A4A4E, 0x2E2E32), in: RoundedRectangle(cornerRadius: d * 0.12))
    }

    /// A blue pad with ruled lines and rings along the top.
    static func notepad(_ d: CGFloat) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: d * 0.1).fill(grad(0x8FCBFA, 0x4FA3EC))
                .frame(width: d * 0.76, height: d * 0.86).offset(y: d * 0.1)
            VStack(spacing: d * 0.11) {
                ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white.opacity(0.9)).frame(width: d * 0.46, height: d * 0.05) }
            }
            .offset(y: d * 0.38)
            HStack(spacing: d * 0.1) {
                ForEach(0..<3, id: \.self) { _ in Capsule().fill(c(0x1F5FA8)).frame(width: d * 0.07, height: d * 0.2) }
            }
            .offset(y: d * 0.02)
        }
        .frame(width: d, height: d, alignment: .top)
    }

    /// An envelope tile with a smaller badge tile in front holding a ring.
    static func mail(_ d: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: d * 0.1).fill(grad(0x3BB6F3, 0x1180D4))
                .frame(width: d * 0.62, height: d * 0.7).offset(x: d * 0.16)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: d * 0.31, y: d * 0.22))
                p.addLine(to: CGPoint(x: d * 0.62, y: 0))
            }
            .stroke(.white.opacity(0.75), lineWidth: d * 0.05)
            .frame(width: d * 0.62, height: d * 0.3).offset(x: d * 0.16, y: -d * 0.08)
            RoundedRectangle(cornerRadius: d * 0.08).fill(c(0x0B5CAD))
                .frame(width: d * 0.48, height: d * 0.48).offset(x: -d * 0.17, y: d * 0.08)
            Circle().stroke(.white, lineWidth: d * 0.07).frame(width: d * 0.24, height: d * 0.24)
                .offset(x: -d * 0.17, y: d * 0.08)
        }
        .frame(width: d, height: d)
    }

    /// Two heads behind a violet badge.
    static func chat(_ d: CGFloat) -> some View {
        ZStack {
            Circle().fill(c(0x9EA4F2)).frame(width: d * 0.24).offset(x: d * 0.3, y: -d * 0.22)
            RoundedRectangle(cornerRadius: d * 0.14).fill(c(0x9EA4F2)).frame(width: d * 0.3, height: d * 0.4).offset(x: d * 0.3, y: d * 0.12)
            Circle().fill(c(0x7B83EB)).frame(width: d * 0.3).offset(x: d * 0.1, y: -d * 0.26)
            RoundedRectangle(cornerRadius: d * 0.16).fill(c(0x7B83EB)).frame(width: d * 0.42, height: d * 0.5).offset(x: d * 0.1, y: d * 0.12)
            RoundedRectangle(cornerRadius: d * 0.08).fill(grad(0x5A62D6, 0x434BB0))
                .frame(width: d * 0.5, height: d * 0.5).offset(x: -d * 0.18, y: d * 0.04)
            VStack(spacing: 0) {
                Capsule().fill(.white).frame(width: d * 0.28, height: d * 0.07)
                Rectangle().fill(.white).frame(width: d * 0.07, height: d * 0.22)
            }
            .offset(x: -d * 0.18, y: d * 0.04)
        }
        .frame(width: d, height: d)
    }

    /// A ruled green sheet with a darker badge holding a cross.
    static func sheets(_ d: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: d * 0.08).fill(c(0x21A366))
                .frame(width: d * 0.66, height: d * 0.82).offset(x: d * 0.15)
            VStack(spacing: d * 0.12) {
                ForEach(0..<3, id: \.self) { _ in Rectangle().fill(c(0x33C481)).frame(width: d * 0.3, height: d * 0.06) }
            }
            .offset(x: d * 0.28)
            RoundedRectangle(cornerRadius: d * 0.08).fill(c(0x107C41))
                .frame(width: d * 0.48, height: d * 0.48).offset(x: -d * 0.17)
            ZStack {
                Capsule().fill(.white).frame(width: d * 0.06, height: d * 0.3).rotationEffect(.degrees(30))
                Capsule().fill(.white).frame(width: d * 0.06, height: d * 0.3).rotationEffect(.degrees(-30))
            }
            .offset(x: -d * 0.17)
        }
        .frame(width: d, height: d)
    }

    /// A blue fold: a tall bar on the right with a bracket opening left.
    static func editor(_ d: CGFloat) -> some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: d * 0.72, y: d * 0.18))
                p.addLine(to: CGPoint(x: d * 0.22, y: d * 0.6))
                p.move(to: CGPoint(x: d * 0.72, y: d * 0.82))
                p.addLine(to: CGPoint(x: d * 0.22, y: d * 0.4))
            }
            .stroke(grad(0x2FA0F0, 0x0868B8), style: StrokeStyle(lineWidth: d * 0.13, lineCap: .round))
            RoundedRectangle(cornerRadius: d * 0.08).fill(grad(0x34A9F5, 0x0A6FC2))
                .frame(width: d * 0.2, height: d * 0.84).offset(x: d * 0.32)
        }
        .frame(width: d, height: d)
    }
}

// MARK: - The editor

private struct VSEditor: View {
    let file: VSFile
    let s: VSScale
    /// When the caret last moved: like VS Code, it holds solid while you type
    /// and only blinks once you stop.
    @State private var moved = Date()

    private var caretKey: String { file.caret.map { "\($0.line):\($0.col)" } ?? "" }

    private var gutter: CGFloat { CGFloat(max(3, String(file.lines.count).count)) * s.code * 0.62 + 30 * s.z }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(file.lines.enumerated()), id: \.offset) { i, line in
                            lineView(i, line).id(i)
                        }
                    }
                    .padding(.bottom, 200 * s.z)
                }
                .onChange(of: file.caret?.line) { _, line in if let line { proxy.scrollTo(line) } }
                .onChange(of: caretKey) { _, _ in moved = Date() }
                .onAppear { if let line = file.caret?.line { proxy.scrollTo(line, anchor: .center) } }
            }
            VSMinimap(lines: file.lines, s: s)
        }
        .background(VS.editor)
    }

    private func lineView(_ i: Int, _ line: String) -> some View {
        let current = file.caret?.line == i
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(i + 1)").font(s.mono).foregroundStyle(current ? VS.text : VS.lineNumber)
                .frame(width: gutter - 26 * s.z, alignment: .trailing)
                .padding(.trailing, 26 * s.z)
            Group {
                if current, let col = file.caret?.col {
                    TimelineView(.periodic(from: moved, by: 0.53)) { t in
                        let on = Int(max(0, t.date.timeIntervalSince(moved)) / 0.53) % 2 == 0
                        Text(VSMarkdown.styled(line, s: s, caret: col, caretOn: on))
                            .overlay(alignment: .topLeading) {
                                if col == 0 {
                                    Rectangle().fill(on ? VS.caret : .clear)
                                        .frame(width: max(1, 1.5 * s.z), height: s.code * 1.25)
                                        .offset(x: -max(1, 1.5 * s.z) / 2)
                                }
                            }
                    }
                } else {
                    Text(VSMarkdown.styled(line, s: s, caret: nil, caretOn: false))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineSpacing(s.lineHeight - s.code * 1.2)
        .padding(.vertical, (s.lineHeight - s.code * 1.2) / 2)
        .frame(minHeight: s.lineHeight)
        .overlay { if current { Rectangle().stroke(VS.currentLine, lineWidth: 2 * s.z) } }
    }
}

/// VS Code's minimap, as blocks rather than letters.
private struct VSMinimap: View {
    let lines: [String]
    let s: VSScale

    var body: some View {
        Canvas { ctx, size in
            let h = 3 * s.z, wrap = 110
            var y: CGFloat = 4 * s.z
            for line in lines {
                let rows = max(1, (line.count + wrap - 1) / wrap)
                for r in 0..<rows {
                    let n = min(wrap, line.count - r * wrap)
                    if n > 0 {
                        let colour = line.hasPrefix("#") || line.hasPrefix("[") ? VS.heading : VS.text
                        ctx.fill(Path(CGRect(x: 6 * s.z, y: y, width: CGFloat(n) * size.width / CGFloat(wrap + 10), height: h * 0.7)),
                                 with: .color(colour.opacity(0.35)))
                    }
                    y += h
                    if y > size.height { return }
                }
            }
        }
        .frame(width: 80 * s.z)
        .background(VS.editor)
        .overlay(alignment: .leading) { Rectangle().fill(VS.hex(0x000000, 0.25)).frame(width: 1) }
    }
}

private enum VSMarkdown {
    private static let header = try! NSRegularExpression(pattern: #"^\[\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?\]"#)
    private static let inline = try! NSRegularExpression(pattern: #"(!?\[[^\]]*\]\([^)]*\))|(\*\*[^*]+\*\*)|(`[^`]+`)|((?<![\w#])#[A-Za-z][\w-]*)"#)

    /// One line coloured the way Dark+ colours markdown, with the caret drawn in.
    static func styled(_ line: String, s: VSScale, caret: Int?, caretOn: Bool) -> AttributedString {
        let mono = s.mono
        var out = AttributedString(line.isEmpty ? " " : line)
        out.font = mono
        out.foregroundColor = VS.text
        let ns = line as NSString
        func paint(_ range: NSRange, _ colour: Color, bold: Bool = false) {
            guard let r = Range(range, in: line),
                  let lo = AttributedString.Index(r.lowerBound, within: out),
                  let hi = AttributedString.Index(r.upperBound, within: out) else { return }
            out[lo..<hi].foregroundColor = colour
            if bold { out[lo..<hi].font = mono.bold() }
        }
        let whole = NSRange(location: 0, length: ns.length)
        let trimmed = line.drop { $0 == " " }
        if let m = header.firstMatch(in: line, range: whole) {
            paint(m.range, VS.number)
            paint(NSRange(location: m.range.upperBound, length: ns.length - m.range.upperBound), VS.heading, bold: true)
        } else if trimmed.hasPrefix("#") && trimmed.drop(while: { $0 == "#" }).hasPrefix(" ") {
            paint(whole, VS.heading, bold: true)
        } else if trimmed.hasPrefix(">") {
            paint(whole, VS.quote)
        } else {
            let lead = line.count - trimmed.count
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                paint(NSRange(location: lead, length: 1), VS.listMark)
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty {
                paint(NSRange(location: lead, length: trimmed.distance(from: trimmed.startIndex, to: dot) + 1), VS.listMark)
            }
            for m in inline.matches(in: line, range: whole) {
                if m.range(at: 2).location != NSNotFound { paint(m.range, VS.text, bold: true) }
                else if m.range(at: 4).location != NSNotFound { paint(m.range, VS.listMark) }
                else { paint(m.range, VS.string) }
            }
        }
        if let caret {
            // A full-height bar that takes no room: half its width comes off the
            // character before it and half off itself, so it sits on the
            // boundary and nothing after it moves. Box-drawing, not "|", which
            // is a line-break opportunity and would rewrap the line as it moved.
            let advance = ("│" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: s.code, weight: .regular)]).width
            var bar = AttributedString("│")
            bar.font = mono
            bar.foregroundColor = caretOn ? VS.caret : .clear
            bar.kern = -advance / 2
            // At the line's start there is nothing to borrow from; the editor
            // draws that caret itself (see VSEditor.lineView).
            let at = min(max(0, caret), line.count)
            if at > 0 {
                let chars = out.characters
                let index = chars.index(chars.startIndex, offsetBy: at)
                out[chars.index(before: index)..<index].kern = -advance / 2
                out.insert(bar, at: index)
            }
        }
        return out
    }
}

// MARK: - Settings and the empty editor

private struct VSSettings: View {
    let s: VSScale
    @ObservedObject private var model = ExternalSettingsModel.shared

    var body: some View {
        let items = model.items()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8 * s.z) {
                Text("Search settings").foregroundStyle(VS.icon)
                Spacer()
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(VS.icon)
            }
            .font(.system(size: s.ui))
            .padding(.horizontal, 8 * s.z).frame(height: 30 * s.z)
            .background(VS.input).overlay(Rectangle().stroke(VS.inputBorder, lineWidth: 1))
            .padding(.bottom, 12 * s.z)
            HStack(spacing: 22 * s.z) {
                Text("User").foregroundStyle(VS.bright)
                    .overlay(alignment: .bottom) { Rectangle().fill(VS.blue).frame(height: 1).offset(y: 6 * s.z) }
                Text("Workspace").foregroundStyle(VS.dim)
                Spacer()
            }
            .font(.system(size: s.ui))
            .padding(.bottom, 10 * s.z)
            Rectangle().fill(VS.border).frame(height: 1).padding(.bottom, 8 * s.z)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2 * s.z) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        row(item, on: i == model.selected)
                    }
                }
            }
            if !model.status.isEmpty {
                Text(model.status).font(.system(size: s.ui)).foregroundStyle(VS.dim).padding(.top, 8 * s.z)
            }
        }
        .padding(.horizontal, 24 * s.z).padding(.top, 12 * s.z)
        .frame(maxWidth: 880 * s.z, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VS.editor)
    }

    private func row(_ item: ExternalSettingsModel.Item, on: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6 * s.z) {
            (Text("Notes: ").foregroundStyle(VS.text) + Text(item.title).bold().foregroundStyle(VS.bright))
                .font(.system(size: s.ui))
            if !item.value.isEmpty {
                HStack {
                    Text(item.value)
                    Spacer(minLength: 12 * s.z)
                    Image(systemName: "chevron.down").font(.system(size: s.small * 0.8))
                }
                .font(.system(size: s.ui))
                .padding(.horizontal, 8 * s.z).frame(width: 300 * s.z, height: 26 * s.z)
                .background(VS.input).overlay(Rectangle().stroke(on ? VS.blue : VS.inputBorder, lineWidth: 1))
            }
        }
        .padding(.vertical, 10 * s.z).padding(.horizontal, 14 * s.z)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? VS.hover : Color.clear)
        .overlay(alignment: .leading) { if on { Rectangle().fill(VS.blue).frame(width: 2 * s.z) } }
        .lineLimit(1)
    }
}

/// An editor with nothing open: the faded logo and the keys VS Code lists.
private struct VSWatermark: View {
    let s: VSScale

    private let rows: [(String, [String])] = [
        ("Show All Commands", ["Ctrl", "Shift", "P"]),
        ("Go to File", ["Ctrl", "P"]),
        ("Find in Files", ["Ctrl", "Shift", "F"]),
        ("Toggle Full Screen", ["F11"]),
        ("Show Settings", ["Ctrl", ","]),
    ]

    var body: some View {
        VStack(spacing: 28 * s.z) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 150 * s.z, weight: .bold)).foregroundStyle(VS.hex(0xFFFFFF, 0.05))
            Grid(alignment: .leading, horizontalSpacing: 12 * s.z, verticalSpacing: 10 * s.z) {
                ForEach(rows, id: \.0) { label, keys in
                    GridRow {
                        Text(label).foregroundStyle(VS.hex(0xFFFFFF, 0.45)).gridColumnAlignment(.trailing)
                        HStack(spacing: 4 * s.z) {
                            ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                                if i > 0 { Text("+").foregroundStyle(VS.hex(0xFFFFFF, 0.35)) }
                                Text(key).foregroundStyle(VS.hex(0xFFFFFF, 0.5))
                                    .padding(.horizontal, 5 * s.z).padding(.vertical, 2 * s.z)
                                    .background(VS.hex(0x808080, 0.17), in: RoundedRectangle(cornerRadius: 3 * s.z))
                            }
                        }
                    }
                }
            }
            .font(.system(size: s.ui))
        }
    }
}

#endif
