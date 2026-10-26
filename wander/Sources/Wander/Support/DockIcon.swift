//
//  DockIcon.swift
//  Wander
//
//  Two icons ship in the bundle — paper and ink — and the Dock gets whichever
//  matches the appearance the app is actually drawing in, including when that
//  is an explicit Light/Dark choice rather than the system's.
//

#if os(macOS)

import AppKit
import SwiftUI
import WanderCore


enum DockIcon {
    private static var current: String?

    /// Each theme has its own mark, in its own palette and display face; the
    /// Dock shows the one you are writing in.
    static func apply(theme: String, dark: Bool) {
        let name = "\(theme)-\(dark ? "dark" : "light")"
        guard current != name else { return }
        let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons")
            ?? Bundle.main.url(forResource: dark ? "AppIcon-dark" : "AppIcon-light", withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else { return }
        current = name
        NSApp.applicationIconImage = image
    }
}

extension Notification.Name {
    static let openThemes = Notification.Name("wander.openThemes")
}

#endif
