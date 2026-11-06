//
//  make_icon.swift
//  Wander — icon generator
//
//  One mark per theme, drawn in that theme's own palette and display face: the
//  wordmark's "w" over the masthead rule, in both appearances. Reads
//  `Resources/themes.json`, the same table the apps read, so an icon can never
//  drift from its theme.
//
//  Run: swift tools/make_icon.swift
//

import SwiftUI
import AppKit
import Foundation

let canvas: CGFloat = 42
let letterSize: CGFloat = 21

struct ThemeSpec {
    let id: String
    let ground: Color
    let ink: Color
    let accent: Color
    let edge: Color
    let families: [String]
    let uppercase: Bool
}

/// Decode just the parts of themes.json the mark needs.
func loadThemes() -> [(light: ThemeSpec, dark: ThemeSpec)] {
    struct Document: Decodable { let themes: [Entry] }
    struct Entry: Decodable {
        let id: String
        let type: TypeSpec
        let light: [String: String]
        let dark: [String: String]
    }
    struct TypeSpec: Decodable { let display: FaceEntry }
    struct FaceEntry: Decodable { let families: [String]; let uppercase: Bool? }

    let url = URL(fileURLWithPath: "Resources/themes.json")
    guard let data = try? Data(contentsOf: url),
          let document = try? JSONDecoder().decode(Document.self, from: data) else {
        fatalError("Resources/themes.json not readable — run from the repo root")
    }
    func color(_ hex: String?) -> Color {
        let digits = (hex ?? "#000000").dropFirst()
        let value = UInt32(digits, radix: 16) ?? 0
        return Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
    return document.themes.map { entry in
        let families = entry.type.display.families
        let upper = entry.type.display.uppercase ?? false
        return (light: ThemeSpec(id: entry.id, ground: color(entry.light["paper"]),
                                 ink: color(entry.light["ink"]), accent: color(entry.light["accent"]),
                                 edge: color(entry.light["rule"]), families: families, uppercase: upper),
                dark: ThemeSpec(id: entry.id, ground: color(entry.dark["paper"]),
                                ink: color(entry.dark["ink"]), accent: color(entry.dark["accent"]),
                                edge: color(entry.dark["rule"]), families: families, uppercase: upper))
    }
}

struct Mark: View {
    let spec: ThemeSpec
    var masked: Bool = false

    private var face: Font {
        if let family = spec.families.first,
           NSFontManager.shared.availableFontFamilies.contains(family) {
            return .custom(family, fixedSize: masked ? letterSize * 0.92 : letterSize).weight(.semibold)
        }
        return .system(size: masked ? letterSize * 0.92 : letterSize, weight: .semibold, design: .serif)
    }

    var body: some View {
        let inset = masked ? 0 : canvas * 0.085
        let side = canvas - inset * 2
        let radius = masked ? 0 : side * 0.225

        ZStack {
            if masked {
                Rectangle().fill(spec.ground)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(spec.ground)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(spec.edge, lineWidth: canvas * 0.006)
                    }
                    .frame(width: side, height: side)
            }

            Text(spec.uppercase ? "W" : "w")
                .font(face)
                .foregroundStyle(spec.ink)
                .offset(y: -side * 0.055)

            Rectangle()
                .fill(spec.accent)
                .frame(width: side * 0.42, height: side * 0.05)
                .offset(y: side * 0.27)
        }
        .frame(width: canvas, height: canvas)
    }
}

@MainActor
func png(_ spec: ThemeSpec, pixels: CGFloat, masked: Bool = false) -> Data {
    let renderer = ImageRenderer(content: Mark(spec: spec, masked: masked))
    renderer.scale = pixels / canvas
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("render failed")
    }
    return data
}

/// iOS wants an opaque square with no alpha; it applies its own mask.
@MainActor
func flatPNG(_ spec: ThemeSpec, pixels: Int) -> Data? {
    let renderer = ImageRenderer(content: Mark(spec: spec, masked: true))
    renderer.scale = CGFloat(pixels) / canvas
    guard let rendered = renderer.cgImage,
          let context = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let full = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    context.setFillColor(NSColor(spec.ground).cgColor)
    context.fill(full)
    context.draw(rendered, in: full)
    guard let flattened = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: flattened).representation(using: .png, properties: [:])
}

