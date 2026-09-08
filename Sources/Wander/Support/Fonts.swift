//
//  Fonts.swift
//  Wander
//
//  The themes are largely made of type, so the faces they need ship with the
//  app rather than being hoped for: `Resources/Fonts` is registered with
//  CoreText at launch, on both platforms, and `Face` resolves a theme's
//  preferred family with a fallback that keeps the right *kind* of letter
//  (serif, sans, mono) when a family is somehow missing.
//

import SwiftUI
import CoreText

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

enum Fonts {
    private static var registered = false

    /// Register every face in the bundle's Fonts folder. Idempotent, and
    /// deliberately quiet: a font that fails to register falls back rather
    /// than stopping the app.
    static func register() {
        guard !registered else { return }
        registered = true
        guard let folder = Bundle.main.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil) else { return }
        let faces = files.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        guard !faces.isEmpty else { return }
        CTFontManagerRegisterFontURLs(faces as CFArray, .process, true, nil)
    }

    /// Families actually available, for the fallback check.
    static var installed: Set<String> = {
        #if canImport(AppKit)
        return Set(NSFontManager.shared.availableFontFamilies)
        #else
        return Set(UIFont.familyNames)
        #endif
    }()

    static func refreshInstalled() {
        #if canImport(AppKit)
        installed = Set(NSFontManager.shared.availableFontFamilies)
        #else
        installed = Set(UIFont.familyNames)
        #endif
    }
}

/// A face a theme asks for: the families it prefers, in order, and the shape to
/// fall back to when none of them is present.
struct FaceSpec: Equatable {
    enum Shape { case serif, sans, mono, rounded }

    var families: [String]
    var shape: Shape

    init(_ families: [String], shape: Shape) {
        self.families = families
        self.shape = shape
    }

    init(_ family: String, shape: Shape) {
        self.families = [family]
        self.shape = shape
    }

    /// The first family that is actually installed, or nil for the system face.
    var resolved: String? {
        families.first { Fonts.installed.contains($0) }
    }

    var design: Font.Design {
        switch shape {
        case .serif: return .serif
        case .sans: return .default
        case .mono: return .monospaced
        case .rounded: return .rounded
        }
    }

    func font(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        var font: Font
        if let resolved {
            font = .custom(resolved, fixedSize: size).weight(weight)
        } else {
            font = .system(size: size, weight: weight, design: design)
        }
        if italic { font = font.italic() }
        return font
    }

    /// The platform twin, for the prose editor's text storage.
    func platformFont(_ size: CGFloat, weight: PlatformFontWeight = .regular,
                      italic: Bool = false) -> PlatformFont {
        #if canImport(AppKit)
        var font: PlatformFont
        if let resolved, let custom = NSFont(name: resolved, size: size) {
            font = custom
        } else {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let descriptor = base.fontDescriptor.withDesign(appKitDesign) ?? base.fontDescriptor
            font = NSFont(descriptor: descriptor, size: size) ?? base
        }
        if weight == .bold || weight == .semibold || weight == .heavy {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
        #else
        var base: UIFont
        if let resolved, let custom = UIFont(name: resolved, size: size) {
            base = custom
        } else {
            let system = UIFont.systemFont(ofSize: size, weight: weight)
            let descriptor = system.fontDescriptor.withDesign(uiKitDesign) ?? system.fontDescriptor
            base = UIFont(descriptor: descriptor, size: size)
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if weight == .bold || weight == .semibold || weight == .heavy { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let withTraits = base.fontDescriptor.withSymbolicTraits(traits) {
            base = UIFont(descriptor: withTraits, size: size)
        }
        return base
        #endif
    }

    #if canImport(AppKit)
    private var appKitDesign: NSFontDescriptor.SystemDesign {
        switch shape {
        case .serif: return .serif
        case .sans: return .default
        case .mono: return .monospaced
        case .rounded: return .rounded
        }
    }
    #else
    private var uiKitDesign: UIFontDescriptor.SystemDesign {
        switch shape {
        case .serif: return .serif
        case .sans: return .default
        case .mono: return .monospaced
        case .rounded: return .rounded
        }
    }
    #endif
}
