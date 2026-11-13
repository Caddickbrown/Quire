//
//  WritingTextEditor.swift
//  Quire
//
//  A thin wrapper over NSTextView / UITextView so we can control what SwiftUI's
//  TextEditor won't: zero text insets (so an overlaid placeholder lands exactly
//  on the caret) and a hidden scroll indicator.
//
//  Pass `sizeToFit` and the editor stops scrolling and reports the height its
//  text needs through SwiftUI's own sizing pass, so it can live inside somebody
//  else's scroll — the Stream edits entries in place that way. The height is
//  measured, never published into state: writing a measurement back would
//  re-lay-out the view, which re-measures it, and the row shakes.
//
//  Writing-surface extras (all optional, chosen in Settings):
//  * `typewriter`      — keeps the caret's line vertically centred as you type.
//  * `focusParagraph`  — dims everything but the paragraph you're in.
//  * live styling      — `_italic_`, `*italic*`, `**bold**` and `` `code` `` render in
//                        place while editing; the markers stay in the text.
//  * list continuation — ↩ inside a `- `, `1. ` or `- [ ] ` line continues the
//                        list; ↩ on an empty item ends it.
//  * ⌘B / ⌘I          — wrap the selection in `**` / `_` (via the Format menu
//                        notifications, so the shortcut reaches whichever
//                        editor is focused).
//
//  `mirror` turns the same view into a read-only copy for the external display:
//  the monitor renders the editor's text through this very styling code (so
//  `_italic_`, `**bold**`, `` `code` `` and `@tags` look exactly as they do on
//  the phone, and can't drift), draws a caret of its own at `mirrorCaret`, and
//  scrolls to keep it in view. `onCaretChange` is the other half: the live
//  editor reports where its caret is so the mirror can follow it.
//

import SwiftUI

