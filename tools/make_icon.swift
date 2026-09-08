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

/// The mark. macOS draws its own rounded square, because a Mac icon is a shape
/// on a desktop; iOS is drawn edge to edge, because the platform masks it —
/// giving it a border of its own leaves a visible ring inside the mask.
struct Mark: View {
    let palette: Palette
    var masked: Bool = false

    var body: some View {
        let inset = masked ? 0 : canvas * 0.085
        let side = canvas - inset * 2
        let radius = masked ? 0 : side * 0.225

        ZStack {
            if masked {
                Rectangle().fill(palette.ground)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(palette.ground)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(palette.edge, lineWidth: canvas * 0.006)
                    }
                    .frame(width: side, height: side)
            }

            // Placed rather than stacked: a VStack centres the pair, which
            // walks the rule off the bottom of the square as the letter grows.
            Text("w")
                .font(.system(size: masked ? letterSize * 0.92 : letterSize,
                              weight: .semibold, design: .serif))
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
    // Linux and Windows don't mask the icon, so the Tauri bundle takes the same
    // rounded art the Mac does, in the sizes its bundler expects.
    let tauriIcons = root.appendingPathComponent("tauri/src-tauri/icons")
    try? fm.createDirectory(at: tauriIcons, withIntermediateDirectories: true)
    for (name, pixels) in [("32x32.png", 32), ("128x128.png", 128),
                           ("128x128@2x.png", 256), ("icon.png", 512)] {
        try png(light, pixels: CGFloat(pixels))
            .write(to: tauriIcons.appendingPathComponent(name))
    }
    print("wrote tauri/src-tauri/icons")

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path,
                          "-o", resources.appendingPathComponent("AppIcon.icns").path]
    try iconutil.run()
    iconutil.waitUntilExit()
    print("wrote Resources/AppIcon.icns")

    // The Tauri bundler wants an .icns for its macOS bundle too.
    try? fm.copyItem(at: resources.appendingPathComponent("AppIcon.icns"),
                     to: tauriIcons.appendingPathComponent("icon.icns"))

    // iOS masks the icon itself and rejects an alpha channel, so its art is
    // drawn edge to edge and written through an opaque CGContext.
    let iosPixels = 1024
    let renderer = ImageRenderer(content: Mark(palette: light, masked: true))
    renderer.scale = CGFloat(iosPixels) / canvas
    if let rendered = renderer.cgImage,
       let context = CGContext(data: nil, width: iosPixels, height: iosPixels,
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        let full = CGRect(x: 0, y: 0, width: iosPixels, height: iosPixels)
        context.setFillColor(NSColor(light.ground).cgColor)
        context.fill(full)
        context.draw(rendered, in: full)
        if let flattened = context.makeImage() {
            let rep = NSBitmapImageRep(cgImage: flattened)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: resources.appendingPathComponent("AppIcon-ios.png"))
                // Straight into the asset catalog as well: a copy step done by
                // hand is a copy step that ends up one revision behind.
                let iconset = resources
                    .appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon-1024.png")
                try? data.write(to: iconset)
                print("wrote Resources/AppIcon-ios.png and the app icon set")
            }
        }
    }
}

try MainActor.assumeIsolated { try main() }
