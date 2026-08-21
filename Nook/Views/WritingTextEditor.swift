//
//  WritingTextEditor.swift
//  Nook
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
//  * live styling      — `_italic_`, `**bold**` and `` `code` `` render in
//                        place while editing; the markers stay in the text.
//  * list continuation — ↩ inside a `- `, `1. ` or `- [ ] ` line continues the
//                        list; ↩ on an empty item ends it.
//  * ⌘B / ⌘I          — wrap the selection in `**` / `_` (via the Format menu
//                        notifications, so the shortcut reaches whichever
//                        editor is focused).
//

import SwiftUI

private let tagRegex = try! NSRegularExpression(pattern: #"@[a-zA-Z][a-zA-Z0-9_-]*"#)
/// `_text_` or `__text__` → italicised while editing (slant applied via
/// .obliqueness so it works for fonts like Lato with no separate italic face).
/// The backreference makes the closing run of underscores match the opening.
private let emphasisRegex = try! NSRegularExpression(pattern: #"(_{1,2})(.+?)\1"#)
/// `**text**` → bold while editing.
private let boldRegex = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
/// `` `text` `` → monospaced while editing.
private let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)

extension Notification.Name {
    /// Posted by the Format menu (⌘B / ⌘I); handled by whichever editor is
    /// first responder. A notification rather than a focused-value plumbing
    /// job: the composer, the entry editor and the Stream's in-place editor
    /// all host this view, and the responder check picks the right one.
    static let nookFormatBold   = Notification.Name("com.caddickbrown.nook.formatBold")
    static let nookFormatItalic = Notification.Name("com.caddickbrown.nook.formatItalic")
}

// List-continuation rules live in Models/ListContinuation.swift (pure, so
// `make check` and NookTests exercise them); both coordinators below call it.

/// The `@token` the caret sits in (or right after): its UTF-16 range including
/// the `@`, and the partial name typed so far. Nil when the caret isn't in one.
/// Drives tag autocompletion on both platforms.
/// "@" as a UTF-16 unit, for NSString.character(at:) comparisons.
let nookAtSign: unichar = 64

func nookTagToken(in text: String, caret: Int) -> (range: NSRange, partial: String)? {
    let ns = text as NSString
    guard caret > 0, caret <= ns.length else { return nil }
    func isTagChar(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
            || c == 45 /* - */ || c == 95 /* _ */
    }
    var i = caret - 1
    while i >= 0, isTagChar(ns.character(at: i)) { i -= 1 }
    guard i >= 0, ns.character(at: i) == nookAtSign else { return nil }
    // The @ must start a token, not sit mid-word (an email address, say).
    if i > 0 {
        let before = ns.character(at: i - 1)
        if isTagChar(before) || before == nookAtSign { return nil }
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

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
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
        for m in emphasisRegex.matches(in: sub, range: subRange) {
            tv.textStorage?.addAttribute(.obliqueness, value: 0.2, range: shifted(m.range))
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
        for m in emphasisRegex.matches(in: tv.string, range: full) {
            tv.textStorage?.addAttribute(.obliqueness, value: 0.2, range: m.range)
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
        /// The post-edit range of the in-flight user edit, recorded in
        /// shouldChangeText; nil for programmatic replacements (full restyle).
        private var pendingEditRange: NSRange?
        private var observers: [NSObjectProtocol] = []

        init(text: Binding<String>) {
            self.text = text
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .nookFormatBold, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrapSelection(marker: "**") }
            })
            observers.append(center.addObserver(forName: .nookFormatItalic, object: nil, queue: .main) { [weak self] _ in
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
                  let token = nookTagToken(in: tv.string, caret: tv.selectedRange().location),
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
                  ns.character(at: charRange.location - 1) == nookAtSign else { return [] }
            let typed = ns.substring(with: charRange).lowercased()
            return tagSuggestions.filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if focusParagraph { reapply?() }   // the dimmed region follows the caret
            recenter?()
        }

        /// ↩ continues / ends a list; anything else falls through.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            guard sel.length == 0 else { return false }
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            var line = ns.substring(with: lineRange)
            if line.hasSuffix("\n") { line = String(line.dropLast()) }
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

#elseif os(iOS)
import UIKit

private func platformFont(_ raw: String, _ size: CGFloat) -> UIFont {
    let base: UIFont
    switch WritingFont(rawValue: raw) ?? .lato {
    case .lato:   base = UIFont(name: "Lato-Regular", size: size) ?? .systemFont(ofSize: size)
    case .system: base = .systemFont(ofSize: size)
    case .serif:  base = designed(size, .serif)
    case .mono:   base = .monospacedSystemFont(ofSize: size, weight: .regular)
    }
    // Track Dynamic Type: the px preference is the base size; the system's
    // text-size setting scales it, so accessibility sizes reach the editor too
    // (SwiftUI's Font.custom already scales everywhere else).
    return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
}
private func designed(_ size: CGFloat, _ design: UIFontDescriptor.SystemDesign) -> UIFont {
    let base = UIFont.systemFont(ofSize: size)
    if let d = base.fontDescriptor.withDesign(design) { return UIFont(descriptor: d, size: size) }
    return base
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

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.showsVerticalScrollIndicator = false
        tv.showsHorizontalScrollIndicator = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = !sizeToFit
        context.coordinator.textView = tv
        apply(to: tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.textView = tv
        tv.isScrollEnabled = !sizeToFit
        // Restyle only when something actually changed — the coordinator has
        // already restyled the edited paragraph on the keystroke path, and the
        // full re-attribute here made every keystroke O(entry).
        let signature = styleSignature
        if tv.text != text {
            tv.text = text
            apply(to: tv)
            context.coordinator.lastStyleSignature = signature
        } else if context.coordinator.lastStyleSignature != signature {
            apply(to: tv)
            context.coordinator.lastStyleSignature = signature
        }
        // Room under the last line so the caret can stay centred at the end.
        tv.contentInset.bottom = (typewriter && !sizeToFit) ? tv.bounds.height * 0.5 : 0
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
    }

    /// Everything that changes how text is styled, so unchanged updates skip
    /// the full re-attribute.
    private var styleSignature: String {
        "\(fontRaw)|\(size)|\(lineSpacing)|\(highlightTags)|\(focusParagraph)|\(textColor)|\(accent)"
    }

    /// Re-attribute just the paragraph(s) covering `range` — the per-keystroke
    /// path. Every styling regex is line-bound, so a paragraph is a safe unit.
    private func styleParagraph(_ tv: UITextView, around range: NSRange?) {
        let ns = tv.text as NSString
        guard let range else { apply(to: tv); return }
        let clamped = NSRange(location: min(range.location, ns.length),
                              length: min(range.length, ns.length - min(range.location, ns.length)))
        let target = ns.paragraphRange(for: clamped)
        let font = platformFont(fontRaw, size)
        let color = UIColor(textColor)
        let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing
        tv.textStorage.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para], range: target)
        let sub = ns.substring(with: target)
        let subRange = NSRange(location: 0, length: (sub as NSString).length)
        func shifted(_ r: NSRange) -> NSRange { NSRange(location: r.location + target.location, length: r.length) }
        if highlightTags {
            for m in tagRegex.matches(in: sub, range: subRange) {
                tv.textStorage.addAttribute(.foregroundColor, value: UIColor(accent), range: shifted(m.range))
            }
        }
        for m in emphasisRegex.matches(in: sub, range: subRange) {
            tv.textStorage.addAttribute(.obliqueness, value: 0.2, range: shifted(m.range))
        }
        let boldDescriptor = font.fontDescriptor.withSymbolicTraits(.traitBold)
        let bold = boldDescriptor.map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        for m in boldRegex.matches(in: sub, range: subRange) {
            tv.textStorage.addAttribute(.font, value: bold, range: shifted(m.range))
        }
        let mono = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
        for m in codeRegex.matches(in: sub, range: subRange) {
            tv.textStorage.addAttribute(.font, value: mono, range: shifted(m.range))
        }
    }

    private func apply(to tv: UITextView) {
        let font = platformFont(fontRaw, size)
        let color = UIColor(textColor)
        let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing
        tv.font = font
        tv.textColor = color
        tv.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let ns = tv.text as NSString
        let full = NSRange(location: 0, length: ns.length)
        tv.textStorage.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para], range: full)
        if highlightTags {
            for m in tagRegex.matches(in: tv.text, range: full) {
                tv.textStorage.addAttribute(.foregroundColor, value: UIColor(accent), range: m.range)
            }
        }
        for m in emphasisRegex.matches(in: tv.text, range: full) {
            tv.textStorage.addAttribute(.obliqueness, value: 0.2, range: m.range)
        }
        // Derive from the (Dynamic Type-scaled) body font, not the raw px size.
        let boldDescriptor = font.fontDescriptor.withSymbolicTraits(.traitBold)
        let bold = boldDescriptor.map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        for m in boldRegex.matches(in: tv.text, range: full) {
            tv.textStorage.addAttribute(.font, value: bold, range: m.range)
        }
        let mono = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
        for m in codeRegex.matches(in: tv.text, range: full) {
            tv.textStorage.addAttribute(.font, value: mono, range: m.range)
        }
        if focusParagraph, ns.length > 0 {
            let sel = tv.selectedRange
            let paragraph = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
            let dimmed = color.withAlphaComponent(0.35)
            if paragraph.location > 0 {
                tv.textStorage.addAttribute(.foregroundColor, value: dimmed,
                                            range: NSRange(location: 0, length: paragraph.location))
            }
            let after = paragraph.location + paragraph.length
            if after < ns.length {
                tv.textStorage.addAttribute(.foregroundColor, value: dimmed,
                                            range: NSRange(location: after, length: ns.length - after))
            }
        }
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
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
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
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        return ceil(bounds.height) + size + lineSpacing
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        weak var textView: UITextView?
        /// Re-applies styling with current settings (the focus dim tracks the caret).
        var reapply: (() -> Void)?
        /// Paragraph-scoped restyle for the just-edited range (nil = full).
        var restyleParagraph: ((NSRange?) -> Void)?
        /// Typewriter centring; nil when the mode is off.
        var recenter: (() -> Void)?
        var focusParagraph = false
        /// Tag names for the @-completion bar (no @, frequency-ordered).
        var tagSuggestions: [String] = []
        /// What the last full apply styled with — updateUIView's skip check.
        var lastStyleSignature = ""
        /// The post-edit range of the in-flight user edit, recorded in
        /// shouldChangeTextIn; nil for programmatic replacements (full restyle).
        private var pendingEditRange: NSRange?
        private var lastTagBarKey = ""
        private var observers: [NSObjectProtocol] = []

        init(text: Binding<String>) {
            self.text = text
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .nookFormatBold, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrapSelection(marker: "**") }
            })
            observers.append(center.addObserver(forName: .nookFormatItalic, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrapSelection(marker: "_") }
            })
        }

        deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            restyleParagraph?(pendingEditRange)   // nil (e.g. programmatic set) = full
            pendingEditRange = nil
            recenter?()
            updateTagBar(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if focusParagraph { reapply?() }   // the dimmed region follows the caret
            recenter?()
            updateTagBar(textView)
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
                  let token = nookTagToken(in: tv.text, caret: tv.selectedRange.location) else {
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
                          let token = nookTagToken(in: tv.text, caret: tv.selectedRange.location)
                    else { return }
                    let replacement = "@\(name) "
                    self.mutate(tv, range: token.range, with: replacement,
                                caret: token.range.location + (replacement as NSString).length)
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

        /// ↩ continues / ends a list; anything else falls through. Also
        /// records where the edit will land, so the restyle stays
        /// paragraph-local.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            pendingEditRange = NSRange(location: range.location,
                                       length: (replacement as NSString).length)
            guard replacement == "\n", range.length == 0 else { return true }
            let ns = textView.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var line = ns.substring(with: lineRange)
            if line.hasSuffix("\n") { line = String(line.dropLast()) }
            let contentEnd = lineRange.location + (line as NSString).length
            guard range.location == contentEnd else { return true }
            switch ListContinuation.action(for: line) {
            case .none:
                return true
            case .continueList(let prefix):
                mutate(textView, range: range, with: "\n" + prefix,
                       caret: range.location + ("\n" + prefix).utf16.count)
                return false
            case .endList(let prefixLength):
                let prefixRange = NSRange(location: lineRange.location, length: prefixLength)
                mutate(textView, range: prefixRange, with: "", caret: lineRange.location)
                return false
            }
        }

        /// Replace `range` with `s` through UITextInput's `replace`, which —
        /// unlike mutating textStorage directly — registers undo, matching the
        /// macOS shouldChangeText path.
        private func mutate(_ tv: UITextView, range: NSRange, with s: String, caret: Int) {
            guard let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
                  let end = tv.position(from: start, offset: range.length),
                  let textRange = tv.textRange(from: start, to: end) else { return }
            // `replace` may re-enter shouldChangeTextIn with its own range;
            // set ours after, so the restyle covers what was really inserted.
            tv.replace(textRange, withText: s)
            pendingEditRange = NSRange(location: range.location, length: (s as NSString).length)
            tv.selectedRange = NSRange(location: caret, length: 0)
            textViewDidChange(tv)
        }

        /// ⌘B/⌘I: wrap the selection in `marker` (or insert an empty pair).
        private func wrapSelection(marker: String) {
            guard let tv = textView, tv.isFirstResponder else { return }
            let sel = tv.selectedRange
            let ns = tv.text as NSString
            let selected = sel.length > 0 ? ns.substring(with: sel) : ""
            let markerLen = (marker as NSString).length
            guard let start = tv.position(from: tv.beginningOfDocument, offset: sel.location),
                  let end = tv.position(from: start, offset: sel.length),
                  let textRange = tv.textRange(from: start, to: end) else { return }
            tv.replace(textRange, withText: marker + selected + marker)
            tv.selectedRange = NSRange(location: sel.location + markerLen, length: sel.length)
            textViewDidChange(tv)
        }
    }
}
#endif