private let tagRegex = try! NSRegularExpression(pattern: #"@[a-zA-Z][a-zA-Z0-9_-]*"#)
/// `_text_` or `__text__` → italicised while editing. The backreference makes
/// the closing run of underscores match the opening.
private let emphasisRegex = try! NSRegularExpression(pattern: #"(_{1,2})(.+?)\1"#)
/// `*text*` → italicised too, as markdown (and the reader) has it. Not `**`,
/// which is bold, and not a `* ` list bullet or a lone `a * b`.
private let starEmphasisRegex = try! NSRegularExpression(pattern: #"(?<![*\w])\*(?![\s*])(.+?)(?<![\s*])\*(?![*\w])"#)
/// Both kinds of emphasis, in `text`'s own ranges.
private func emphasisMatches(in text: String, range: NSRange) -> [NSTextCheckingResult] {
    emphasisRegex.matches(in: text, range: range) + starEmphasisRegex.matches(in: text, range: range)
}
/// `**text**` → bold while editing.
private let boldRegex = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
/// `` `text` `` → monospaced while editing.
private let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)

extension Notification.Name {
    /// Posted by the Format menu (⌘B / ⌘I); handled by whichever editor is
    /// first responder. A notification rather than a focused-value plumbing
    /// job: the composer, the entry editor and the Stream's in-place editor
    /// all host this view, and the responder check picks the right one.
    static let quireFormatBold   = Notification.Name("com.caddickbrown.quire.formatBold")
    static let quireFormatItalic = Notification.Name("com.caddickbrown.quire.formatItalic")
}

// List-continuation rules live in Models/ListContinuation.swift (pure, so
// `make check` and QuireTests exercise them); both coordinators below call it.

/// The `@token` the caret sits in (or right after): its UTF-16 range including
/// the `@`, and the partial name typed so far. Nil when the caret isn't in one.
/// Drives tag autocompletion on both platforms.
/// "@" as a UTF-16 unit, for NSString.character(at:) comparisons.
let quireAtSign: unichar = 64

func quireTagToken(in text: String, caret: Int) -> (range: NSRange, partial: String)? {
    quireTagToken(in: text as NSString, caret: caret)
}

/// The same on a string the caller already holds as an NSString (a text
/// view's storage), so asking on every keystroke copies nothing.
func quireTagToken(in ns: NSString, caret: Int) -> (range: NSRange, partial: String)? {
    guard caret > 0, caret <= ns.length else { return nil }
    func isTagChar(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
            || c == 45 /* - */ || c == 95 /* _ */
    }
    var i = caret - 1
    while i >= 0, isTagChar(ns.character(at: i)) { i -= 1 }
    guard i >= 0, ns.character(at: i) == quireAtSign else { return nil }
    // The @ must start a token, not sit mid-word (an email address, say).
    if i > 0 {
        let before = ns.character(at: i - 1)
        if isTagChar(before) || before == quireAtSign { return nil }
    }
    let partial = ns.substring(with: NSRange(location: i + 1, length: caret - (i + 1)))
    return (NSRange(location: i, length: caret - i), partial)
}

#if os(macOS)
import AppKit

private func platformFont(_ raw: String, _ size: CGFloat) -> NSFont {
    switch WritingFont(rawValue: raw) ?? .lato {
    case .lato:   return NSFont(name: "Lato-Regular", size: size) ?? .systemFont(ofSize: size)
    case .system: return .systemFont(ofSize: size)
    case .serif:  return designed(size, .serif)
    case .mono:   return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
/// The font's italic face, or a slant where it has none.
private func macItalic(_ font: NSFont) -> [NSAttributedString.Key: Any] {
    let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    if NSFontManager.shared.traits(of: italic).contains(.italicFontMask) { return [.font: italic] }
    return [.obliqueness: 0.2]
}
private func designed(_ size: CGFloat, _ design: NSFontDescriptor.SystemDesign) -> NSFont {
    let base = NSFont.systemFont(ofSize: size)
    if let d = base.fontDescriptor.withDesign(design) { return NSFont(descriptor: d, size: size) ?? base }
    return base
}

struct WritingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontRaw: String
    var size: CGFloat
    var textColor: Color
    var lineSpacing: CGFloat
    var highlightTags: Bool = true
    var accent: Color = AccentTheme.blue.color
    /// Embedded mode: don't scroll, just be as tall as the text needs.
    var sizeToFit = false
    /// Keep the caret's line vertically centred (composer-style scrolling).
    var typewriter = false
    /// Dim everything but the paragraph the caret is in.
    var focusParagraph = false
    /// Known tag names (no @), frequency-ordered — offered while typing @….
    var tagSuggestions: [String] = []
    /// Where the caret is (a UTF-16 offset, at the end of any selection),
    /// reported on every move; nil once the editor gives up keyboard focus.
    /// The composer forwards it to the external display.
    var onCaretChange: ((Int?) -> Void)? = nil
    /// A paste that's media (an image, a copied photo or video file) goes here
    /// to be attached instead of typed; nil pastes everything as text.
    var onPasteMedia: ((PastedMedia) -> Void)? = nil
    /// Mirror mode (the external display): read-only, no Dynamic Type scaling
    /// (the monitor's type is sized off the panel, not the phone's text
    /// setting), with a caret of its own drawn at `mirrorCaret` and kept in
    /// view as the text grows.
    var mirror = false
    var mirrorCaret: Int? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than with `scrollableTextView()` so the text
        // view can be the one that hears a media paste.
        let scroll = NSScrollView()
        let tv0 = PastingTextView(frame: .zero)
        tv0.minSize = .zero
        tv0.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv0.isVerticallyResizable = true
        tv0.isHorizontallyResizable = false
        tv0.autoresizingMask = [.width]
        tv0.textContainer?.widthTracksTextView = true
        tv0.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv0
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = sizeToFit ? .none : .automatic
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        if mirror {
            // The external display is iOS-only; this keeps the shared call
            // site compiling. Read-only, no caret of its own.
            tv.isEditable = false
            tv.isSelectable = false
        }
        context.coordinator.textView = tv
        apply(to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.textView = tv
        // Restyle only when something actually changed: on the per-keystroke
        // update the coordinator has already restyled the edited paragraph, and
        // re-attributing the whole document here made every keystroke O(entry).
        let signature = styleSignature
        if tv.string != text {
            tv.string = text
            // A wholesale swap (a different entry loaded, a template inserted,
            // a sync landing) leaves the undo stack holding ranges into text
            // that no longer exists, so ⌘Z would splice them into the new
            // document. Nothing here is worth undoing across that boundary.
            tv.undoManager?.removeAllActions()
            apply(to: tv)
            context.coordinator.lastStyleSignature = signature
        } else if context.coordinator.lastStyleSignature != signature {
            apply(to: tv)
            context.coordinator.lastStyleSignature = signature
        }
        // Room under the last line so the caret can stay centred at the end.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets.bottom = (typewriter && !sizeToFit)
            ? scroll.contentView.bounds.height * 0.5 : 0
        // Caret-only moves shift the focus dim / typewriter centre; edits
        // restyle just their own paragraph (focus mode restyles fully — its
        // dim spans the document).
        context.coordinator.reapply = { [self] in apply(to: tv) }
        context.coordinator.restyleParagraph = focusParagraph
            ? { [self] _ in apply(to: tv) }
            : { [self] range in styleParagraph(tv, around: range) }
        context.coordinator.recenter = (typewriter && !sizeToFit) ? { Self.centerCaret(tv) } : nil
        context.coordinator.focusParagraph = focusParagraph
        context.coordinator.tagSuggestions = tagSuggestions
        context.coordinator.onCaretChange = onCaretChange
        (tv as? PastingTextView)?.pasteMedia = onPasteMedia
    }

    /// Everything that changes how text is styled, so unchanged updates skip
    /// the full re-attribute.
    private var styleSignature: String {
        "\(fontRaw)|\(size)|\(lineSpacing)|\(highlightTags)|\(focusParagraph)|\(textColor)|\(accent)"
    }

    /// Re-attribute just the paragraph(s) covering `range` — the per-keystroke
    /// path. Every styling regex is line-bound, so a paragraph is a safe unit.
    private func styleParagraph(_ tv: NSTextView, around range: NSRange?) {
        let ns = tv.string as NSString
        guard let range else { apply(to: tv); return }
        let clamped = NSRange(location: min(range.location, ns.length),
                              length: min(range.length, ns.length - min(range.location, ns.length)))
        let target = ns.paragraphRange(for: clamped)
        let font = platformFont(fontRaw, size)
        let color = NSColor(textColor)
        let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing
        tv.textStorage?.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para], range: target)
        let sub = ns.substring(with: target)
        let subRange = NSRange(location: 0, length: (sub as NSString).length)
        func shifted(_ r: NSRange) -> NSRange { NSRange(location: r.location + target.location, length: r.length) }
        if highlightTags {
            let tagColor = NSColor(accent)
            for m in tagRegex.matches(in: sub, range: subRange) {
                tv.textStorage?.addAttribute(.foregroundColor, value: tagColor, range: shifted(m.range))
            }
        }
        let italic = macItalic(font)
        for m in emphasisMatches(in: sub, range: subRange) {
            tv.textStorage?.addAttributes(italic, range: shifted(m.range))
        }
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for m in boldRegex.matches(in: sub, range: subRange) {
            tv.textStorage?.addAttribute(.font, value: bold, range: shifted(m.range))
        }
        let mono = NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
        for m in codeRegex.matches(in: sub, range: subRange) {
            tv.textStorage?.addAttribute(.font, value: mono, range: shifted(m.range))
        }
    }

    private func apply(to tv: NSTextView) {
        let font = platformFont(fontRaw, size)
        let color = NSColor(textColor)
        let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing
        tv.font = font
        tv.textColor = color
        tv.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let ns = tv.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        tv.textStorage?.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para], range: full)
        if highlightTags {
            let tagColor = NSColor(accent)
            for m in tagRegex.matches(in: tv.string, range: full) {
                tv.textStorage?.addAttribute(.foregroundColor, value: tagColor, range: m.range)
            }
        }
        let italic = macItalic(font)
        for m in emphasisMatches(in: tv.string, range: full) {
            tv.textStorage?.addAttributes(italic, range: m.range)
        }
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for m in boldRegex.matches(in: tv.string, range: full) {
            tv.textStorage?.addAttribute(.font, value: bold, range: m.range)
        }
        let mono = NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
        for m in codeRegex.matches(in: tv.string, range: full) {
            tv.textStorage?.addAttribute(.font, value: mono, range: m.range)
        }
        if focusParagraph, ns.length > 0 {
            let sel = tv.selectedRange()
            let paragraph = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
            let dimmed = color.withAlphaComponent(0.35)
            if paragraph.location > 0 {
                tv.textStorage?.addAttribute(.foregroundColor, value: dimmed,
                                             range: NSRange(location: 0, length: paragraph.location))
            }
            let after = paragraph.location + paragraph.length
            if after < ns.length {
                tv.textStorage?.addAttribute(.foregroundColor, value: dimmed,
                                             range: NSRange(location: after, length: ns.length - after))
            }
        }
    }

    /// Scroll so the caret's line sits mid-viewport.
    fileprivate static func centerCaret(_ tv: NSTextView) {
        guard let scroll = tv.enclosingScrollView,
              let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString
        guard ns.length > 0 else { return }
        lm.ensureLayout(for: tc)
        let loc = min(tv.selectedRange().location, ns.length - 1)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: max(loc, 0), length: 1), in: tc)
        let target = max(0, rect.midY - scroll.contentView.bounds.height / 2)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Answer SwiftUI's sizing question directly rather than measuring the live
    /// view: the text view's own layout depends on the frame we're being asked
    /// to choose, so reading it here would chase its own tail.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard sizeToFit, let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: measuredHeight(width: width))
    }

    /// Height of `text` wrapped at `width`, plus a blank line's slack — enough
    /// room for the line you're about to start, and never a clipped last line.
    private func measuredHeight(width: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing
        let attributed = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [.font: platformFont(fontRaw, size), .paragraphStyle: para])
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height) + size + lineSpacing
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        /// Re-applies styling with current settings (the focus dim tracks the caret).
        var reapply: (() -> Void)?
        /// Paragraph-scoped restyle for the just-edited range (nil = full).
        var restyleParagraph: ((NSRange?) -> Void)?
        /// Typewriter centring; nil when the mode is off.
        var recenter: (() -> Void)?
        var focusParagraph = false
        /// Tag names for @-completion (no @, frequency-ordered).
        var tagSuggestions: [String] = []
        /// What the last full apply styled with — updateNSView's skip check.
        var lastStyleSignature = ""
        /// Caret reporting for the external display (see `onCaretChange`).
        var onCaretChange: ((Int?) -> Void)?
        /// The post-edit range of the in-flight user edit, recorded in
        /// shouldChangeText; nil for programmatic replacements (full restyle).
        private var pendingEditRange: NSRange?
        private var observers: [NSObjectProtocol] = []

        init(text: Binding<String>) {
            self.text = text
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .quireFormatBold, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrapSelection(marker: "**") }
            })
            observers.append(center.addObserver(forName: .quireFormatItalic, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrapSelection(marker: "_") }
            })
        }

        deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

        /// Record where the edit will land, so the restyle can stay
        /// paragraph-local. Falls through to every other decision unchanged.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            pendingEditRange = NSRange(location: affectedCharRange.location,
                                       length: ((replacementString ?? "") as NSString).length)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
            restyleParagraph?(pendingEditRange)   // nil (e.g. setString) = full
            pendingEditRange = nil
            recenter?()
            offerTagCompletion(tv)
        }

        /// Typing inside an @token pops the native completion list, but only
        /// while a known tag actually extends what's typed — never after an
        /// exact match, so accepting one doesn't re-open the list.
        private func offerTagCompletion(_ tv: NSTextView) {
            guard !tagSuggestions.isEmpty,
                  let token = quireTagToken(in: tv.string, caret: tv.selectedRange().location),
                  !token.partial.isEmpty else { return }
            let partial = token.partial.lowercased()
            let extendable = tagSuggestions.contains {
                $0.lowercased().hasPrefix(partial) && $0.lowercased() != partial
            }
            guard extendable else { return }
            DispatchQueue.main.async { [weak tv] in tv?.complete(nil) }
        }

        /// Feed the completion list: inside an @token, offer tag names that
        /// extend what AppKit considers the partial word (the text after @).
        func textView(_ textView: NSTextView, completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let ns = textView.string as NSString
            guard charRange.location > 0,
                  ns.character(at: charRange.location - 1) == quireAtSign else { return [] }
            let typed = ns.substring(with: charRange).lowercased()
            return tagSuggestions.filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if focusParagraph { reapply?() }   // the dimmed region follows the caret
            recenter?()
            reportCaret()
        }

        func textDidBeginEditing(_ notification: Notification) { reportCaret() }
        func textDidEndEditing(_ notification: Notification) { onCaretChange?(nil) }

        private func reportCaret() {
            guard let onCaretChange, let tv = textView else { return }
            onCaretChange(tv.window?.firstResponder === tv ? NSMaxRange(tv.selectedRange()) : nil)
        }

        /// ↩ continues / ends a list; anything else falls through.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            guard sel.length == 0 else { return false }
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            var line = ns.substring(with: lineRange)
            // lineRange takes the terminator with it, and that isn't always a
            // lone "\n" — a pasted-in CRLF is one Character, so dropping the
            // last Character strips the pair.
            while let last = line.last, last.isNewline { line.removeLast() }
            // Only when the caret sits at the end of the line's content.
            let contentEnd = lineRange.location + (line as NSString).length
            guard sel.location == contentEnd else { return false }
            switch ListContinuation.action(for: line) {
            case .none:
                return false
            case .continueList(let prefix):
                textView.insertText("\n" + prefix, replacementRange: sel)
                return true
            case .endList(let prefixLength):
                let prefixRange = NSRange(location: lineRange.location, length: prefixLength)
                if textView.shouldChangeText(in: prefixRange, replacementString: "") {
                    textView.textStorage?.replaceCharacters(in: prefixRange, with: "")
                    textView.didChangeText()
                }
                return true
            }
        }

        /// ⌘B/⌘I: wrap the selection in `marker` (or insert an empty pair).
        private func wrapSelection(marker: String) {
            guard let tv = textView, tv.window?.firstResponder === tv else { return }
            let sel = tv.selectedRange()
            let markerLen = (marker as NSString).length
            let ns = tv.string as NSString
            let selected = sel.length > 0 ? ns.substring(with: sel) : ""
            let replacement = marker + selected + marker
            guard tv.shouldChangeText(in: sel, replacementString: replacement) else { return }
            tv.textStorage?.replaceCharacters(in: sel, with: replacement)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: sel.location + markerLen, length: sel.length))
        }
    }
}

