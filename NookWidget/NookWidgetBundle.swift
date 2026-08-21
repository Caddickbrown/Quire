//
//  NookWidgetBundle.swift
//  NookWidget
//
//  Widget extension entry point.
//

import WidgetKit
import SwiftUI
import CoreText

@main
struct NookWidgetBundle: WidgetBundle {
    init() { Self.registerBundledFonts() }

    var body: some Widget {
        NookWidget()
        // Lock Screen accessories, Live Activities and Control Center controls
        // exist on iOS only.
        #if os(iOS)
        NookNewEntryWidget()
        NookTimerLiveActivity()
        if #available(iOS 18.0, *) {
            NookNewDraftControl()
        }
        #endif
    }

    /// The widget runs in its own process, so it must register the bundled
    /// Lato fonts itself — it can't rely on the main app's registration.
    private static func registerBundledFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts")
                ?? Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil)
        else { return }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
