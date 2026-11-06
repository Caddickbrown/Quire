//
//  MarkdownStyle.swift
//  Wander
//
//  Draws markdown as typography rather than as syntax. The text stays plain
//  markdown — what changes is how it looks: headings take the display serif,
//  quotes go italic and indent, code takes a tinted monospace, and every
//  marker (#, **, >, backtick) fades back so the prose reads clean with the
//  structure still visible.
//

import Foundation
import WanderCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

enum MarkdownStyle {

    // Line-bound block rules.
    private static let heading = regex(#"^(#{1,6})[ \t]+(.*)$"#, [.anchorsMatchLines])
    private static let quote   = regex(#"^([ \t]*>[ \t]?)(.*)$"#, [.anchorsMatchLines])
    private static let bullet  = regex(#"^([ \t]*)([-*+]|\d{1,3}\.)[ \t]+"#, [.anchorsMatchLines])
    private static let divider = regex(#"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, [.anchorsMatchLines])
    private static let fence   = regex("^```.*?^```", [.anchorsMatchLines, .dotMatchesLineSeparators])

    // Inline rules.
    private static let strong  = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, [])
    private static let emphasis = regex(#"(?<![*\w])([*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![*\w])"#, [])
    private static let code    = regex("`([^`\n]+)`", [])
    private static let link    = regex(#"\[([^\]\n]*)\]\(([^)\s]+)\)"#, [])
    private static let tag     = regex(#"@[a-zA-Z][a-zA-Z0-9_-]*"#, [])

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Restyle `range` (a caret position — its paragraph is used) or the whole
    /// text when `range` is nil. Long documents restyle a paragraph at a time;
    /// short ones — which is nearly every journal entry — restyle whole, so a
    /// closing `**` finds its opener however far back it sits.
    /// Restyle `storage`. `caret` is where the insertion point is — its
    /// paragraph is the unit restyled on a keystroke, and the one left lit in
    /// focus mode. Returns the base attributes so the caller can set them as
    /// the view's typing attributes.
    @discardableResult
    static func apply(to storage: NSTextStorage, caret: NSRange?, restyleAll: Bool,
                      theme: Theme, size: CGFloat, leading: Double, centred: Bool = false,
                      dimInactive: Bool) -> [NSAttributedString.Key: Any] {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        var target = full
        if let caret, !restyleAll, !dimInactive, ns.length > 8_000 {
            let point = NSRange(location: min(caret.location, ns.length), length: 0)
            target = ns.paragraphRange(for: point)
        }

        let body = theme.proseFace.platformFont(size, weight: theme.proseWeightPlatform)
        let bodyParagraph = paragraph(size: size, leading: leading, centred: centred)
        let base: [NSAttributedString.Key: Any] = [
            .font: body,
            .foregroundColor: theme.prose.platform,
            .paragraphStyle: bodyParagraph
        ]
        let marker = theme.muted.opacity(0.45).platform

        storage.beginEditing()
        storage.setAttributes(base, range: target)

        func each(_ rule: NSRegularExpression, _ handle: (NSTextCheckingResult) -> Void) {
            rule.enumerateMatches(in: storage.string, range: target) { match, _, _ in
                if let match { handle(match) }
            }
        }
        func set(_ key: NSAttributedString.Key, _ value: Any, _ r: NSRange) {
            guard r.location != NSNotFound, r.length > 0,
                  NSMaxRange(r) <= ns.length else { return }
            storage.addAttribute(key, value: value, range: r)
        }

        // Headings — the display sizes carry the hierarchy, the hashes fade.
        each(heading) { m in
            let level = m.range(at: 1).length
            let scale: CGFloat = [1.55, 1.30, 1.14, 1.04, 1.0, 1.0][min(level, 6) - 1]
            set(.font, theme.displayFace.platformFont(size * scale, weight: .semibold), m.range)
            set(.foregroundColor, theme.ink.platform, m.range)
            set(.paragraphStyle, paragraph(size: size, leading: leading, spacingBefore: size * 0.9), m.range)
            // The hashes stay, but at body size and hairline grey, so they read
            // as a printer's mark beside the heading rather than part of it.
            set(.font, theme.proseFace.platformFont(size * 0.85, weight: theme.proseWeightPlatform), m.range(at: 1))
            set(.foregroundColor, marker, m.range(at: 1))
        }

        // Block quotes — italic, indented, in the muted voice of a margin note.
        each(quote) { m in
            set(.font, theme.proseFace.platformFont(size, weight: theme.proseWeightPlatform, italic: true), m.range)
            set(.foregroundColor, theme.muted.platform, m.range)
            set(.paragraphStyle, paragraph(size: size, leading: leading, indent: size * 1.1), m.range)
            set(.font, theme.proseFace.platformFont(size * 0.85, weight: theme.proseWeightPlatform), m.range(at: 1))
            set(.foregroundColor, marker, m.range(at: 1))
        }

        // List markers pick up the accent; the item hangs off the marker.
        each(bullet) { m in
            set(.paragraphStyle, paragraph(size: size, leading: leading, indent: size * 1.2), m.range)
            set(.foregroundColor, theme.accent.platform, m.range(at: 2))
        }

        each(divider) { m in
            set(.foregroundColor, marker, m.range)
            set(.kern, size * 0.18, m.range)
        }

        each(strong) { m in
            set(.font, theme.proseFace.platformFont(size, weight: .bold), m.range(at: 2))
            set(.foregroundColor, theme.ink.platform, m.range(at: 2))
            set(.foregroundColor, marker, NSRange(location: m.range.location, length: m.range(at: 1).length))
            set(.foregroundColor, marker, NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length,
                                                  length: m.range(at: 1).length))
        }

        each(emphasis) { m in
            set(.font, theme.proseFace.platformFont(size, weight: theme.proseWeightPlatform, italic: true), m.range(at: 2))
            set(.foregroundColor, marker, NSRange(location: m.range.location, length: 1))
            set(.foregroundColor, marker, NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }

        each(code) { m in
            set(.font, theme.monoFace.platformFont(size * 0.88), m.range)
            set(.backgroundColor, theme.rule.opacity(0.5).platform, m.range)
            set(.foregroundColor, theme.ink.platform, m.range(at: 1))
            set(.foregroundColor, marker, NSRange(location: m.range.location, length: 1))
            set(.foregroundColor, marker, NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }

        each(fence) { m in
            set(.font, theme.monoFace.platformFont(size * 0.88), m.range)
            set(.foregroundColor, theme.prose.platform, m.range)
            set(.backgroundColor, theme.rule.opacity(0.35).platform, m.range)
            set(.paragraphStyle, paragraph(size: size, leading: leading, indent: size * 0.6), m.range)
        }

        each(link) { m in
            set(.foregroundColor, theme.accent.platform, m.range(at: 1))
            set(.underlineStyle, NSUnderlineStyle.single.rawValue, m.range(at: 1))
            set(.underlineColor, theme.accent.opacity(0.4).platform, m.range(at: 1))
            set(.foregroundColor, marker, m.range(at: 2))
            set(.font, theme.monoFace.platformFont(size * 0.8), m.range(at: 2))
        }

        // @tags — the same tokens Nook and jnl index on.
        each(tag) { m in
            set(.foregroundColor, theme.accent.platform, m.range)
        }

        // Focus mode: everything but the paragraph under the caret recedes.
        if dimInactive {
            let point = NSRange(location: min(caret?.location ?? 0, ns.length), length: 0)
            let live = ns.paragraphRange(for: point)
            let faded = theme.muted.opacity(0.38).platform
            for r in [NSRange(location: 0, length: live.location),
                      NSRange(location: NSMaxRange(live), length: ns.length - NSMaxRange(live))] {
                set(.foregroundColor, faded, r)
            }
        }

        storage.endEditing()
        return base
    }

    private static func paragraph(size: CGFloat,
                                  leading: Double,
                                  spacingBefore: CGFloat = 0,
                                  indent: CGFloat = 0,
                                  centred: Bool = false) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        if centred { style.alignment = .center }
        style.lineSpacing = size * CGFloat(leading)
        style.paragraphSpacing = size * CGFloat(leading) * 1.5
        style.paragraphSpacingBefore = spacingBefore
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }
}
