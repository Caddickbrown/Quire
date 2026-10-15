//
//  QuireControlWidget.swift
//  QuireWidget
//
//  A Control Center control that is just a button: tap it to open Quire's
//  composer on a new entry — the same job as the Lock Screen accessory in
//  QuireLockScreenWidget.swift, on the surfaces controls reach (Control Center,
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

/// Opens Quire on a blank Write screen.
///
/// The app has its own `OpenNewDraftIntent` (in `Quire/QuireIntents.swift`) for
/// Siri/Shortcuts, but that file isn't compiled into the widget target, so the
/// control carries its own intent and hands off through the `quire://write` deep
/// link — exactly what the Lock Screen accessory's `widgetURL` does.
@available(iOS 18.0, *)
struct QuireNewDraftControlIntent: AppIntent {
    static var title: LocalizedStringResource = "New Draft"
    static var description = IntentDescription("Opens Quire to a blank Write screen.")
    static var openAppWhenRun = true
    // Shortcuts already lists the app's own "New Draft" intent; don't double up.
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "quire://write")!))
    }
}

// MARK: - Control definition

@available(iOS 18.0, *)
struct QuireNewDraftControl: ControlWidget {
    let kind = "QuireNewDraftControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: kind) {
            ControlWidgetButton(action: QuireNewDraftControlIntent()) {
                Label("New Draft", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Draft")
        .description("A button that opens Quire ready to write.")
    }
}
#endif
