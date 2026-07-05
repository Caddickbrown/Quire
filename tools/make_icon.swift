//
//  make_icon.swift — renders Jibber's app icon.
//
//  Usage:
//    swift tools/make_icon.swift preview     → render every concept at 256px to /tmp/jibber-icons/
//    swift tools/make_icon.swift <concept>   → render the chosen concept at ALL sizes into the appiconset
//
//  Concepts: bubble | pages | ink | glyph
//

import AppKit
import CoreText
import CoreGraphics
import Foundation

let outDir = "Jibber/Assets.xcassets/AppIcon.appiconset"

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let cs = CGColorSpaceCreateDeviceRGB()

func ctx(_ px: Int) -> CGContext {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                      bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setAllowsAntialiasing(true)
    c.interpolationQuality = .high
    return c
}

/// Background squircle filled with a vertical gradient; returns the clip rect.
@discardableResult
func squircle(_ c: CGContext, _ s: CGFloat, _ top: CGColor, _ bottom: CGColor) -> CGRect {
    let margin = s * 0.085
    let rect = CGRect(x: margin, y: margin, width: s - 2*margin, height: s - 2*margin)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    c.saveGState()
    c.addPath(path); c.clip()
    let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    c.restoreGState()
    return rect
}

func roundedRectPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawGlyphJ(_ c: CGContext, _ s: CGFloat, color: CGColor, fontFrac: CGFloat = 0.66,
                dy: CGFloat = 0, shadow: Bool = false) {
    let font = CTFontCreateWithName("SFProRounded-Bold" as CFString, s * fontFrac, nil)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: "j", attributes: [.font: font, .foregroundColor: color]))
    let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    c.saveGState()
    if shadow {
        c.setShadow(offset: CGSize(width: 0, height: -s*0.012), blur: s*0.03,
                    color: srgb(0,0,0,0.28))
    }
    c.textPosition = CGPoint(x: (s - b.width)/2 - b.minX, y: (s - b.height)/2 - b.minY + dy)
    CTLineDraw(line, c)
    c.restoreGState()
}

// ── Concept: bubble ── speech bubble + writing lines (jibber = talk + journal) ──
func conceptBubble(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircle(c, s, srgb(255, 138, 76), srgb(240, 66, 92))     // amber → coral
    let cream = srgb(252, 248, 240)

    // Bubble body
    let bw = s * 0.60, bh = s * 0.44
    let bx = (s - bw)/2, by = s*0.40
    let bubble = CGRect(x: bx, y: by, width: bw, height: bh)
    c.addPath(roundedRectPath(bubble, bh*0.30)); c.setFillColor(cream); c.fillPath()

    // Tail (bottom-left), drawn as a small triangle merged into the body
    c.move(to: CGPoint(x: bx + bw*0.30, y: by + bh*0.06))
    c.addLine(to: CGPoint(x: bx + bw*0.14, y: by - bh*0.16))
    c.addLine(to: CGPoint(x: bx + bw*0.46, y: by + bh*0.10))
    c.closePath(); c.setFillColor(cream); c.fillPath()

    // Three "text" lines inside
    let ink = srgb(240, 66, 92)
    let lineH = bh*0.11
    let widths: [CGFloat] = [0.68, 0.80, 0.46]
    for (i, wf) in widths.enumerated() {
        let ly = by + bh*0.66 - CGFloat(i)*bh*0.24
        let lr = CGRect(x: bx + bw*0.16, y: ly, width: bw*wf, height: lineH)
        c.addPath(roundedRectPath(lr, lineH/2)); c.setFillColor(ink); c.fillPath()
    }
    return c
}

// ── Concept: pages ── an open journal / stacked pages with a ribbon ──
func conceptPages(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircle(c, s, srgb(46, 196, 182), srgb(28, 126, 214))    // teal → blue
    let cream = srgb(252, 248, 240)

    // Open book: two rounded page panels meeting at a center spine.
    let pw = s*0.30, ph = s*0.42
    let cx = s/2, cy = s/2
    let gap = s*0.015
    for sign in [-1.0, 1.0] as [CGFloat] {
        let r = CGRect(x: cx + (sign<0 ? -pw - gap : gap), y: cy - ph/2, width: pw, height: ph)
        c.addPath(roundedRectPath(r, s*0.03)); c.setFillColor(cream); c.fillPath()
        // ruled lines
        c.setStrokeColor(srgb(28, 126, 214, 0.55)); c.setLineWidth(s*0.012); c.setLineCap(.round)
        for i in 0..<3 {
            let ly = r.maxY - ph*0.28 - CGFloat(i)*ph*0.20
            c.move(to: CGPoint(x: r.minX + pw*0.16, y: ly))
            c.addLine(to: CGPoint(x: r.maxX - pw*0.16, y: ly))
            c.strokePath()
        }
    }
    // Spine
    let spine = CGRect(x: cx - gap, y: cy - ph/2 - s*0.01, width: gap*2, height: ph + s*0.02)
    c.setFillColor(srgb(255, 209, 102)); c.fill(spine)
    return c
}

