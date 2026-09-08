//
//  make_icon.swift
//  Wander — icon generator
//
//  The mark is the masthead: a paper square, the wordmark's "w", one terracotta
//  rule. It is drawn through SwiftUI's own ImageRenderer with the same
//  `.system(design: .serif)` font the masthead uses, at the same point size —
//  AppKit's NSFont path kept picking a different weight and, at 1024pt, New
//  York's display cut, so the icon's letter never quite matched the window's.
//  Rendering small and scaling the raster keeps the text cut.
//
//  Run: swift tools/make_icon.swift
//

import SwiftUI
import AppKit
import Foundation

/// Logical canvas. The letter is sized in the same points as the masthead's
/// wordmark, so the optical size Core Text picks is the same one.
let canvas: CGFloat = 42
let letterSize: CGFloat = 21

struct Palette {
    let ground: Color
    let ink: Color
    let accent: Color
    let edge: Color
}

let light = Palette(ground: Color(red: 0.965, green: 0.949, blue: 0.918),
                    ink:    Color(red: 0.090, green: 0.075, blue: 0.063),
                    accent: Color(red: 0.612, green: 0.196, blue: 0.125),
                    edge:   Color(red: 0.867, green: 0.835, blue: 0.780))

let dark = Palette(ground: Color(red: 0.086, green: 0.075, blue: 0.059),
                   ink:    Color(red: 0.949, green: 0.925, blue: 0.878),
                   accent: Color(red: 0.800, green: 0.416, blue: 0.298),
                   edge:   Color(red: 0.204, green: 0.176, blue: 0.141))

struct Mark: View {
    let palette: Palette

    var body: some View {
        let inset = canvas * 0.085
        let side = canvas - inset * 2
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .fill(palette.ground)
                .overlay {
                    RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                        .strokeBorder(palette.edge, lineWidth: canvas * 0.006)
                }
                .frame(width: side, height: side)

            // Placed rather than stacked: a VStack centres the pair, which
            // walks the rule off the bottom of the square as the letter grows.
            Text("w")
                .font(.system(size: letterSize, weight: .semibold, design: .serif))
                .foregroundStyle(palette.ink)
                .offset(y: -side * 0.055)

            Rectangle()
                .fill(palette.accent)
                .frame(width: side * 0.42, height: side * 0.05)
                .offset(y: side * 0.27)
        }
        .frame(width: canvas, height: canvas)
    }
}

@MainActor
func png(_ palette: Palette, pixels: CGFloat) -> Data {
    let renderer = ImageRenderer(content: Mark(palette: palette))
    renderer.scale = pixels / canvas
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("render failed at \(pixels)px")
    }
    return data
}

@MainActor
func main() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath)
    let resources = root.appendingPathComponent("Resources")
    try? fm.createDirectory(at: resources, withIntermediateDirectories: true)

    for (name, palette) in [("AppIcon-light", light), ("AppIcon-dark", dark)] {
        try png(palette, pixels: 1024).write(to: resources.appendingPathComponent("\(name).png"))
        print("wrote Resources/\(name).png")
    }

    let iconset = root.appendingPathComponent("build/AppIcon.iconset")
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 1 ? "" : "@2x"
            try png(light, pixels: CGFloat(base * scale))
                .write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
        }
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path,
                          "-o", resources.appendingPathComponent("AppIcon.icns").path]
    try iconutil.run()
    iconutil.waitUntilExit()
    print("wrote Resources/AppIcon.icns")

    // iOS wants a single flat 1024 with no alpha; the platform applies its own
    // mask, so the square is drawn edge to edge there.
    let iosRenderer = ImageRenderer(content: Mark(palette: light).frame(width: canvas, height: canvas))
    iosRenderer.scale = 1024 / canvas
    if let image = iosRenderer.nsImage, let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: resources.appendingPathComponent("AppIcon-ios.png"))
        print("wrote Resources/AppIcon-ios.png")
    }
}

try MainActor.assumeIsolated { try main() }
