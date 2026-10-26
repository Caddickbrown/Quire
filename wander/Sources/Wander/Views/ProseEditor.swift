//
//  ProseEditor.swift
//  Wander
//
//  The writing surface: a platform text view holding plain markdown, styled in
//  place. There is no preview pane — a heading looks like a heading while you
//  type it, and the markers themselves recede to a hairline grey.
//
//  Styling is a set of line-bound regex passes (see MarkdownStyle), re-run over
//  the edited paragraph on each keystroke and over the whole text when the
//  entry, theme or type size changes. macOS uses NSTextView, iOS UITextView;
//  everything above the view is shared.
//

import SwiftUI
import WanderCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Everything the editor needs that isn't the text itself.
struct ProseStyle: Equatable {
    var theme: Theme
    var scheme: ColorScheme
    var size: CGFloat
    /// Line spacing as a multiple of the type size, so it holds as type grows.
    var leading: Double
    var centred: Bool = false
    var typewriter: Bool
    var dimInactive: Bool

    /// Everything that changes how the text is drawn but not what it says.
    var key: String { "\(theme.id)-\(scheme)-\(size)-\(leading)-\(centred)-\(dimInactive)-\(typewriter)" }
}

#if canImport(AppKit)

struct ProseEditor: NSViewRepresentable {
    @Binding var text: String
    var style: ProseStyle
    /// Bumped by the owner to hand the caret to the editor.
    var focusToken: Int
    var onEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.widthTracksTextView = true

        let tv = ProseTextView(frame: .zero, textContainer: container)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [NSView.AutoresizingMask.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 0, height: 10)
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isAutomaticTextReplacementEnabled = true
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = false
        tv.usesFindBar = true
        tv.string = text

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false