// ── Concept: ink ── ink "j" on warm paper with a folded corner ──
func conceptInk(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    let rect = squircle(c, s, srgb(251, 243, 227), srgb(240, 224, 194))  // paper cream
    let ink = srgb(30, 42, 90)

    // Folded top-right corner
    let fold = s*0.20
    c.saveGState()
    c.addPath(roundedRectPath(rect, rect.width*0.225)); c.clip()
    c.move(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
    c.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    c.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold))
    c.closePath(); c.setFillColor(srgb(214, 191, 150)); c.fillPath()
    c.restoreGState()

    drawGlyphJ(c, s, color: ink, fontFrac: 0.62)
    return c
}

// ── Concept: glyph ── the current mark, refined with depth ──
func conceptGlyph(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircle(c, s, srgb(124, 92, 255), srgb(88, 44, 214))     // violet
    drawGlyphJ(c, s, color: srgb(252, 248, 240), fontFrac: 0.66, shadow: true)
    return c
}

/// Flat (single-colour, no gradient) squircle; returns the rect.
@discardableResult
func squircleFlat(_ c: CGContext, _ s: CGFloat, _ color: CGColor) -> CGRect {
    let margin = s * 0.085
    let rect = CGRect(x: margin, y: margin, width: s - 2*margin, height: s - 2*margin)
    c.addPath(roundedRectPath(rect, rect.width * 0.225)); c.setFillColor(color); c.fillPath()
    return rect
}

// ── Simpler concepts ────────────────────────────────────────────────────────

// flatj — flat blue, cream "j". As simple as it gets.
func conceptFlatJ(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircleFlat(c, s, srgb(28, 126, 214))
    drawGlyphJ(c, s, color: srgb(252, 248, 240), fontFrac: 0.62)
    return c
}

// lines — flat blue, three cream "writing" lines. A quiet journal mark.
func conceptLines(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircleFlat(c, s, srgb(28, 126, 214))
    let cream = srgb(252, 248, 240)
    let lineH = s * 0.075
    let widths: [CGFloat] = [0.52, 0.52, 0.34]
    for (i, wf) in widths.enumerated() {
        let ly = s*0.60 - CGFloat(i)*s*0.16
        let r = CGRect(x: s*0.26, y: ly, width: s*wf, height: lineH)
        c.addPath(roundedRectPath(r, lineH/2)); c.setFillColor(cream); c.fillPath()
    }
    return c
}

// book — flat blue, one simple closed book (cream panel + spine stripe).
func conceptBook(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircleFlat(c, s, srgb(28, 126, 214))
    let bw = s*0.42, bh = s*0.50
    let r = CGRect(x: (s-bw)/2 + s*0.02, y: (s-bh)/2, width: bw, height: bh)
    c.addPath(roundedRectPath(r, s*0.04)); c.setFillColor(srgb(252, 248, 240)); c.fillPath()
    // spine
    let spine = CGRect(x: r.minX - s*0.055, y: r.minY, width: s*0.055, height: bh)
    c.addPath(roundedRectPath(spine, s*0.02)); c.setFillColor(srgb(255, 209, 102)); c.fillPath()
    return c
}

let concepts: [String: (CGFloat) -> CGContext] = [
    "bubble": conceptBubble, "pages": conceptPages, "ink": conceptInk, "glyph": conceptGlyph,
    "flatj": conceptFlatJ, "lines": conceptLines, "book": conceptBook,
]

func write(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
}

let arg = CommandLine.arguments.dropFirst().first ?? "preview"

if arg == "preview" {
    let dir = "/tmp/jibber-icons"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, fn) in concepts {
        write(fn(256).makeImage()!, "\(dir)/\(name).png")
        print("  \(dir)/\(name).png")
    }
} else if let fn = concepts[arg] {
    let targets: [(String, Int)] = [
        ("16-mac.png", 16), ("32-mac 1.png", 32), ("32-mac.png", 32), ("64-mac.png", 64),
        ("128-mac.png", 128), ("256-mac 1.png", 256), ("256-mac.png", 256),
        ("512-mac 1.png", 512), ("512-mac.png", 512), ("1024-mac.png", 1024),
        ("icon-ios-1024.png", 1024),
    ]
    var cache: [Int: CGImage] = [:]
    for (name, px) in targets {
        let img = cache[px] ?? fn(CGFloat(px)).makeImage()!
        cache[px] = img
        write(img, "\(outDir)/\(name)")
        print("  wrote \(name)")
    }
    print("Done (\(arg)).")
} else {
    print("Unknown concept '\(arg)'. Options: preview, \(concepts.keys.sorted().joined(separator: ", "))")
    exit(1)
}
