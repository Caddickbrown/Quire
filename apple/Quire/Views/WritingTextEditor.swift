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
//  * live styling      — `_italic_`, `**bold**` and `` `code` `` render in
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
    let ns = text as NSString
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
    var focused: Binding<Bool>? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let tv: UITextView = mirror ? MirrorTextView() : PastingTextView()
        tv.delegate = context.coordinator
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
        context.coordinator.textView = tv
        apply(to: tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.textView = tv
        context.coordinator.focused = focused
        if mirror { updateMirror(tv, context: context); return }
        tv.isScrollEnabled = !sizeToFit
        // Restyle only when something actually changed — the coordinator has
        // already restyled the edited paragraph on the keystroke path, and the
        // full re-attribute here made every keystroke O(entry).
        let signature = styleSignature
        if tv.text != text {
            tv.text = text
            // Same reason as the macOS side: a wholesale swap invalidates every
            // range the undo stack is holding, so drop it rather than let a
            // shake-to-undo paste the old entry's edits into the new one.
            tv.undoManager?.removeAllActions()
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
        context.coordinator.onCaretChange = onCaretChange
        (tv as? PastingTextView)?.pasteMedia = onPasteMedia
        // UIKit focus callbacks update SwiftUI state; wait until this update
        // has finished and the text view is attached to its window.
        if focused != nil {
            DispatchQueue.main.async { [weak tv, weak coordinator = context.coordinator] in
                guard let tv, tv.window != nil, let focused = coordinator?.focused else { return }
                if focused.wrappedValue, !tv.isFirstResponder { tv.becomeFirstResponder() }
                else if !focused.wrappedValue, tv.isFirstResponder { tv.resignFirstResponder() }
            }
        }
    }

    /// The mirror's update: merge the new text in as one edit, restyle what
    /// changed, and hand the caret to the view. No typewriter, focus dim or
    /// tag bar — none of them mean anything on a screen nobody types into.
    private func updateMirror(_ tv: UITextView, context: Context) {
        let signature = styleSignature
        if tv.text != text {
            mergeMirrorText(tv, text)
            (tv as? MirrorTextView)?.noteTextChanged()
        }
        if context.coordinator.lastStyleSignature != signature {
            apply(to: tv)
            context.coordinator.lastStyleSignature = signature
        }
        // Room under the last line, so the caret can sit mid-screen at the end
        // of the text instead of the newest words hugging the bottom edge.
        tv.contentInset.bottom = tv.bounds.height * 0.45
        if let m = tv as? MirrorTextView {
            m.caretColor = UIColor(accent)
            m.caretIndex = mirrorCaret
        }
    }

    /// Apply the new text as a single edit — the common prefix and suffix stay
    /// put, so a keystroke restyles only its own paragraph and the scroll
    /// position holds. Assigning `tv.text` wholesale re-laid-out everything
    /// and threw the offset away, which is what kept the monitor pinned to the
    /// top or the bottom rather than to the caret.
    private func mergeMirrorText(_ tv: UITextView, _ new: String) {
        let old = tv.text as NSString
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
        styleParagraph(tv, around: NSRange(location: prefix, length: (replacement as NSString).length))
    }

    /// Everything that changes how text is styled, so unchanged updates skip
    /// the full re-attribute.
    private var styleSignature: String {
        "\(fontRaw)|\(size)|\(lineSpacing)|\(highlightTags)|\(focusParagraph)|\(textColor)|\(accent)|\(mirror)"
    }

    /// Re-attribute just the paragraph(s) covering `range` — the per-keystroke
    /// path. Every styling regex is line-bound, so a paragraph is a safe unit.
    private func styleParagraph(_ tv: UITextView, around range: NSRange?) {
        let ns = tv.text as NSString
        guard let range else { apply(to: tv); return }
        let clamped = NSRange(location: min(range.location, ns.length),
                              length: min(range.length, ns.length - min(range.location, ns.length)))
        let target = ns.paragraphRange(for: clamped)
        let font = platformFont(fontRaw, size, scaled: !mirror)
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
        let font = platformFont(fontRaw, size, scaled: !mirror)
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
            attributes: [.font: platformFont(fontRaw, size, scaled: !mirror), .paragraphStyle: para])
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        return ceil(bounds.height) + size + lineSpacing
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var focused: Binding<Bool>?
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
        /// Caret reporting for the external display (see `onCaretChange`).
        var onCaretChange: ((Int?) -> Void)?
        /// The post-edit range of the in-flight user edit, recorded in
        /// shouldChangeTextIn; nil for programmatic replacements (full restyle).
        private var pendingEditRange: NSRange?
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
            reportCaret(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) { focused?.wrappedValue = true; reportCaret(textView) }
        func textViewDidEndEditing(_ textView: UITextView) { focused?.wrappedValue = false; onCaretChange?(nil) }

        /// The end of the selection, or nil while the keyboard is elsewhere
        /// (the title field, say) — the monitor shouldn't blink a caret the
        /// phone isn't showing.
        private func reportCaret(_ tv: UITextView) {
            guard let onCaretChange else { return }
            onCaretChange(tv.isFirstResponder ? NSMaxRange(tv.selectedRange) : nil)
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
                  let token = quireTagToken(in: tv.text, caret: tv.selectedRange.location) else {
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
                          let token = quireTagToken(in: tv.text, caret: tv.selectedRange.location)
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

/// The editor's text view: a paste of media hands it to `pasteMedia` to be
/// attached; anything else pastes as usual.
final class PastingTextView: UITextView {
    var pasteMedia: ((PastedMedia) -> Void)?

    /// The composer's control chords, declared here because the text view is
    /// the first responder while you type: the key catcher sits beside the
    /// page, not above it, so nothing it declares is in this responder chain.
    /// Priority over the text system, which reads ^f ^p ^d ^t as cursor edits.
    override var keyCommands: [UIKeyCommand]? {
        var own = super.keyCommands ?? []
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
        return own + KeyCommandRouter.chords.map {
            let c = UIKeyCommand(input: $0, modifierFlags: .control, action: #selector(quireChord(_:)))
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }

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
        didSet { caretView.backgroundColor = caretColor }
    }

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
    }

    /// The text was replaced underneath the caret: its rect has moved even if
    /// its index hasn't, and the newest line may be off-screen.
    func noteTextChanged() {
        caretMoved = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionCaret()
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
