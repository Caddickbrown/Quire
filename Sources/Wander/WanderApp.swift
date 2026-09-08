//
//  WanderApp.swift
//  Wander
//
//  A journal that writes plain markdown in the jnl / Nook layout, so the same
//  folder can be opened by any of them.
//

import SwiftUI
import AppKit
import WanderCore

@main
struct WanderApp: App {
    @StateObject private var store = JournalStore()
    @AppStorage("focusMode") private var focusMode = false
    @AppStorage("showIndex") private var showIndex = true
    @AppStorage("showStats") private var showStats = true
    @AppStorage("showOptions") private var showOptions = false
    @AppStorage("typewriter") private var typewriter = false
    @AppStorage("typeSize") private var typeSize = 17.5
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Entry") { store.newEntry() }
                    .keyboardShortcut("n")
                Button("New Draft") { store.newDraft() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Now") { store.flush() }
                    .keyboardShortcut("s")
                Divider()
                Button("Reload from Disk") { store.reload() }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Reveal Entry in Finder") {
                    if let entry = store.selectedEntry { store.reveal(entry) } else { store.revealFolder() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Change Journal Folder\u{2026}") { store.chooseFolder() }
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Entry Markdown") {
                    if let entry = store.selectedEntry { store.copyMarkdown(entry) }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Find in Journal") { store.searchFocusRequest += 1 }
                    .keyboardShortcut("f")
            }
            CommandMenu("Entry") {
                Button(store.selectedEntry?.isStarred == true ? "Unstar" : "Star") {
                    store.toggleStarOnSelection()
                }
                .keyboardShortcut("d")
                Button(store.selectedIsUnfiled ? "File to Journal" : "Return to Inbox") {
                    if let entry = store.selectedEntry { store.toggleFiling(entry) }
                }
                .keyboardShortcut("j")
                Button("Date & Time\u{2026}") {
                    store.reschedulingEntry = store.selectedEntry
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Delete Entry\u{2026}", role: .destructive) {
                    store.deletionCandidate = store.selectedEntry
                }
                .keyboardShortcut(.delete, modifiers: .command)
                Divider()
                Button("Previous Entry") { store.step(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Entry") { store.step(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            CommandGroup(after: .toolbar) {
                Button(focusMode ? "Leave Focus Mode" : "Focus Mode") { focusMode.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button(typewriter ? "Stop Typewriter Scrolling" : "Typewriter Scrolling") {
                    typewriter.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Journal") { store.show(.journal) }
                    .keyboardShortcut("1")
                Button("Inbox") { store.show(.inbox) }
                    .keyboardShortcut("2")
                Button("Starred") { store.show(.starred) }
                    .keyboardShortcut("3")
                Divider()
                Button(showIndex ? "Hide Index" : "Show Index") {
                    withAnimation(Motion.column) { showIndex.toggle() }
                }
                .keyboardShortcut("\\", modifiers: .command)
                Button(showStats ? "Hide Stats" : "Show Stats") {
                    withAnimation(Motion.column) { showStats.toggle() }
                }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                Button(showOptions ? "Hide Options" : "Show Options") {
                    withAnimation(Motion.column) { showOptions.toggle() }
                }
                .keyboardShortcut("\\", modifiers: [.command, .option])
                Divider()
                Button("Larger Type") { typeSize = min(28, typeSize + 0.5) }
                    .keyboardShortcut("+")
                Button("Smaller Type") { typeSize = max(13, typeSize - 0.5) }
                    .keyboardShortcut("-")
                Button("Appearance: \(Appearance(rawValue: appearanceRaw)?.label ?? "Auto")") {
                    appearanceRaw = (Appearance(rawValue: appearanceRaw) ?? .system).next.rawValue
                }
                Divider()
            }
            CommandGroup(replacing: .help) {}
        }
    }
}
