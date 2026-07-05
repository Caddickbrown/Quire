//
//  WritingTextEditor.swift
//  Jibber
//
//  A thin wrapper over NSTextView / UITextView so we can control what SwiftUI's
//  TextEditor won't: zero text insets (so an overlaid placeholder lands exactly
//  on the caret) and a hidden scroll indicator.
//

import SwiftUI

private let tagRegex = try! NSRegularExpression(pattern: #"@[a-zA-Z][a-zA-Z0-9_-]*"#)

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

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        apply(to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        apply(to: tv)
    }

    private func apply(to tv: NSTextView) {
        let font = platformFont(fontRaw, size)
        let color = NSColor(textColor)
        let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing
        tv.font = font
        tv.textColor = color
        tv.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para], range: full)
        if highlightTags {
            let tagColor = NSColor.controlAccentColor
            for m in tagRegex.matches(in: tv.string, range: full) {
                tv.textStorage?.addAttribute(.foregroundColor, value: tagColor, range: m.range)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

#elseif os(iOS)
import UIKit

private func platformFont(_ raw: String, _ size: CGFloat) -> UIFont {
    switch WritingFont(rawValue: raw) ?? .lato {
    case .lato:   return UIFont(name: "Lato-Regular", size: size) ?? .systemFont(ofSize: size)
    case .system: return .systemFont(ofSize: size)
    case .serif:  return designed(size, .serif)
    case .mono:   return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
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

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.showsVerticalScrollIndicator = false
        tv.showsHorizontalScrollIndicator = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        apply(to: tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.text = $text
        if tv.text != text { tv.text = text }
        apply(to: tv)
    }

    private func apply(to tv: UITextView) {
        let font = platformFont(fontRaw, size)
        let color = UIColor(textColor)
        let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing
        tv.font = font
        tv.textColor = color
        tv.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let full = NSRange(location: 0, length: (tv.text as NSString).length)
        tv.textStorage.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para], range: full)
        if highlightTags {
            for m in tagRegex.matches(in: tv.text, range: full) {
                tv.textStorage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: m.range)
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
#endif
