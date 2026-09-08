//
//  Appearance.swift
//  Wander
//
//  Light, dark, or whatever the system is doing. Shared by both shells.
//

import SwiftUI

enum Appearance: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "Auto"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var next: Appearance {
        let all = Appearance.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

#if !os(macOS)
extension Notification.Name {
    static let openThemes = Notification.Name("wander.openThemes")
}
#endif