        context.coordinator.restyle(tv, all: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ProseTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        var needsRestyle = false
        if tv.string != text {
            let selected = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length),
                                        length: 0))
            needsRestyle = true
        }
        if coordinator.styleKey != style.key {
            coordinator.styleKey = style.key
            needsRestyle = true
        }

        tv.placeholderAttributes = [
            .font: style.theme.proseFace.platformFont(style.size, weight: style.theme.proseWeightPlatform,
                                                       italic: true),
            .foregroundColor: style.theme.muted.opacity(0.55).platform
        ]
        tv.insertionPointColor = style.theme.accent.platform
        tv.selectedTextAttributes = [.backgroundColor: style.theme.accent.opacity(0.18).platform]
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0,
                                            bottom: style.typewriter ? 320 : 0, right: 0)

        if needsRestyle { coordinator.restyle(tv, all: true) }

        if coordinator.lastFocusToken != focusToken {
            coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProseEditor
        var styleKey = ""
        var lastFocusToken = 0

        init(_ parent: ProseEditor) {
            self.parent = parent
            self.styleKey = parent.style.key
            self.lastFocusToken = parent.focusToken
        }

        func restyle(_ tv: NSTextView, all: Bool) {
            guard let storage = tv.textStorage else { return }
            let style = parent.style
            // With no caret in the text there is no live paragraph, and focus
            // mode would grey the entry out entirely — dim only while writing.
            let writing = tv.window?.firstResponder === tv
            let base = MarkdownStyle.apply(to: storage, caret: tv.selectedRange(), restyleAll: all,
                                           theme: style.theme, size: style.size,
                                           leading: style.leading, centred: style.centred,
                                           dimInactive: style.dimInactive && writing)
            tv.typingAttributes = base
            tv.defaultParagraphStyle = base[.paragraphStyle] as? NSParagraphStyle
            // The restyle runs from inside `textDidChange`, while the text
            // system is still settling the edit it has just made, and the
            // redraw it owes the lines below the caret can be lost on the way
            // through: the text is in the storage, and laid out, but never
            // painted — insert a paragraph break above a line and that line
            // vanishes until something else disturbs the view. Ask for the
            // redraw plainly. Both calls are bounded by what is on screen, so
            // the length of the entry doesn't come into it.
            if let layout = tv.layoutManager, let container = tv.textContainer {
                layout.invalidateDisplay(forCharacterRange:
                    NSRange(location: 0, length: (tv.string as NSString).length))
                layout.ensureLayout(forBoundingRect: tv.visibleRect, in: container)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            restyle(tv, all: false)
            parent.onEdit()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent.style.dimInactive { restyle(tv, all: true) }
            if parent.style.typewriter { Self.centreCaret(tv) }
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent.style.dimInactive { restyle(tv, all: true) }
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent.style.dimInactive { restyle(tv, all: true) }
        }

        /// Keep the caret on the same line of the window as the text grows.
        static func centreCaret(_ tv: NSTextView) {
            guard let layout = tv.layoutManager,
                  let container = tv.textContainer,
                  let scroll = tv.enclosingScrollView else { return }
            let caret = NSRange(location: tv.selectedRange().location, length: 0)
            let glyphs = layout.glyphRange(forCharacterRange: caret, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let y = rect.midY + tv.textContainerInset.height - scroll.contentView.bounds.height / 2
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

/// NSTextView with a placeholder and the two markdown key equivalents a writing
/// app is expected to have.
final class ProseTextView: NSTextView {
    var placeholder = "Begin writing\u{2026}"
    var placeholderAttributes: [NSAttributedString.Key: Any] = [:]

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: placeholderAttributes)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": wrapSelection(with: "**"); return true
        // Underscores for emphasis, asterisks for strong: `_like this_` reads
        // as emphasis in plain text, and keeps the one marker clear of the two
        // that surround bold.
        case "i": wrapSelection(with: "_"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    /// Wrap the selection in a marker, or unwrap it if it is already wrapped.
    private func wrapSelection(with marker: String) {
        let range = selectedRange()
        let ns = string as NSString
        guard range.length > 0 else {
            insertText(marker + marker, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + marker.count, length: 0))
            return
        }
        let selected = ns.substring(with: range)
        let wrapped = selected.hasPrefix(marker) && selected.hasSuffix(marker)
            && selected.count > marker.count * 2
        let replacement = wrapped
            ? String(selected.dropFirst(marker.count).dropLast(marker.count))
            : marker + selected + marker
        if shouldChangeText(in: range, replacementString: replacement) {
            replaceCharacters(in: range, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: range.location,
                                     length: (replacement as NSString).length))
        }
    }
}

#else

struct ProseEditor: UIViewRepresentable {
    @Binding var text: String
    var style: ProseStyle
    var focusToken: Int
    var onEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.isScrollEnabled = true
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 40, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.autocorrectionType = .yes
        tv.smartQuotesType = .yes
        tv.smartDashesType = .yes
        tv.keyboardDismissMode = .interactive
        tv.text = text
        context.coordinator.restyle(tv, all: true)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        var needsRestyle = false
        if tv.text != text {
            let selected = tv.selectedRange
            tv.text = text
            tv.selectedRange = NSRange(location: min(selected.location, (text as NSString).length),
                                       length: 0)
            needsRestyle = true
        }
        if coordinator.styleKey != style.key {
            coordinator.styleKey = style.key
            needsRestyle = true
        }
        tv.tintColor = style.theme.accent.platform
        if needsRestyle { coordinator.restyle(tv, all: true) }

        if coordinator.lastFocusToken != focusToken {
            coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ProseEditor
        var styleKey = ""
        var lastFocusToken = 0

        init(_ parent: ProseEditor) {
            self.parent = parent
            self.styleKey = parent.style.key
            self.lastFocusToken = parent.focusToken
        }

        func restyle(_ tv: UITextView, all: Bool) {
            let style = parent.style
            let base = MarkdownStyle.apply(to: tv.textStorage, caret: tv.selectedRange,
                                           restyleAll: all, theme: style.theme, size: style.size,
                                           leading: style.leading, centred: style.centred,
                                           dimInactive: style.dimInactive)
            tv.typingAttributes = base
        }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            restyle(tv, all: false)
            parent.onEdit()
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            if parent.style.dimInactive { restyle(tv, all: true) }
        }
    }
}

#endif
