// Quire's app icon: "A · The gathering" from the design canvas — nested sheets
// on one spine, the tail making a Q. Writes the whole AppIcon.appiconset.
//
//   swift tools/make_apple_icon.swift apple/Quire/Assets.xcassets/AppIcon.appiconset
//
// iOS gets a full-bleed square (the system rounds it), light and dark. macOS
// gets the rounded plate on a transparent canvas, with the simpler two-sheet
// mark at 64 px and below, as on the canvas.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Look { let plate: UInt32; let stroke: UInt32 }
let almanac = Look(plate: 0x8E2F1C, stroke: 0xF7F1E4)
let cinema = Look(plate: 0x16130F, stroke: 0xE08A6B)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

/// The mark in the canvas's 100×100 space, nudged so its box centres on 50,50.
func drawMark(_ c: CGContext, simple: Bool, stroke: UInt32) {
    c.setStrokeColor(color(stroke))
    c.setLineWidth(simple ? 6 : 4.2)
    c.setLineCap(.round)
    c.translateBy(x: -6, y: -3)
    func curve(_ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ y3: CGFloat) {
        c.move(to: CGPoint(x: 36, y: y0))
        c.addCurve(to: CGPoint(x: 36, y: y3), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
        c.strokePath()
    }
    curve(24, 76, 24, 76, 76, 76)
    if simple { curve(38, 60, 38, 60, 62, 62) } else {
        curve(34, 64, 34, 64, 66, 66)
        curve(44, 52, 44, 52, 56, 56)
    }
    c.move(to: CGPoint(x: 36, y: 24)); c.addLine(to: CGPoint(x: 36, y: 76)); c.strokePath()
    c.move(to: CGPoint(x: 58, y: 66)); c.addLine(to: CGPoint(x: 76, y: 82)); c.strokePath()
}

func render(size: Int, look: Look, mac: Bool, to url: URL) {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, like the canvas.
    c.translateBy(x: 0, y: s); c.scaleBy(x: 1, y: -1)
    let plate = mac ? s * 824 / 1024 : s
    let origin = (s - plate) / 2
    c.saveGState()
    c.translateBy(x: origin, y: origin)
    if mac {
        let radius = plate * 0.2237
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: plate, height: plate),
                         cornerWidth: radius, cornerHeight: radius, transform: nil))
        c.clip()
    }
    c.setFillColor(color(look.plate))
    c.fill(CGRect(x: 0, y: 0, width: plate, height: plate))
    c.scaleBy(x: plate / 100, y: plate / 100)
    drawMark(c, simple: mac && size <= 64, stroke: look.stroke)
    c.restoreGState()
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_apple_icon.swift <AppIcon.appiconset>\n".utf8)); exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
render(size: 1024, look: almanac, mac: false, to: out.appendingPathComponent("icon-ios-1024.png"))
render(size: 1024, look: cinema, mac: false, to: out.appendingPathComponent("icon-ios-1024-dark.png"))
// The names Contents.json already points at.
let macFiles: [(String, Int)] = [
    ("16-mac.png", 16), ("32-mac 1.png", 32), ("32-mac.png", 32), ("64-mac.png", 64),
    ("128-mac.png", 128), ("256-mac 1.png", 256), ("256-mac.png", 256), ("512-mac 1.png", 512),
    ("512-mac.png", 512), ("1024-mac.png", 1024),
]
for (name, size) in macFiles { render(size: size, look: almanac, mac: true, to: out.appendingPathComponent(name)) }
print("wrote \(2 + macFiles.count) icons to \(out.path)")
