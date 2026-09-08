//
//  WanderiOSApp.swift
//  wander (iOS)
//
//  The same journal, the same files, in a shape a phone can hold: the index and
//  the page as a split view, with Stats and Options as sheets rather than
//  columns. Everything below the shell — the store, the styling, the editor —
//  is shared with the Mac app.
//

#if os(iOS)
import SwiftUI
import WanderCore

@main
struct WanderiOSApp: App {
    @StateObject private var store = JournalStore()

    var body: some Scene {
        WindowGroup {
            RootViewPhone(store: store)
                .background(Theme.resolve(.light).paper.color)
        }
    }
}
#endif
