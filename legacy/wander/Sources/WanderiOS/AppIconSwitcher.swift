//
//  AppIconSwitcher.swift
//  wander (iOS)
//
//  Every theme has its own mark, so the home screen shows the one you write in.
//  iOS only allows an alternate icon that is declared in the bundle, which is
//  why `project.yml` lists all of them.
//

#if os(iOS)
import UIKit

enum AppIconSwitcher {
    /// Switch to the theme's icon, quietly. iOS refuses mid-launch and while
    /// backgrounded, and there is nothing useful to say when it does.
    static func apply(theme id: String) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let name = id == "almanac" ? nil : "wander-\(id)"
        guard UIApplication.shared.alternateIconName != name else { return }
        UIApplication.shared.setAlternateIconName(name) { _ in }
    }
}
#endif
