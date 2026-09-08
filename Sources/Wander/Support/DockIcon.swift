//
//  DockIcon.swift
//  Wander
//
//  Two icons ship in the bundle — paper and ink — and the Dock gets whichever
//  matches the appearance the app is actually drawing in, including when that
//  is an explicit Light/Dark choice rather than the system's.
//

import AppKit
import SwiftUI
import WanderCore

enum DockIcon {
    private static var current: String?

    static func apply(dark: Bool) {
        let name = dark ? "AppIcon-dark" : "AppIcon-light"
        guard current != name else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        current = name
        NSApp.applicationIconImage = image
    }

    static func apply(for scheme: ColorScheme) {
        apply(dark: scheme == .dark)
    }
}
