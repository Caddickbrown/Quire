//
//  NookControlWidget.swift
//  NookWidget
//
//  A Control Center control that is just a button: tap it to open Nook's
//  composer on a new entry — the same job as the Lock Screen accessory in
//  NookLockScreenWidget.swift, on the surfaces controls reach (Control Center,
//  the Lock Screen control slots, and the Action Button).
//
//  Controls are iOS 18+, and the deployment target is iOS 17, so everything
//  here is both `#if os(iOS)` and `@available(iOS 18.0, *)`.
//

#if os(iOS)
import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Intent

/// Opens Nook on a blank Write screen.
///
/// The app has its own `OpenNewDraftIntent` (in `Nook/NookIntents.swift`) for
/// Siri/Shortcuts, but that file isn't compiled into the widget target, so the
/// control carries its own intent and hands off through the `nook://write` deep
/// link — exactly what the Lock Screen accessory's `widgetURL` does.
@available(iOS 18.0, *)
struct NookNewDraftControlIntent: AppIntent {
    static var title: LocalizedStringResource = "New Draft"
    static var description = IntentDescription("Opens Nook to a blank Write screen.")
    static var openAppWhenRun = true
    // Shortcuts already lists the app's own "New Draft" intent; don't double up.
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "nook://write")!))
    }
}

// MARK: - Control definition

@available(iOS 18.0, *)
struct NookNewDraftControl: ControlWidget {
    let kind = "NookNewDraftControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: kind) {
            ControlWidgetButton(action: NookNewDraftControlIntent()) {
                Label("New Draft", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Draft")
        .description("A button that opens Nook ready to write.")
    }
}
#endif