/// The editor's text view: a paste of media hands it to `pasteMedia` to be
/// attached; anything else pastes as usual.
final class PastingTextView: NSTextView {
    var pasteMedia: ((PastedMedia) -> Void)?

    override func paste(_ sender: Any?) {
        if let pasteMedia, let media = Attach.pasteboardMedia() { pasteMedia(media); return }
        super.paste(sender)
    }
}

#elseif os(iOS)
import UIKit
import Combine
import os
/// The editor's own notes (Console, subsystem com.caddickbrown.quire): only
/// when the first line had dropped and was laid out again.
private let editorLog = Logger(subsystem: "com.caddickbrown.quire", category: "editor")

private func platformFont(_ raw: String, _ size: CGFloat, scaled: Bool = true) -> UIFont {
    let base: UIFont
    if let custom = UIFont(name: raw, size: size) {
        base = custom
    } else {
        switch WritingFont(rawValue: raw) ?? .lato {
        case .lato:   base = UIFont(name: "Lato-Regular", size: size) ?? .systemFont(ofSize: size)
        case .system: base = .systemFont(ofSize: size)
        case .serif:  base = designed(size, .serif)
        case .mono:   base = .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
    // Track Dynamic Type: the px preference is the base size; the system's
    // text-size setting scales it, so accessibility sizes reach the editor too
    // (SwiftUI's Font.custom already scales everywhere else). Not for the
    // external-display mirror, whose size is already set off the monitor.
    guard scaled else { return base }
    return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
}
/// The font's italic face (Newsreader and Lato have one), or the same face
/// slanted by its matrix where there is none (Archivo). Not `.obliqueness`:
/// the TextKit 2 text views iOS builds draw that attribute upright, which is
/// why italics never showed in the editor or on the monitor.
private func italicFont(_ font: UIFont) -> UIFont {
    let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
    if let d = font.fontDescriptor.withSymbolicTraits(traits) {
        let italic = UIFont(descriptor: d, size: font.pointSize)
        if italic.fontDescriptor.symbolicTraits.contains(.traitItalic) { return italic }
    }
    let slant = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
    return UIFont(descriptor: font.fontDescriptor.withMatrix(slant), size: font.pointSize)
}
private func designed(_ size: CGFloat, _ design: UIFontDescriptor.SystemDesign) -> UIFont {
    let base = UIFont.systemFont(ofSize: size)
    if let d = base.fontDescriptor.withDesign(design) { return UIFont(descriptor: d, size: size) }
    return base
}

/// What the editor styles with, worked out when a setting changes rather than
/// on every key: the fonts are the same objects from one keystroke to the next.
fileprivate struct EditorStyle {
    let font: UIFont
    let italic: UIFont
    let bold: UIFont
    let mono: UIFont
    let color: UIColor
    let accent: UIColor
    let lineSpacing: CGFloat
    let highlightTags: Bool
    let focusParagraph: Bool
    /// What unstyled text carries: the body font, its colour and the line spacing.
    let base: [NSAttributedString.Key: Any]
}

/// A paragraph as it was measured: its words and the fonts across them.
fileprivate struct ParagraphKey: Hashable {
    let text: String
    let fonts: Int
}

/// A handle on the live editor for edits that don't come from the keyboard:
/// an attachment's link, a prompt, a transcript. They go in as one ranged,
/// undoable edit, so the caret and the undo stack survive; assigning the whole
/// text instead resets the view, which sends the caret to the end.
final class WritingEditorProxy {
    fileprivate weak var coordinator: WritingTextEditor.Coordinator?

    /// Replace `range` (UTF-16) of a text `length` units long with `string`.
    /// `moveCaret` puts the caret after what went in; otherwise the selection
    /// stays on the words it was on. False when there is no live editor or it
    /// holds something else: the caller assigns the text as before.
    func replace(_ range: NSRange, with string: String, in length: Int, moveCaret: Bool) -> Bool {
        coordinator?.replace(range, with: string, in: length, moveCaret: moveCaret) ?? false
    }
}

struct WritingTextEditor: UIViewRepresentable {
    @Binding var text: String
    var fontRaw: String
    var size: CGFloat
    var textColor: Color
    var lineSpacing: CGFloat
    var highlightTags: Bool = true
    var accent: Color = AccentTheme.blue.color
    /// Embedded mode: don't scroll, just be as tall as the text needs.
    var sizeToFit = false
    /// Keep the caret's line vertically centred (composer-style scrolling).
    var typewriter = false
    /// Dim everything but the paragraph the caret is in.
    var focusParagraph = false
    /// Known tag names (no @), frequency-ordered — offered while typing @….
    var tagSuggestions: [String] = []
    /// Where the caret is (a UTF-16 offset, at the end of any selection),
    /// reported on every move; nil once the editor gives up keyboard focus.
    /// The composer forwards it to the external display.
    var onCaretChange: ((Int?) -> Void)? = nil
    /// A paste that's media (an image, a copied photo or video file) goes here
    /// to be attached instead of typed; nil pastes everything as text.
    var onPasteMedia: ((PastedMedia) -> Void)? = nil
    /// Mirror mode (the external display): read-only, no Dynamic Type scaling
    /// (the monitor's type is sized off the panel, not the phone's text
    /// setting), with a caret of its own drawn at `mirrorCaret` and kept in
    /// view as the text grows.
    var mirror = false
    var mirrorCaret: Int? = nil
    /// Where the keyboard should be. UIKit's first responder is the truth: the
    /// view reports it here, and a change of this value asks for it once (see
    /// `Coordinator.request`). Never pair it with SwiftUI's `.focused()`.
    var focused: Binding<Bool>? = nil
    /// Embedded mode: never shorter than this, however little is written. The
    /// text view itself then covers the page, so a tap below the words is a
    /// tap in the text view and UIKit puts the caret after the last one.
    var minHeight: CGFloat = 0
    /// For ranged edits from outside (see `WritingEditorProxy`).
    var proxy: WritingEditorProxy? = nil
    /// For UI tests to find the view by; nothing reads it otherwise.
    var identifier: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let tv: UITextView = mirror ? MirrorTextView() : PastingTextView()
        let coordinator = context.coordinator
        tv.delegate = coordinator
        tv.accessibilityIdentifier = identifier
        tv.backgroundColor = .clear
        tv.showsVerticalScrollIndicator = false
        tv.showsHorizontalScrollIndicator = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = !sizeToFit
        if mirror {
            // The phone's ↑/↓ follow this view's lines (see PastingTextView).
            ExternalDisplayModel.shared.bodyLayout = { [weak tv] text in
                guard let tv, tv.text == text else { return nil }
                return tv
            }
            // Nobody can touch the monitor; the view scrolls itself to the
            // caret instead. Selectable stays on — the caret geometry comes
            // from the text-input machinery, which a non-selectable view
            // doesn't keep up.
            tv.isEditable = false
            tv.isUserInteractionEnabled = false
        }
        coordinator.textView = tv
        coordinator.isMirror = mirror
        coordinator.style = makeStyle()
        coordinator.lastStyleSignature = styleSignature(tv)
        // Styling happens inside the storage's own editing (see
        // `Coordinator.textStorage(_:willProcessEditing:…)`).
        tv.textStorage.delegate = coordinator
        (tv as? PastingTextView)?.onWindow = { [weak coordinator] in coordinator?.attached() }
        proxy?.coordinator = coordinator
        coordinator.restyleAll(tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.textView = tv
        coordinator.focused = focused
        proxy?.coordinator = coordinator
        let signature = styleSignature(tv)
        let restyle = coordinator.lastStyleSignature != signature
        if restyle {
            coordinator.style = makeStyle()
            coordinator.lastStyleSignature = signature
        }
        if mirror { updateMirror(tv, context: context, restyle: restyle); return }
        if tv.isScrollEnabled == sizeToFit { tv.isScrollEnabled = !sizeToFit }
        // On a keystroke the view already holds this text and the edited
        // paragraph was styled as it went in: nothing to do. The check is on
        // the storage's own string, length first, so it copies nothing; the
        // slower comparison only runs when that one says they differ.
        if !coordinator.holds(text), tv.text != text {
            // A different entry, a template, a sync landing. The swap is styled
            // whole just below, so the per-edit pass stands aside for it.
            coordinator.swapping = true
            tv.text = text
            coordinator.swapping = false
            // Same reason as the macOS side: a wholesale swap invalidates every
            // range the undo stack is holding, so drop it rather than let a
            // shake-to-undo paste the old entry's edits into the new one.
            tv.undoManager?.removeAllActions()
            coordinator.restyleAll(tv)
        } else if restyle {
            coordinator.restyleAll(tv)
        }
        // Room under the last line so the caret can stay centred at the end.
        let inset = (typewriter && !sizeToFit) ? tv.bounds.height * 0.5 : 0
        if tv.contentInset.bottom != inset { tv.contentInset.bottom = inset }
        coordinator.recenter = (typewriter && !sizeToFit) ? { [weak tv] in if let tv { Self.centerCaret(tv) } } : nil
        coordinator.tagSuggestions = tagSuggestions
        coordinator.onCaretChange = onCaretChange
        (tv as? PastingTextView)?.pasteMedia = onPasteMedia
        // Never first responder from in here: the coordinator asks for it on
        // the next turn, and only when what's asked for has changed.
        coordinator.request(focus: focused?.wrappedValue, on: tv)
    }

    /// The mirror's update: merge the new text in as one edit, restyle what
    /// changed, and hand the caret to the view. No typewriter, focus dim or
    /// tag bar — none of them mean anything on a screen nobody types into.
    private func updateMirror(_ tv: UITextView, context: Context, restyle: Bool) {
        if !context.coordinator.holds(text), tv.text != text {
            mergeMirrorText(tv, text)
            (tv as? MirrorTextView)?.noteTextChanged()
        }
        if restyle { context.coordinator.restyleAll(tv) }
        // Room under the last line, so the caret can sit mid-screen at the end
        // of the text instead of the newest words hugging the bottom edge.
        let inset = tv.bounds.height * 0.45
        if tv.contentInset.bottom != inset { tv.contentInset.bottom = inset }
        if let m = tv as? MirrorTextView {
            m.caretColor = UIColor(accent)
            m.caretIndex = mirrorCaret
        }
    }

    /// Apply the new text as a single edit — the common prefix and suffix stay
    /// put, so a keystroke restyles only its own paragraph and the scroll
    /// position holds. Assigning `tv.text` wholesale re-laid-out everything
    /// and threw the offset away, which is what kept the monitor pinned to the
    /// top or the bottom rather than to the caret. The edit is styled by the
    /// storage's delegate, in the same pass as the characters.
    private func mergeMirrorText(_ tv: UITextView, _ new: String) {
        let old = tv.textStorage.mutableString
        let incoming = new as NSString
        let shortest = min(old.length, incoming.length)
        var prefix = 0
        while prefix < shortest, old.character(at: prefix) == incoming.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix,
              old.character(at: old.length - 1 - suffix) == incoming.character(at: incoming.length - 1 - suffix) {
            suffix += 1
        }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = incoming.substring(with: NSRange(location: prefix, length: incoming.length - prefix - suffix))
        tv.textStorage.replaceCharacters(in: range, with: replacement)
    }

    /// Everything that changes how text is styled, so unchanged updates skip
    /// the full re-attribute. The text size setting is in it: the body font is
    /// scaled by it.
    private func styleSignature(_ tv: UITextView) -> String {
        "\(fontRaw)|\(size)|\(lineSpacing)|\(highlightTags)|\(focusParagraph)|\(textColor)|\(accent)|\(mirror)|\(tv.traitCollection.preferredContentSizeCategory.rawValue)"
    }

    private func makeStyle() -> EditorStyle {
        let font = platformFont(fontRaw, size, scaled: !mirror)
        let color = UIColor(textColor)
        let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing
        // Derived from the (Dynamic Type-scaled) body font, not the raw px size.
        let boldDescriptor = font.fontDescriptor.withSymbolicTraits(.traitBold)
        return EditorStyle(
            font: font,
            italic: italicFont(font),
            bold: boldDescriptor.map { UIFont(descriptor: $0, size: font.pointSize) } ?? font,
            mono: .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular),
            color: color,
            accent: UIColor(accent),
            lineSpacing: lineSpacing,
            highlightTags: highlightTags,
            focusParagraph: focusParagraph,
            base: [.font: font, .foregroundColor: color,
                   .paragraphStyle: (para.copy() as? NSParagraphStyle) ?? para])
    }

    /// Scroll so the caret sits mid-viewport.
    fileprivate static func centerCaret(_ tv: UITextView) {
        guard let sel = tv.selectedTextRange else { return }
        let caret = tv.caretRect(for: sel.end)
        guard caret.origin.y.isFinite, tv.bounds.height > 0 else { return }
        let target = caret.midY - tv.bounds.height / 2
        let minY = -tv.adjustedContentInset.top
        let maxY = max(minY, tv.contentSize.height + tv.contentInset.bottom - tv.bounds.height)
        tv.setContentOffset(CGPoint(x: 0, y: min(max(target, minY), maxY)), animated: false)
    }

    /// Answer SwiftUI's sizing question directly rather than measuring the live
    /// view: the text view's own layout depends on the frame we're being asked
    /// to choose, so reading it here would chase its own tail — which on iOS
    /// showed up as the row jittering with every keystroke.
    ///
    /// SwiftUI asks more than once per keystroke (twice, counted on an iPad), and
    /// again whenever the page around it redraws with the text unchanged, so the
    /// answer is kept for the text, width and type it was measured for. When it
    /// does have to be worked out, only the paragraphs that changed are typeset.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard sizeToFit, let width = proposal.width, width > 0, width.isFinite else { return nil }
        let coordinator = context.coordinator
        let key = "\(fontRaw)|\(size)|\(lineSpacing)|\(mirror)|\(uiView.traitCollection.preferredContentSizeCategory.rawValue)"
        if let cache = coordinator.measured, cache.width == width, cache.key == key, cache.text == text {
            return CGSize(width: width, height: max(cache.height, minHeight))
        }
        // From the view's own styled text, so bold, code and italic runs wrap
        // as they are drawn. If the view doesn't hold this text yet, the plain
        // measure stands in, and isn't kept.
        if let height = coordinator.measuredHeight(of: uiView, holding: text, width: width, key: key) {
            coordinator.measured = (text, width, key, height)
            return CGSize(width: width, height: max(height, minHeight))
        }
        return CGSize(width: width, height: max(plainHeight(width: width), minHeight))
    }

    /// Height of `text` in the body font alone, wrapped at `width`, plus a
    /// blank line's slack. Only for a view that doesn't hold the text yet.
    private func plainHeight(width: CGFloat) -> CGFloat {
        let font = platformFont(fontRaw, size, scaled: !mirror)
        let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing
        let attributed = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [.font: font, .paragraphStyle: para])
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        return ceil(bounds.height) + ceil(font.lineHeight) + lineSpacing
    }

    final class Coordinator: NSObject, UITextViewDelegate, NSTextStorageDelegate {
        var focused: Binding<Bool>?
        var text: Binding<String>
        weak var textView: UITextView?
        /// What to style with; set by the view before anything is styled.
        fileprivate var style: EditorStyle?
        var isMirror = false
        /// Typewriter centring; nil when the mode is off.
        var recenter: (() -> Void)?
        /// Tag names for the @-completion bar (no @, frequency-ordered).
        var tagSuggestions: [String] = []
        /// What the style was built from — updateUIView's skip check.
        var lastStyleSignature = ""
        /// The last height `sizeThatFits` measured, and what it measured.
        var measured: (text: String, width: CGFloat, key: String, height: CGFloat)?
        /// Caret reporting for the external display (see `onCaretChange`).
        var onCaretChange: ((Int?) -> Void)?
        /// Set around a wholesale `tv.text =`: the whole text is styled right
        /// after it, so the per-edit pass has nothing to add.
        var swapping = false
        /// Our own attribute pass is running; its edits are not edits to style.
        private var isStyling = false
        /// A restyle skipped while an input method was composing, owed once it ends.
        private var restyleOwed = false
        /// Counts `textViewDidChange`, so a programmatic edit can tell whether
        /// UIKit reported it or it must.
        private var changes = 0
        /// The focus last asked for or last reported by UIKit. A request is
        /// only acted on when it differs from this.
        private var lastFocus: Bool?
        /// A request made before the view had a window; kept for when it does.
        private var focusOwed = false
        /// Where an edit replaced or removed text: that paragraph's layout is
        /// thrown away and laid out again on the next turn (see `repairLayout`).
        private var repairAt: Int?
        private var repairScheduled = false
        /// Paragraph heights for one width and type (`heightsKey`).
        private var heights: [ParagraphKey: CGFloat] = [:]
        private var heightsKey = ""
        private var heightsWidth: CGFloat = 0
        private var blankHeight: CGFloat = 0
        private var lastTagBarKey = ""
        private var observers: [NSObjectProtocol] = []

        init(text: Binding<String>) {
            self.text = text
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .quireFormatBold, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrapSelection(marker: "**") }
            })
            observers.append(center.addObserver(forName: .quireFormatItalic, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrapSelection(marker: "_") }
            })
        }

        deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

        /// Whether the view already holds exactly `text`. Compared on the
        /// storage's own string, length first: no copy of either.
        func holds(_ text: String) -> Bool {
            guard let tv = textView else { return false }
            let ns = tv.textStorage.mutableString
            return ns.length == (text as NSString).length && ns.isEqual(to: text)
        }

        // MARK: Styling

        /// An edit to the characters is styled here, inside the storage's own
        /// editing pass, so the layout hears of the characters and their
        /// attributes together. Styling it afterwards from `textViewDidChange`,
        /// one attribute at a time, changed attributes under TextKit 2 while it
        /// was still settling the keyboard's own replacement ("..." into "…"),
        /// and the body sat a line low until the next key.
        ///
        /// `will`, not `did`: fonts change here, and changes made before the
        /// storage fixes its attributes are folded into the edit it reports.
        func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorage.EditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            // Attribute-only passes are our own (or UIKit's); nothing to style.
            guard editedMask.contains(.editedCharacters), !isStyling, !swapping, let style else { return }
            let tv = textView
            // An edit that replaced or removed something, not just added to it.
            if !isMirror { scheduleRepair(at: editedRange.length - delta > 0 ? editedRange.location : nil) }
            // An input method is composing: its marked text carries attributes
            // of its own, so the paragraph is left alone until it commits.
            if tv?.markedTextRange != nil { restyleOwed = true; return }
            isStyling = true
            Self.applyStyle(textStorage, paragraphsCovering: editedRange, with: style)
            isStyling = false
        }

        /// Attributes for the paragraph(s) covering `range`. Every styling
        /// regex is line-bound, so a paragraph is a safe unit. The caller has
        /// the storage in an editing pass.
        private static func applyStyle(_ storage: NSTextStorage, paragraphsCovering range: NSRange, with style: EditorStyle) {
            let ns = storage.mutableString
            let length = ns.length
            let location = min(max(range.location, 0), length)
            let target = ns.paragraphRange(for: NSRange(location: location, length: min(max(range.length, 0), length - location)))
            guard target.length > 0 else { return }
            storage.setAttributes(style.base, range: target)
            let sub = ns.substring(with: target)
            let subRange = NSRange(location: 0, length: target.length)
            func shifted(_ r: NSRange) -> NSRange { NSRange(location: r.location + target.location, length: r.length) }
            if style.highlightTags {
                for m in tagRegex.matches(in: sub, range: subRange) {
                    storage.addAttribute(.foregroundColor, value: style.accent, range: shifted(m.range))
                }
            }
            for m in emphasisMatches(in: sub, range: subRange) {
                storage.addAttribute(.font, value: style.italic, range: shifted(m.range))
            }
            for m in boldRegex.matches(in: sub, range: subRange) {
                storage.addAttribute(.font, value: style.bold, range: shifted(m.range))
            }
            for m in codeRegex.matches(in: sub, range: subRange) {
                storage.addAttribute(.font, value: style.mono, range: shifted(m.range))
            }
        }

        /// Style the whole text, as one editing pass: a new entry, a changed
        /// setting, or the focus dim following the caret. The view's own font
        /// and colour are only set while it is empty: on a view with text in
        /// it they re-attribute everything outside any pass.
        func restyleAll(_ tv: UITextView) {
            guard let style else { return }
            let storage = tv.textStorage
            if tv.markedTextRange != nil { restyleOwed = true; return }
            if storage.length == 0 {
                tv.font = style.font
                tv.textColor = style.color
            }
            tv.typingAttributes = style.base
            guard storage.length > 0 else { return }
            isStyling = true
            storage.beginEditing()
            Self.applyStyle(storage, paragraphsCovering: NSRange(location: 0, length: storage.length), with: style)
            if style.focusParagraph {
                let ns = storage.mutableString
                let sel = tv.selectedRange
                let paragraph = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
                let dimmed = style.color.withAlphaComponent(0.35)
                if paragraph.location > 0 {
                    storage.addAttribute(.foregroundColor, value: dimmed,
                                         range: NSRange(location: 0, length: paragraph.location))
                }
                let after = paragraph.location + paragraph.length
                if after < ns.length {
                    storage.addAttribute(.foregroundColor, value: dimmed,
                                         range: NSRange(location: after, length: ns.length - after))
                }
            }
            storage.endEditing()
            isStyling = false
            // The same words may now wrap differently.
            measured = nil
        }

        /// The paragraph the caret is in, as one editing pass: what was owed
        /// while an input method was composing.
        private func restyleCaretParagraph(_ tv: UITextView) {
            guard let style, tv.textStorage.length > 0 else { return }
            let storage = tv.textStorage
            isStyling = true
            storage.beginEditing()
            Self.applyStyle(storage, paragraphsCovering: tv.selectedRange, with: style)
            storage.endEditing()
            isStyling = false
            measured = nil
        }

        // MARK: Layout repair

        /// `location`: where an edit replaced or removed text. Nil for any
        /// other edit, which still gets the check for a dropped first line.
        private func scheduleRepair(at location: Int?) {
            if let location { repairAt = min(repairAt ?? location, location) }
            guard !repairScheduled else { return }
            repairScheduled = true
            // On the next turn: never from inside the storage's own callback.
            DispatchQueue.main.async { [weak self] in self?.repairLayout() }
        }

        /// TextKit 2 can keep a paragraph's old geometry after the keyboard
        /// swaps characters under it: Dan's editor log (9 Nov) had the view,
        /// offset, insets, font and line height all unchanged after "..." became
        /// "…" with a tag on the line below, and the first line laid out a line
        /// low until the next key. So, a turn after an edit:
        ///
        /// 1. Where text was replaced, that paragraph's layout is thrown away
        ///    and everything from the top down to it laid out again for real,
        ///    not from TextKit 2's estimates, then the viewport redrawn.
        /// 2. After any edit, the first line is checked: in this view it always
        ///    starts at the top. If it doesn't, the whole layout is thrown away
        ///    and redone. Reading the first fragment and the caret at the start
        ///    is cheap; the full relayout only runs when the text has dropped.
        ///
        /// `textLayoutManager` is nil on a view that fell back to TextKit 1,
        /// where none of this applies.
        private func repairLayout() {
            repairScheduled = false
            let at = repairAt
            repairAt = nil
            guard !isMirror, let tv = textView, tv.markedTextRange == nil, tv.window != nil,
                  let layout = tv.textLayoutManager, let content = layout.textContentManager else { return }
            let viewport = layout.textViewportLayoutController
            if let at {
                let ns = tv.textStorage.mutableString
                let paragraph = ns.paragraphRange(for: NSRange(location: min(max(at, 0), ns.length), length: 0))
                let docStart = content.documentRange.location
                if paragraph.length > 0,
                   let start = content.location(docStart, offsetBy: paragraph.location),
                   let end = content.location(start, offsetBy: paragraph.length),
                   let range = NSTextRange(location: start, end: end),
                   let upTo = NSTextRange(location: docStart, end: end) {
                    layout.invalidateLayout(for: range)
                    layout.ensureLayout(for: upTo)
                    viewport.layoutViewport()
                }
            }
            // Half a line: the bug moves a whole one, and a caret's own top can
            // sit a point or two below the line's.
            let threshold = (style?.font.lineHeight ?? 16) * 0.5
            guard let dropped = Self.firstLineDrop(tv, layout), dropped > threshold else { return }
            layout.invalidateLayout(for: layout.documentRange)
            layout.ensureLayout(for: layout.documentRange)
            viewport.layoutViewport()
            tv.setNeedsDisplay()
            editorLog.notice("first line was \(Double(dropped)) pt low; laid out again: now \(Double(Self.firstLineDrop(tv, layout) ?? -1))")
        }

        /// How far below the top the first line sits: 0 unless the text has
        /// dropped. The first layout fragment's frame, or the caret at the start
        /// of the text, whichever is lower. Nil with nothing laid out.
        private static func firstLineDrop(_ tv: UITextView, _ layout: NSTextLayoutManager) -> CGFloat? {
            var y: CGFloat?
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
                y = fragment.layoutFragmentFrame.minY
                return false
            }
            guard tv.textStorage.length > 0 else { return y }
            let caret = tv.caretRect(for: tv.beginningOfDocument).minY - tv.textContainerInset.top
            guard caret.isFinite else { return y }
            return max(y ?? 0, caret)
        }

        // MARK: Measuring

        /// The height the view's own styled text needs at `width`, plus a blank
        /// line's slack — room for the line you're about to start, and never a
        /// clipped last line. Paragraph by paragraph, each kept for its words
        /// and fonts, so a keystroke typesets one paragraph, not the entry.
        /// Nil when the view doesn't hold `text`.
        func measuredHeight(of tv: UITextView, holding text: String, width: CGFloat, key: String) -> CGFloat? {
            guard let style, textView === tv, holds(text) else { return nil }
            let storage = tv.textStorage
            let ns = storage.mutableString
            if heightsKey != key || heightsWidth != width {
                heights.removeAll(keepingCapacity: true)
                heightsKey = key
                heightsWidth = width
                blankHeight = Self.height(of: NSAttributedString(string: " ", attributes: style.base), width: width)
            }
            // Only the paragraphs still in the text are kept.
            var kept: [ParagraphKey: CGFloat] = [:]
            kept.reserveCapacity(heights.count + 1)
            var total: CGFloat = 0
            var count = 0
            var location = 0
            let length = ns.length
            // An empty text is one blank line, and so is what follows a final ↩.
            var endsOpen = true
            while location < length {
                var start = 0, end = 0, contentsEnd = 0
                ns.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd,
                                     for: NSRange(location: location, length: 0))
                let content = NSRange(location: start, length: contentsEnd - start)
                if content.length == 0 {
                    total += blankHeight
                } else {
                    var hasher = Hasher()
                    storage.enumerateAttribute(.font, in: content, options: []) { value, range, _ in
                        hasher.combine(range.location - content.location)
                        hasher.combine(range.length)
                        hasher.combine((value as? NSObject)?.hash ?? 0)
                    }
                    let paragraph = ParagraphKey(text: ns.substring(with: content), fonts: hasher.finalize())
                    let height = heights[paragraph]
                        ?? Self.height(of: storage.attributedSubstring(from: content), width: width)
                    kept[paragraph] = height
                    total += height
                }
                count += 1
                endsOpen = end > contentsEnd
                guard end > location else { break }
                location = end
            }
            if endsOpen { total += blankHeight; count += 1 }
            heights = kept
            // Line spacing falls between lines; inside a paragraph it is in the
            // paragraph's own height already.
            total += CGFloat(max(0, count - 1)) * style.lineSpacing
            return ceil(total) + ceil(style.font.lineHeight) + style.lineSpacing
        }

        private static func height(of string: NSAttributedString, width: CGFloat) -> CGFloat {
            string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        }

        // MARK: Focus

        /// The host asked for the keyboard to be here (true) or not (false).
        /// Acted on only when that differs from what was last asked for or
        /// last reported by UIKit, and on the next turn, after SwiftUI's
        /// update. Asking again on every update is how two fields come to
        /// take the keyboard from each other in turn.
        func request(focus want: Bool?, on tv: UITextView) {
            guard let want, want != lastFocus else { return }
            lastFocus = want
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv, self.lastFocus == want else { return }
                self.applyFocus(tv)
            }
        }

        private func applyFocus(_ tv: UITextView) {
            guard let want = lastFocus else { return }
            // Not on screen yet: `attached` picks it up.
            guard tv.window != nil else { focusOwed = true; return }
            focusOwed = false
            if want, !tv.isFirstResponder {
                // Refused: forget the request, so the next change of anything asks again.
                if !tv.becomeFirstResponder() { lastFocus = nil }
            } else if !want, tv.isFirstResponder {
                tv.resignFirstResponder()
            }
        }

        /// The view joined a window with a request still owed.
        func attached() {
            guard focusOwed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusOwed, let tv = self.textView else { return }
                self.applyFocus(tv)
            }
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            changes &+= 1
            text.wrappedValue = textView.text
            if textView.markedTextRange == nil {
                if restyleOwed {
                    restyleOwed = false
                    if style?.focusParagraph == true { restyleAll(textView) } else { restyleCaretParagraph(textView) }
                } else if style?.focusParagraph == true {
                    restyleAll(textView)   // its dim spans the document
                }
                // An emptied view takes its type from here for what comes next.
                if textView.textStorage.length == 0, let style {
                    if textView.font != style.font { textView.font = style.font }
                    textView.typingAttributes = style.base
                }
            }
            recenter?()
            updateTagBar(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if style?.focusParagraph == true { restyleAll(textView) }   // the dimmed region follows the caret
            recenter?()
            updateTagBar(textView)
            reportCaret(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            // UIKit's word on it: recorded first, so the echo through the
            // binding is not taken for a new request.
            lastFocus = true
            focusOwed = false
            if let focused, !focused.wrappedValue { focused.wrappedValue = true }
            reportCaret(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            lastFocus = false
            focusOwed = false
            if let focused, focused.wrappedValue { focused.wrappedValue = false }
            guard let onCaretChange else { return }
            onCaretChange(nil)
            select(nil)
        }

        /// The end of the selection, or nil while the keyboard is elsewhere
        /// (the title field, say) — the monitor shouldn't blink a caret the
        /// phone isn't showing. The selection itself goes too, to be shaded.
        private func reportCaret(_ tv: UITextView) {
            guard let onCaretChange else { return }
            onCaretChange(tv.isFirstResponder ? NSMaxRange(tv.selectedRange) : nil)
            select(tv.isFirstResponder && tv.selectedRange.length > 0 ? tv.selectedRange : nil)
        }

        private func select(_ range: NSRange?) {
            let model = ExternalDisplayModel.shared
            if model.selection != range { model.selection = range }
        }

        // MARK: @-completion bar (keyboard accessory)

        /// While the caret sits in an @token with matching known tags, a chip
        /// bar rides above the keyboard; tapping a chip completes the tag.
        private func updateTagBar(_ tv: UITextView) {
            func clear() {
                guard tv.inputAccessoryView != nil else { return }
                lastTagBarKey = ""
                tv.inputAccessoryView = nil
                tv.reloadInputViews()
            }
            guard !tagSuggestions.isEmpty,
                  let token = quireTagToken(in: tv.textStorage.mutableString, caret: tv.selectedRange.location) else {
                clear(); return
            }
            let partial = token.partial.lowercased()
            let matches = tagSuggestions.filter {
                let name = $0.lowercased()
                return partial.isEmpty ? true : (name.hasPrefix(partial) && name != partial)
            }.prefix(8)
            guard !matches.isEmpty else { clear(); return }
            let key = matches.joined(separator: ",")
            guard key != lastTagBarKey || tv.inputAccessoryView == nil else { return }
            lastTagBarKey = key
            tv.inputAccessoryView = makeTagBar(tv, matches: Array(matches))
            tv.reloadInputViews()
        }

        private func makeTagBar(_ tv: UITextView, matches: [String]) -> UIView {
            let bar = UIScrollView(frame: CGRect(x: 0, y: 0, width: max(tv.bounds.width, 320), height: 40))
            bar.backgroundColor = .secondarySystemBackground
            bar.showsHorizontalScrollIndicator = false
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            for name in matches {
                var config = UIButton.Configuration.gray()
                config.title = "@\(name)"
                config.cornerStyle = .capsule
                config.buttonSize = .small
                let button = UIButton(configuration: config, primaryAction: UIAction { [weak self, weak tv] _ in
                    guard let self, let tv,
                          // Re-derive the token at tap time — the text may have
                          // moved under a bar built a keystroke ago.
                          let token = quireTagToken(in: tv.textStorage.mutableString, caret: tv.selectedRange.location)
                    else { return }
                    let replacement = "@\(name) "
                    self.mutate(tv, range: token.range, with: replacement,
                                selection: NSRange(location: token.range.location + (replacement as NSString).length, length: 0))
                })
                button.accessibilityLabel = "Complete tag \(name)"
                stack.addArrangedSubview(button)
            }
            bar.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: bar.contentLayoutGuide.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: bar.contentLayoutGuide.trailingAnchor, constant: -10),
                stack.centerYAnchor.constraint(equalTo: bar.frameLayoutGuide.centerYAnchor),
                stack.heightAnchor.constraint(equalToConstant: 32),
                bar.contentLayoutGuide.heightAnchor.constraint(equalTo: bar.frameLayoutGuide.heightAnchor),
            ])
            return bar
        }

        /// ↩ continues / ends a list; anything else falls through.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard replacement == "\n", range.length == 0 else { return true }
            let ns = textView.textStorage.mutableString
            guard range.location <= ns.length else { return true }
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var line = ns.substring(with: lineRange)
            // The terminator comes along with lineRange and isn't always a lone
            // "\n" — a pasted-in CRLF is one Character, so this strips the pair.
            while let last = line.last, last.isNewline { line.removeLast() }
            let contentEnd = lineRange.location + (line as NSString).length
            guard range.location == contentEnd else { return true }
            switch ListContinuation.action(for: line) {
            case .none:
                return true
            case .continueList(let prefix):
                mutate(textView, range: range, with: "\n" + prefix,
                       selection: NSRange(location: range.location + ("\n" + prefix).utf16.count, length: 0))
                return false
            case .endList(let prefixLength):
                let prefixRange = NSRange(location: lineRange.location, length: prefixLength)
                mutate(textView, range: prefixRange, with: "", selection: NSRange(location: lineRange.location, length: 0))
                return false
            }
        }

        /// Replace `range` with `s` through UITextInput's `replace`, which —
        /// unlike mutating textStorage directly — registers undo, matching the
        /// macOS shouldChangeText path. The storage's delegate styles it.
        ///
        /// Whether `replace` reports the change to the delegate itself is
        /// UIKit's business and has not been the same everywhere, so the
        /// change is reported here only if UIKit didn't: once, either way.
        private func mutate(_ tv: UITextView, range: NSRange, with s: String, selection: NSRange) {
            guard let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
                  let end = tv.position(from: start, offset: range.length),
                  let textRange = tv.textRange(from: start, to: end) else { return }
            let before = changes
            tv.replace(textRange, withText: s)
            let length = tv.textStorage.length
            let location = min(max(selection.location, 0), length)
            tv.selectedRange = NSRange(location: location, length: min(max(selection.length, 0), length - location))
            if changes == before { textViewDidChange(tv) }
        }

        /// A ranged edit from outside the keyboard (see `WritingEditorProxy`).
        fileprivate func replace(_ range: NSRange, with s: String, in length: Int, moveCaret: Bool) -> Bool {
            guard !isMirror, let tv = textView, tv.textStorage.length == length,
                  range.location >= 0, range.length >= 0, NSMaxRange(range) <= length else { return false }
            // An input method mid-word: what it has so far is kept as typed
            // rather than thrown away by an edit landing under it.
            if tv.markedTextRange != nil {
                tv.unmarkText()
                guard tv.textStorage.length == length else { return false }
            }
            let added = (s as NSString).length
            let selected = tv.selectedRange
            let selection: NSRange
            if moveCaret {
                selection = NSRange(location: range.location + added, length: 0)
            } else if selected.location >= NSMaxRange(range) {
                // After the edit: carried along with its words.
                selection = NSRange(location: selected.location + added - range.length, length: selected.length)
            } else if NSMaxRange(selected) <= range.location {
                selection = selected
            } else {
                selection = NSRange(location: range.location + added, length: 0)
            }
            mutate(tv, range: range, with: s, selection: selection)
            return true
        }

        /// ⌘B/⌘I: wrap the selection in `marker` (or insert an empty pair).
        private func wrapSelection(marker: String) {
            guard let tv = textView, tv.isFirstResponder else { return }
            let sel = tv.selectedRange
            let selected = sel.length > 0 ? tv.textStorage.mutableString.substring(with: sel) : ""
            let markerLen = (marker as NSString).length
            mutate(tv, range: sel, with: marker + selected + marker,
                   selection: NSRange(location: sel.location + markerLen, length: sel.length))
        }
    }
}