/// One app icon set, with both appearances baked in: the theme's light mark,
/// and the dark mark iOS shows when the home screen is in its dark appearance.
/// Without the dark image the system derives one by darkening the light art
/// wholesale — which sinks a near-black "w" into a near-black ground. Both are
/// opaque, because a theme's paper is part of the mark rather than a backdrop
/// for the system to supply.
@MainActor
func writeAppIconSet(named name: String, light: ThemeSpec, dark: ThemeSpec,
                     in catalog: URL,
                     lightFile: String = "icon.png",
                     darkFile: String = "icon-dark.png") throws {
    let set = catalog.appendingPathComponent("\(name).appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    guard let lightData = flatPNG(light, pixels: 1024),
          let darkData = flatPNG(dark, pixels: 1024) else { fatalError("render failed: \(name)") }
    try lightData.write(to: set.appendingPathComponent(lightFile))
    try darkData.write(to: set.appendingPathComponent(darkFile))
    try """
    {
      "images" : [
        {
          "filename" : "\(lightFile)",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        },
        {
          "appearances" : [
            {
              "appearance" : "luminosity",
              "value" : "dark"
            }
          ],
          "filename" : "\(darkFile)",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "make_icon.swift",
        "version" : 1
      }
    }

    """.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

@MainActor
func main() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath)
    let resources = root.appendingPathComponent("Resources")
    let icons = resources.appendingPathComponent("Icons")
    try? fm.createDirectory(at: icons, withIntermediateDirectories: true)

    // The bundled faces have to be registered before anything is drawn in them.
    let fontDir = resources.appendingPathComponent("Fonts")
    if let files = try? fm.contentsOfDirectory(at: fontDir, includingPropertiesForKeys: nil) {
        CTFontManagerRegisterFontURLs(files.filter { $0.pathExtension == "ttf" } as CFArray,
                                      .process, true, nil)
    }

    let themes = loadThemes()
    let catalog = resources.appendingPathComponent("Assets.xcassets")
    // The first theme is the app's own: it becomes AppIcon, the primary icon,
    // so it is not also written as an alternate no one can ask for.
    let primary = themes.first?.light.id
    for (light, dark) in themes {
        // macOS: the Dock swaps these as the theme and appearance change.
        try png(light, pixels: 512).write(to: icons.appendingPathComponent("\(light.id)-light.png"))
        try png(dark, pixels: 512).write(to: icons.appendingPathComponent("\(dark.id)-dark.png"))
        // iOS: an alternate icon set per theme, named as AppIconSwitcher asks.
        guard light.id != primary else { continue }
        try writeAppIconSet(named: "wander-\(light.id)", light: light, dark: dark, in: catalog)
    }
    print("wrote \(themes.count * 2) dock icons and \(themes.count - 1) alternate iOS icon sets")

    // The default marks, still in the almanac palette.
    guard let almanac = themes.first else { return }
    try png(almanac.light, pixels: 1024).write(to: resources.appendingPathComponent("AppIcon-light.png"))
    try png(almanac.dark, pixels: 1024).write(to: resources.appendingPathComponent("AppIcon-dark.png"))
    try writeAppIconSet(named: "AppIcon", light: almanac.light, dark: almanac.dark, in: catalog,
                        lightFile: "icon-1024.png", darkFile: "icon-1024-dark.png")

    let tauriIcons = root.appendingPathComponent("tauri/src-tauri/icons")
    try? fm.createDirectory(at: tauriIcons, withIntermediateDirectories: true)
    for (name, pixels) in [("32x32.png", 32), ("128x128.png", 128),
                           ("128x128@2x.png", 256), ("icon.png", 512)] {
        try png(almanac.light, pixels: CGFloat(pixels))
            .write(to: tauriIcons.appendingPathComponent(name))
    }

    let iconset = root.appendingPathComponent("build/AppIcon.iconset")
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 1 ? "" : "@2x"
            try png(almanac.light, pixels: CGFloat(base * scale))
                .write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
        }
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path,
                          "-o", resources.appendingPathComponent("AppIcon.icns").path]
    try iconutil.run()
    iconutil.waitUntilExit()
    try? fm.copyItem(at: resources.appendingPathComponent("AppIcon.icns"),
                     to: tauriIcons.appendingPathComponent("icon.icns"))
    print("wrote the default marks, the icns and the Tauri icon set")
}

try MainActor.assumeIsolated { try main() }
