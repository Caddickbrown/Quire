//
//  make_icon.swift — renders Nook's app icon.
//
//  Usage:
//    swift tools/make_icon.swift preview     → render every concept at 256px to /tmp/nook-icons/
//    swift tools/make_icon.swift <concept>   → render the chosen concept at ALL sizes into the appiconset
//
//  Concepts: bubble | pages | ink | glyph | … (see `concepts` at the bottom)
//
//  A concept with a companion `<name>-dark` entry also renders that one to
//  icon-ios-1024-dark.png — the iOS 18 dark-appearance variant, wired up by the
//  `appearances` entry in the appiconset's Contents.json.
//

import AppKit
import CoreText
import CoreGraphics
import Foundation

let outDir = "Nook/Assets.xcassets/AppIcon.appiconset"

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

/// When true, backgrounds fill the whole canvas with no margin or self-rounding.
/// iOS masks the icon to its own superellipse, so an inset+rounded background
/// leaves a transparent border ring; iOS icons must be full-bleed. macOS icons
/// keep the inset+rounded look (Apple's icon grid expects padding).
var fullBleed = false

/// Background squircle filled with a vertical gradient; returns the clip rect.
@discardableResult
func squircle(_ c: CGContext, _ s: CGFloat, _ top: CGColor, _ bottom: CGColor) -> CGRect {
    let margin = fullBleed ? 0 : s * 0.085
    let rect = CGRect(x: margin, y: margin, width: s - 2*margin, height: s - 2*margin)
    let radius = fullBleed ? 0 : rect.width * 0.225
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

// ── Concept: bubble ── speech bubble + writing lines (nook = talk + journal) ──
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
    let margin = fullBleed ? 0 : s * 0.085
    let rect = CGRect(x: margin, y: margin, width: s - 2*margin, height: s - 2*margin)
    let radius = fullBleed ? 0 : rect.width * 0.225
    c.addPath(roundedRectPath(rect, radius)); c.setFillColor(color); c.fillPath()
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

// ── Whimsical concepts ──────────────────────────────────────────────────────

/// Fill a closed path built by `build` with `color`.
func fill(_ c: CGContext, _ color: CGColor, _ build: (CGContext) -> Void) {
    c.beginPath(); build(c); c.setFillColor(color); c.fillPath()
}

// cat — a cat curled up asleep in its nook. Cozy + a little whimsical.
func conceptCat(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircle(c, s, srgb(255, 178, 112), srgb(240, 120, 96))   // warm peach → coral
    let fur   = srgb(60, 54, 78)          // deep plum "cat"
    let tail  = srgb(96, 88, 120)          // lighter fur so the tail reads
    let blush = srgb(255, 176, 150)
    let cx = s/2, cy = s*0.52

    // Curled body — a fat oval.
    fill(c, fur) { g in
        g.addEllipse(in: CGRect(x: cx - s*0.30, y: cy - s*0.22, width: s*0.60, height: s*0.44))
    }
    // Tail wrapping across the front of the body (lighter tone, curls to a tip).
    c.saveGState()
    c.setStrokeColor(tail); c.setLineCap(.round); c.setLineWidth(s*0.065)
    c.move(to: CGPoint(x: cx + s*0.26, y: cy + s*0.02))
    c.addCurve(to: CGPoint(x: cx - s*0.02, y: cy - s*0.17),
               control1: CGPoint(x: cx + s*0.30, y: cy - s*0.22),
               control2: CGPoint(x: cx + s*0.12, y: cy - s*0.24))
    c.strokePath()
    c.restoreGState()

    // Head resting on the body (upper-left).
    let hx = cx - s*0.13, hy = cy + s*0.13, hr = s*0.135
    fill(c, fur) { g in g.addEllipse(in: CGRect(x: hx - hr, y: hy - hr, width: hr*2, height: hr*2)) }
    // Ears (two triangles).
    for dx in [-1.0, 1.0] as [CGFloat] {
        fill(c, fur) { g in
            let ex = hx + dx*hr*0.62
            g.move(to: CGPoint(x: ex - hr*0.34, y: hy + hr*0.55))
            g.addLine(to: CGPoint(x: ex + hr*0.06, y: hy + hr*1.15))
            g.addLine(to: CGPoint(x: ex + hr*0.42, y: hy + hr*0.5))
            g.closePath()
        }
    }
    // Closed, content eye — a downward arc.
    c.setStrokeColor(srgb(252, 248, 240)); c.setLineWidth(s*0.016); c.setLineCap(.round)
    c.move(to: CGPoint(x: hx - hr*0.55, y: hy + hr*0.10))
    c.addQuadCurve(to: CGPoint(x: hx - hr*0.05, y: hy + hr*0.10),
                   control: CGPoint(x: hx - hr*0.30, y: hy - hr*0.18))
    c.strokePath()
    // Blush cheek + tiny nose.
    fill(c, blush) { g in g.addEllipse(in: CGRect(x: hx - hr*0.62, y: hy - hr*0.34, width: hr*0.5, height: hr*0.34)) }
    fill(c, blush) { g in g.addEllipse(in: CGRect(x: hx - hr*0.14, y: hy - hr*0.06, width: hr*0.28, height: hr*0.20)) }
    return c
}

// moon — a sleepy crescent moon over a little book. Bedtime journaling.
func conceptMoon(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircle(c, s, srgb(94, 108, 210), srgb(52, 46, 120))      // dusk indigo
    let cream = srgb(252, 244, 214)

    // Crescent = big disc minus an offset disc.
    let mx = s*0.56, my = s*0.60, mr = s*0.22
    c.saveGState()
    fill(c, cream) { g in g.addEllipse(in: CGRect(x: mx - mr, y: my - mr, width: mr*2, height: mr*2)) }
    c.setBlendMode(.destinationOut)
    fill(c, srgb(0,0,0)) { g in
        g.addEllipse(in: CGRect(x: mx - mr*0.55, y: my - mr*0.35, width: mr*2, height: mr*2))
    }
    c.restoreGState()

    // A couple of little stars.
    for (px, py, pr) in [(0.30, 0.72, 0.018), (0.72, 0.30, 0.014), (0.24, 0.44, 0.011)] as [(CGFloat,CGFloat,CGFloat)] {
        fill(c, cream) { g in g.addEllipse(in: CGRect(x: s*px - s*pr, y: s*py - s*pr, width: s*pr*2, height: s*pr*2)) }
    }

    // Small open book resting at the bottom.
    let bw = s*0.34, bh = s*0.12, bx = (s-bw)/2, by = s*0.24
    for sign in [-1.0, 1.0] as [CGFloat] {
        fill(c, cream) { g in
            let x0 = sign<0 ? bx : s/2
            g.move(to: CGPoint(x: sign<0 ? bx : s/2 + bw/2, y: by))
            g.addQuadCurve(to: CGPoint(x: x0 + (sign<0 ? 0 : bw/2), y: by + bh),
                           control: CGPoint(x: s/2, y: by + bh*0.4))
            g.addLine(to: CGPoint(x: s/2, y: by + bh*0.72))
            g.addLine(to: CGPoint(x: s/2, y: by))
            g.closePath()
        }
    }
    return c
}

// star — a friendly shooting star with a little face, on twilight.
func conceptStar(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircle(c, s, srgb(120, 96, 235), srgb(70, 52, 160))
    let gold = srgb(255, 214, 120)
    let cx = s*0.54, cy = s*0.54, R = s*0.24, r = R*0.42

    // Five-point star.
    fill(c, gold) { g in
        for i in 0..<10 {
            let rad = i.isMultiple(of: 2) ? R : r
            let a = CGFloat(i) * .pi/5 + .pi/2
            let p = CGPoint(x: cx + rad*cos(a), y: cy + rad*sin(a))
            if i == 0 { g.move(to: p) } else { g.addLine(to: p) }
        }
        g.closePath()
    }
    // Trailing sparkle tail.
    c.setStrokeColor(srgb(255, 236, 190, 0.9)); c.setLineCap(.round); c.setLineWidth(s*0.03)
    c.move(to: CGPoint(x: cx - R*0.7, y: cy - R*0.7))
    c.addLine(to: CGPoint(x: cx - R*1.9, y: cy - R*1.9))
    c.strokePath()
    // Happy little face: two eyes + a smile.
    let ink = srgb(70, 52, 120)
    for dx in [-1.0, 1.0] as [CGFloat] {
        fill(c, ink) { g in g.addEllipse(in: CGRect(x: cx + dx*R*0.22 - R*0.05, y: cy + R*0.06, width: R*0.10, height: R*0.14)) }
    }
    c.setStrokeColor(ink); c.setLineWidth(s*0.016); c.setLineCap(.round)
    c.move(to: CGPoint(x: cx - R*0.20, y: cy - R*0.06))
    c.addQuadCurve(to: CGPoint(x: cx + R*0.20, y: cy - R*0.06), control: CGPoint(x: cx, y: cy - R*0.24))
    c.strokePath()
    return c
}

// bookface — a cheerful open book with a little smiling face. Journaling, but happy.
func conceptBookFace(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircle(c, s, srgb(46, 196, 182), srgb(28, 150, 200))     // fresh teal
    let cream = srgb(252, 248, 240)
    let cx = s/2, cy = s*0.50
    let pw = s*0.30, ph = s*0.34, gap = s*0.018

    // Two page panels, tops fanned slightly outward like an open book.
    for sign in [-1.0, 1.0] as [CGFloat] {
        c.saveGState()
        // slight rotation about the spine so the book looks "open"
        c.translateBy(x: cx, y: cy); c.rotate(by: sign * -0.06); c.translateBy(x: -cx, y: -cy)
        let r = CGRect(x: cx + (sign<0 ? -pw - gap : gap), y: cy - ph/2, width: pw, height: ph)
        fill(c, cream) { g in g.addPath(roundedRectPath(r, s*0.03)) }
        // ruled lines on each page
        c.setStrokeColor(srgb(28, 150, 200, 0.5)); c.setLineWidth(s*0.011); c.setLineCap(.round)
        for i in 0..<3 {
            let ly = r.maxY - ph*0.30 - CGFloat(i)*ph*0.22
            c.move(to: CGPoint(x: r.minX + pw*0.16, y: ly)); c.addLine(to: CGPoint(x: r.maxX - pw*0.16, y: ly)); c.strokePath()
        }
        c.restoreGState()
    }
    // Spine
    fill(c, srgb(255, 209, 102)) { g in g.addPath(roundedRectPath(CGRect(x: cx - gap, y: cy - ph/2 - s*0.008, width: gap*2, height: ph + s*0.016), gap)) }

    // Little smiling face floating above, like the book is telling a story.
    let fy = cy + ph*0.62
    for dx in [-1.0, 1.0] as [CGFloat] {
        fill(c, cream) { g in g.addEllipse(in: CGRect(x: cx + dx*s*0.075 - s*0.018, y: fy, width: s*0.036, height: s*0.05)) }
    }
    c.setStrokeColor(cream); c.setLineWidth(s*0.02); c.setLineCap(.round)
    c.move(to: CGPoint(x: cx - s*0.06, y: fy - s*0.005))
    c.addQuadCurve(to: CGPoint(x: cx + s*0.06, y: fy - s*0.005), control: CGPoint(x: cx, y: fy - s*0.06))
    c.strokePath()
    return c
}

// pencil — a friendly pencil character mid-doodle, on warm paper.
func conceptPencil(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircle(c, s, srgb(255, 196, 92), srgb(245, 150, 70))      // sunny amber
    let cx = s/2, cy = s/2
    let bodyW = s*0.22, bodyLen = s*0.46
    let yellow = srgb(252, 224, 120), wood = srgb(240, 214, 168)
    let lead = srgb(70, 62, 84), pink = srgb(244, 138, 150), band = srgb(190, 200, 210)

    // Draw the pencil tilted, pointing down-right.
    c.saveGState()
    c.translateBy(x: cx, y: cy); c.rotate(by: -0.62); c.translateBy(x: -cx, y: -cy)
    let bx = cx - bodyW/2
    let topY = cy + bodyLen*0.36
    // Barrel
    fill(c, yellow) { g in g.addPath(roundedRectPath(CGRect(x: bx, y: cy - bodyLen*0.42, width: bodyW, height: bodyLen*0.72), s*0.02)) }
    // Eraser + metal band at top
    fill(c, pink) { g in g.addPath(roundedRectPath(CGRect(x: bx, y: topY - bodyLen*0.02, width: bodyW, height: bodyLen*0.12), s*0.03)) }
    fill(c, band) { g in g.addRect(CGRect(x: bx, y: topY - bodyLen*0.06, width: bodyW, height: bodyLen*0.045)) }
    // Wooden tip (triangle) + lead point
    let tipY = cy - bodyLen*0.42
    fill(c, wood) { g in
        g.move(to: CGPoint(x: bx, y: tipY)); g.addLine(to: CGPoint(x: bx + bodyW, y: tipY))
        g.addLine(to: CGPoint(x: bx + bodyW/2, y: tipY - bodyLen*0.20)); g.closePath()
    }
    fill(c, lead) { g in
        g.move(to: CGPoint(x: bx + bodyW*0.34, y: tipY - bodyLen*0.128))
        g.addLine(to: CGPoint(x: bx + bodyW*0.66, y: tipY - bodyLen*0.128))
        g.addLine(to: CGPoint(x: bx + bodyW/2, y: tipY - bodyLen*0.20)); g.closePath()
    }
    // Face on the barrel: two eyes + a smile.
    let fy = cy + bodyLen*0.02
    for dx in [-1.0, 1.0] as [CGFloat] {
        fill(c, lead) { g in g.addEllipse(in: CGRect(x: cx + dx*bodyW*0.24 - bodyW*0.07, y: fy, width: bodyW*0.14, height: bodyW*0.2)) }
    }
    c.setStrokeColor(lead); c.setLineWidth(s*0.014); c.setLineCap(.round)
    c.move(to: CGPoint(x: cx - bodyW*0.22, y: fy - bodyW*0.02))
    c.addQuadCurve(to: CGPoint(x: cx + bodyW*0.22, y: fy - bodyW*0.02), control: CGPoint(x: cx, y: fy - bodyW*0.28))
    c.strokePath()
    c.restoreGState()

    // A little doodle squiggle the pencil just drew, at bottom-left.
    c.setStrokeColor(srgb(252, 248, 240)); c.setLineWidth(s*0.022); c.setLineCap(.round)
    c.move(to: CGPoint(x: s*0.24, y: s*0.30))
    c.addCurve(to: CGPoint(x: s*0.44, y: s*0.28),
               control1: CGPoint(x: s*0.30, y: s*0.40), control2: CGPoint(x: s*0.38, y: s*0.18))
    c.strokePath()
    return c
}

// ── "Professional whimsy" concepts — refined mark, one playful flourish ──────

// nib — a fountain-pen nib with a graceful ink flourish curling off the tip.
func conceptNib(_ s: CGFloat) -> CGContext {
    let c = ctx(Int(s))
    squircle(c, s, srgb(58, 72, 102), srgb(34, 44, 70))        // muted slate-navy
    let gold  = srgb(226, 190, 108)
    let cream = srgb(250, 246, 236)
    let cx = s*0.5
    let tipY = s*0.30, topY = s*0.74, halfW = s*0.115
    let holeY = s*0.575

    // Nib body: a slim leaf — near-straight sides tapering to a fine point,
    // with softly rounded shoulders at the top.
    fill(c, gold) { g in
        g.move(to: CGPoint(x: cx, y: tipY))
        g.addQuadCurve(to: CGPoint(x: cx - halfW, y: topY - s*0.08), control: CGPoint(x: cx - halfW*0.62, y: (tipY+topY)/2))
        g.addQuadCurve(to: CGPoint(x: cx, y: topY),                  control: CGPoint(x: cx - halfW*0.85, y: topY))
        g.addQuadCurve(to: CGPoint(x: cx + halfW, y: topY - s*0.08), control: CGPoint(x: cx + halfW*0.85, y: topY))
        g.addQuadCurve(to: CGPoint(x: cx, y: tipY),                  control: CGPoint(x: cx + halfW*0.62, y: (tipY+topY)/2))
        g.closePath()
    }
    // Breather hole.
    fill(c, srgb(34, 44, 70)) { g in g.addEllipse(in: CGRect(x: cx - s*0.026, y: holeY, width: s*0.052, height: s*0.052)) }
    // Center slit from breather hole to tip.
    c.setStrokeColor(srgb(34, 44, 70)); c.setLineWidth(s*0.014); c.setLineCap(.round)
    c.move(to: CGPoint(x: cx, y: holeY)); c.addLine(to: CGPoint(x: cx, y: tipY + s*0.015)); c.strokePath()

    // Ink flourish trailing from the tip — the whimsy.
    c.setStrokeColor(cream); c.setLineCap(.round); c.setLineJoin(.round); c.setLineWidth(s*0.026)
    c.move(to: CGPoint(x: cx, y: tipY))
    c.addCurve(to: CGPoint(x: s*0.35, y: s*0.235),
               control1: CGPoint(x: cx, y: s*0.25), control2: CGPoint(x: s*0.41, y: s*0.25))
    c.addCurve(to: CGPoint(x: s*0.67, y: s*0.225),
               control1: CGPoint(x: s*0.30, y: s*0.215), control2: CGPoint(x: s*0.60, y: s*0.29))
    c.strokePath()
    return c
}

// ribbon — a clean closed journal with a satin bookmark that curls playfully.
//
// Two palettes, one geometry: `light` is the shipping icon (cream journal on
// sage-teal), `dark` is the iOS dark-appearance variant (green journal on
// near-black). Keep them sharing this function — a second copy would drift.
struct RibbonPalette {
    let bgTop: CGColor, bgBottom: CGColor
    let cover: CGColor, frame: CGColor
    let ribbon: CGColor, ribbonHi: CGColor

    static let light = RibbonPalette(
        bgTop:    srgb(70, 150, 128), bgBottom: srgb(44, 112, 96),   // muted sage-teal
        cover:    srgb(250, 246, 236),                               // paper cream
        frame:    srgb(44, 112, 96, 0.35),
        ribbon:   srgb(214, 96, 92),  ribbonHi: srgb(232, 132, 126)) // warm coral

    static let dark = RibbonPalette(
        bgTop:    srgb(30, 36, 34),   bgBottom: srgb(14, 18, 17),    // near-black, faintly green
        cover:    srgb(78, 168, 130),                                // green cover
        frame:    srgb(20, 62, 46, 0.55),
        ribbon:   srgb(226, 112, 104), ribbonHi: srgb(240, 148, 140))
}

func conceptRibbon(_ s: CGFloat, _ p: RibbonPalette) -> CGContext {
    let c = ctx(Int(s))
    squircle(c, s, p.bgTop, p.bgBottom)
    let cx = s/2
    let bw = s*0.44, bh = s*0.54
    let r = CGRect(x: cx - bw/2, y: (s-bh)/2, width: bw, height: bh)

    // Cover.
    fill(c, p.cover) { g in g.addPath(roundedRectPath(r, s*0.045)) }
    // Subtle inset frame line (bookbinding detail).
    c.setStrokeColor(p.frame); c.setLineWidth(s*0.01)
    c.addPath(roundedRectPath(r.insetBy(dx: s*0.045, dy: s*0.045), s*0.03)); c.strokePath()

    // Satin ribbon bookmark: tucked over the top edge, down the right third,
    // out past the bottom where the tail flicks up in a soft curl (the whimsy).
    let rw = s*0.05
    let rx = r.minX + bw*0.66
    // Straight run from just over the top edge down to just below the bottom edge.
    fill(c, p.ribbon) { g in
        g.addRect(CGRect(x: rx, y: r.minY - s*0.015, width: rw, height: bh + s*0.03))
    }
    // Soft flick at the tail.
    c.setStrokeColor(p.ribbon); c.setLineCap(.round); c.setLineJoin(.round); c.setLineWidth(rw)
    c.move(to: CGPoint(x: rx + rw/2, y: r.minY - s*0.015))
    c.addQuadCurve(to: CGPoint(x: rx + rw/2 + s*0.055, y: r.minY - s*0.075),
                   control: CGPoint(x: rx + rw/2 + s*0.02, y: r.minY - s*0.02))
    c.strokePath()
    // Thin satin highlight stripe down the ribbon.
    c.setStrokeColor(p.ribbonHi); c.setLineWidth(s*0.012); c.setLineCap(.round)
    c.move(to: CGPoint(x: rx + rw*0.34, y: r.maxY + s*0.01))
    c.addLine(to: CGPoint(x: rx + rw*0.34, y: r.minY + s*0.02))
    c.strokePath()
    return c
}

let concepts: [String: (CGFloat) -> CGContext] = [
    "bubble": conceptBubble, "pages": conceptPages, "ink": conceptInk, "glyph": conceptGlyph,
    "flatj": conceptFlatJ, "lines": conceptLines, "book": conceptBook,
    "cat": conceptCat, "moon": conceptMoon, "star": conceptStar,
    "bookface": conceptBookFace, "pencil": conceptPencil,
    "nib": conceptNib,
    "ribbon": { conceptRibbon($0, .light) },
    "ribbon-dark": { conceptRibbon($0, .dark) },
]

func write(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
}

let arg = CommandLine.arguments.dropFirst().first ?? "preview"

if arg == "preview" {
    let dir = "/tmp/nook-icons"
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
    // iOS icons must be full-bleed; macOS icons keep the inset+rounded look.
    // Cache is keyed by (px, fullBleed) since both platforms share px=1024.
    var cache: [String: CGImage] = [:]
    for (name, px) in targets {
        fullBleed = name.hasPrefix("icon-ios")
        let key = "\(px)-\(fullBleed)"
        let img = cache[key] ?? fn(CGFloat(px)).makeImage()!
        cache[key] = img
        write(img, "\(outDir)/\(name)")
        print("  wrote \(name)\(fullBleed ? " (full-bleed)" : "")")
    }
    // Dark-appearance variant (iOS 18+): one full-bleed 1024 next to the light
    // icon, referenced from Contents.json by an `appearances` entry. macOS
    // appiconsets have no dark slot, so this is iOS-only by design.
    if let darkFn = concepts["\(arg)-dark"] {
        fullBleed = true
        write(darkFn(1024).makeImage()!, "\(outDir)/icon-ios-1024-dark.png")
        print("  wrote icon-ios-1024-dark.png (full-bleed, dark appearance)")
    }
    fullBleed = false
    print("Done (\(arg)).")
} else {
    print("Unknown concept '\(arg)'. Options: preview, \(concepts.keys.sorted().joined(separator: ", "))")
    exit(1)
}
