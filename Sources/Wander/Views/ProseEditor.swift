//
//  ProseEditor.swift
//  Wander
//
//  The writing surface: a TextKit 1 NSTextView holding plain markdown, styled
//  in place. There is no preview pane — a heading looks like a heading while
//  you type it, and the markers themselves recede to a hairline grey.
//
//  Styling is a set of line-bound regex passes (see MarkdownStyle), re-run over
//  the edited paragraph on each keystroke and over the whole text when the
//  entry, theme or type size changes.
//

import SwiftUI
import AppKit

struct ProseEditor: NSViewRepresentable {
    @Binding var text: String
    var theme: Theme
    var scheme: ColorScheme
    var size: CGFloat
    var typewriter: Bool
    var dimInactive: Bool
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
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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

        context.coordinator.textView = tv
        context.coordinator.applyAll(tv)
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
            // A new entry starts at the top with the caret at the head of it;
            // an external edit to the open entry keeps the caret where it was.
            let location = min(selected.location, (text as NSString).length)
            tv.setSelectedRange(NSRange(location: location, length: 0))
            needsRestyle = true
        }

        if coordinator.styleKey != styleKey {
            coordinator.styleKey = styleKey
            needsRestyle = true
        }

        tv.placeholderAttributes = [
            .font: Face.nsSerif(size, italic: true),
            .foregroundColor: theme.muted.opacity(0.55).nsColor
        ]
        tv.insertionPointColor = theme.accent.nsColor
        tv.selectedTextAttributes = [.backgroundColor: theme.accent.opacity(0.18).nsColor]
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0,
                                            bottom: typewriter ? 320 : 0, right: 0)

        if needsRestyle { coordinator.applyAll(tv) }

        if coordinator.lastFocusToken != focusToken {
            coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    /// Everything that changes how the text is drawn but not what it says.
    private var styleKey: String {
        "\(scheme)-\(size)-\(dimInactive)-\(typewriter)"
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProseEditor
        var styleKey = ""
        var lastFocusToken = 0
        weak var textView: ProseTextView?

        init(_ parent: ProseEditor) {
            self.parent = parent
            self.styleKey = parent.styleKey
            self.lastFocusToken = parent.focusToken
        }

        func applyAll(_ tv: NSTextView) {
            MarkdownStyle.apply(to: tv, range: nil,
                                theme: parent.theme, size: parent.size,
                                dimInactive: parent.dimInactive)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            MarkdownStyle.apply(to: tv, range: tv.selectedRange(),
                                theme: parent.theme, size: parent.size,
                                dimInactive: parent.dimInactive)
            parent.onEdit()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent.dimInactive {
                MarkdownStyle.apply(to: tv, range: nil,
                                    theme: parent.theme, size: parent.size,
                                    dimInactive: true)
            }
            if parent.typewriter { Self.centreCaret(tv) }
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

/// NSTextView with a placeholder and the two markdown key equivalents that a
/// writing app is expected to have.
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
        case "i": wrapSelection(with: "*"); return true
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
        let stripped = selected.hasPrefix(marker) && selected.hasSuffix(marker)
            && selected.count > marker.count * 2
        let replacement = stripped
            ? String(selected.dropFirst(marker.count).dropLast(marker.count))
            : marker + selected + marker
        if shouldChangeText(in: range, replacementString: replacement) {
            replaceCharacters(in: range, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
        }
    }
}