/// The editor's text view: a paste of media hands it to `pasteMedia` to be
/// attached; anything else pastes as usual.
final class PastingTextView: UITextView {
    var pasteMedia: ((PastedMedia) -> Void)?
    /// Told when the view joins a window: a focus request made before it was
    /// on screen is acted on then (`Coordinator.attached`).
    var onWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onWindow?() }
    }

    /// A sized-to-fit editor (the composer) never scrolls inside itself: the
    /// page around it does. UIKit still nudged the offset on some edits: Dan's
    /// recording showed the whole body dropping a few points after the
    /// keyboard turned "..." into "…" with a line below, until the next key.
    /// Held at the top whenever scrolling is off.
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set { super.contentOffset = isScrollEnabled ? newValue : .zero }
    }
    override func setContentOffset(_ offset: CGPoint, animated: Bool) {
        super.setContentOffset(isScrollEnabled ? offset : .zero, animated: animated)
    }

    /// The composer's control chords, declared here because the text view is
    /// the first responder while you type: the key catcher sits beside the
    /// page, not above it, so nothing it declares is in this responder chain.
    /// Priority over the text system, which reads ^f ^p ^d ^t as cursor edits.
    override var keyCommands: [UIKeyCommand]? {
        var own = (super.keyCommands ?? []) + [CommandKeys.toggle]
        // With a monitor showing this text, ↑/↓ move by the monitor's lines;
        // the phone keeps its own wrapping for how the text looks.
        if ExternalDisplayModel.shared.isConnected, ExternalDisplayModel.shared.bodyLayout != nil {
            own += [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow].map {
                let c = UIKeyCommand(input: $0, modifierFlags: [], action: #selector(quireLine(_:)))
                c.wantsPriorityOverSystemBehavior = true
                return c
            }
        }
        guard KeyCommandRouter.shared.wantsChords else { return own }
        // Esc leaves the page; ahead of the text system, which may keep it.
        let esc = EscapeChord.declared(composing: markedTextRange != nil).map { $0.keyCommand(action: #selector(quireEscape)) }
        return own + esc + KeyCommandRouter.chords.map {
            let c = UIKeyCommand(input: $0, modifierFlags: .control, action: #selector(quireChord(_:)))
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }

    @objc private func quireEscape() { KeyCommandRouter.shared.clear() }

    /// The column a run of ↑/↓ keeps to, as in any editor: a short line
    /// passed on the way doesn't pull the caret left for good.
    private var goalX: CGFloat?
    private var lastLineMove: Int?

    @objc private func quireLine(_ command: UIKeyCommand) {
        let up = command.input == UIKeyCommand.inputUpArrow
        let range = selectedRange
        let caret = up ? range.location : range.location + range.length
        if caret != lastLineMove { goalX = nil }
        let layout = ExternalDisplayModel.shared.bodyLayout?(text) ?? self
        guard let (to, x) = layout.verticalMove(from: caret, up: up, goalX: goalX) else { return }
        goalX = x
        lastLineMove = to
        selectedRange = NSRange(location: to, length: 0)
        scrollRangeToVisible(selectedRange)
        delegate?.textViewDidChangeSelection?(self)
    }

    @objc private func quireChord(_ command: UIKeyCommand) {
        if let input = command.input { KeyCommandRouter.shared.chord(input) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), pasteMedia != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let pasteMedia, let media = Attach.pasteboardMedia() { pasteMedia(media); return }
        super.paste(sender)
    }
}

extension UITextView {
    /// Where ↑ or ↓ from `caret` (a UTF-16 offset) lands in this view's own
    /// line breaks, keeping to `goalX` when given; returns the new offset and
    /// the column's x. Past the first or last line it goes to the start or end.
    func verticalMove(from caret: Int, up: Bool, goalX: CGFloat?) -> (Int, CGFloat)? {
        let length = (text as NSString).length
        guard let from = position(from: beginningOfDocument, offset: min(max(0, caret), length)) else { return nil }
        let rect = caretRect(for: from)
        guard rect.height > 0, rect.origin.x.isFinite else { return nil }
        let x = goalX ?? rect.midX
        let y = up ? rect.minY - rect.height / 2 : rect.maxY + rect.height / 2
        let top = caretRect(for: beginningOfDocument).minY
        let bottom = caretRect(for: endOfDocument).maxY
        if y < top { return (0, x) }
        if y > bottom { return (length, x) }
        guard let to = closestPosition(to: CGPoint(x: x, y: y)) else { return nil }
        return (offset(from: beginningOfDocument, to: to), x)
    }
}

/// The text view behind the external display's live entry. A read-only
/// UITextView draws no caret, so this draws its own — a bar in the accent
/// colour at `caretIndex`, blinking like the real one — and scrolls to keep
/// it in view: the phone's editor follows the caret, so the monitor must too,
/// or a correction three paragraphs up happens off-screen.
final class MirrorTextView: UITextView {
    /// UTF-16 offset of the caret; nil hides it (the body isn't focused).
    var caretIndex: Int? {
        didSet { if caretIndex != oldValue { caretMoved = true; setNeedsLayout() } }
    }
    var caretColor: UIColor = .tintColor {
        didSet {
            caretView.backgroundColor = caretColor
            for v in selectionViews { v.backgroundColor = caretColor.withAlphaComponent(0.25) }
        }
    }
    /// The phone's selection, shaded like a highlighter over the words.
    /// Read from the display model directly: selecting backwards moves only
    /// the start, which changes nothing SwiftUI would redraw this view for.
    private var selection: NSRange? {
        didSet { if selection != oldValue { setNeedsLayout() } }
    }
    private var selectionViews: [UIView] = []
    private var watching: AnyCancellable?

    private let caretView = UIView()
    /// Set when the caret or the text changed, so the next layout scrolls;
    /// a layout pass on its own (every scroll tick is one) must not.
    private var caretMoved = false
    private var blink: Timer?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit { blink?.invalidate() }

    private func configure() {
        caretView.isHidden = true
        caretView.backgroundColor = caretColor
        caretView.layer.cornerRadius = 1
        addSubview(caretView)
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self, self.caretIndex != nil else { return }
            self.caretView.alpha = self.caretView.alpha < 0.5 ? 1 : 0
        }
        // `.common`, so the blink carries on through the scroll animation.
        RunLoop.main.add(timer, forMode: .common)
        blink = timer
        watching = ExternalDisplayModel.shared.$selection.sink { [weak self] range in self?.selection = range }
    }

    /// The text was replaced underneath the caret: its rect has moved even if
    /// its index hasn't, and the newest line may be off-screen.
    func noteTextChanged() {
        caretMoved = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shadeSelection()
        positionCaret()
    }

    private func shadeSelection() {
        var rects: [CGRect] = []
        let length = (text as NSString).length
        if let s = selection, s.length > 0, NSMaxRange(s) <= length,
           let start = position(from: beginningOfDocument, offset: s.location),
           let end = position(from: start, offset: s.length),
           let range = textRange(from: start, to: end) {
            rects = selectionRects(for: range).map(\.rect).filter { $0.width > 0 && $0.height > 0 && $0.origin.y.isFinite }
        }
        while selectionViews.count < rects.count {
            let v = UIView()
            v.isUserInteractionEnabled = false
            v.layer.cornerRadius = 2
            v.backgroundColor = caretColor.withAlphaComponent(0.25)
            addSubview(v)
            selectionViews.append(v)
        }
        for (i, v) in selectionViews.enumerated() {
            v.isHidden = i >= rects.count
            if i < rects.count { v.frame = rects[i] }
        }
    }

    private func positionCaret() {
        let length = (text as NSString).length
        guard let index = caretIndex,
              let position = position(from: beginningOfDocument, offset: min(max(index, 0), length))
        else {
            caretView.isHidden = true
            return
        }
        // `caretRect` is in the view's own coordinates — content space for a
        // scroll view — which is also where subviews are placed.
        var rect = caretRect(for: position)
        guard rect.origin.y.isFinite, rect.height > 0 else { caretView.isHidden = true; return }
        rect.size.width = max(2, (font?.pointSize ?? 20) * 0.08)
        caretView.frame = rect
        caretView.isHidden = false
        bringSubviewToFront(caretView)
        guard caretMoved else { return }
        caretMoved = false
        caretView.alpha = 1   // a caret that just moved is a solid one
        keepVisible(rect)
    }

    /// Scroll only once the caret leaves a comfortable band — a line's worth
    /// in from each edge — and then put it a little above centre, where a
    /// reader's eye rests, rather than pinning the newest words to the bottom.
    private func keepVisible(_ caret: CGRect) {
        let height = bounds.height
        guard height > 0 else { return }
        let margin = min(height * 0.2, caret.height * 2)
        let visibleTop = contentOffset.y + margin
        let visibleBottom = contentOffset.y + height - margin
        guard caret.minY < visibleTop || caret.maxY > visibleBottom else { return }
        let target = caret.midY - height * 0.45
        let maxY = max(0, contentSize.height + contentInset.bottom - height)
        setContentOffset(CGPoint(x: 0, y: min(max(0, target), maxY)), animated: true)
    }
}
#endif
