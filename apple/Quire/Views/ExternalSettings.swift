//
//  ExternalSettings.swift
//  Quire
//
//  Settings on the monitor. With the phone dimmed and a keyboard attached,
//  `,` opens this list on the external display instead of a sheet on the phone:
//  ↑/↓ (or j/k) move, ↵ changes the row, `,` or Esc closes. Dark mode, themes,
//  text size, key hints, dimming and a backup are all one key away.
//

#if os(iOS)

import SwiftUI

@MainActor final class ExternalSettingsModel: ObservableObject {
    static let shared = ExternalSettingsModel()

    struct Item: Identifiable {
        let id: String
        let title: String
        let value: String
        let run: () -> Void
    }

    @Published private(set) var isOpen = false
    @Published var selected = 0
    /// The last thing a row said ("Backed up", "Choose a backup folder first.").
    @Published var status = ""
    /// Bumped on every change so rows redraw their values.
    @Published private var tick = 0

    private let routerID = UUID()
    private weak var store: JournalStore?

    /// `,` from anywhere. A closed list opens; an open one closes.
    func toggle(store: JournalStore) {
        isOpen ? close() : open(store: store)
    }

    func open(store: JournalStore) {
        self.store = store
        selected = 0
        status = ""
        isOpen = true
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: { [weak self] in self?.move(-1) },
            moveDown: { [weak self] in self?.move(1) },
            open: { [weak self] in self?.activate() },
            clear: { [weak self] in self?.close() },
            // Swallow every letter so nothing underneath (delete, file…) fires.
            key: { [weak self] k in
                switch k {
                case ",": self?.close()
                case "j": self?.move(1)
                case "k": self?.move(-1)
                default: break
                }
                return true
            }))
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        KeyCommandRouter.shared.unregister(routerID)
    }

    private func move(_ delta: Int) {
        let n = items().count
        guard n > 0 else { return }
        selected = min(n - 1, max(0, selected + delta))
    }

    private func activate() {
        let all = items()
        guard all.indices.contains(selected) else { return }
        all[selected].run()
        tick += 1
    }

    // MARK: Rows

    private var defaults: UserDefaults { .standard }

    private func flag(_ key: String, default value: Bool = false) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    private var appThemeID: String { defaults.string(forKey: QuireTheme.storageKey) ?? QuireTheme.auto }
    private var monitorThemeID: String { defaults.string(forKey: ExternalTheme.key) ?? "almanac" }

    /// What the app is showing right now, resolved: "auto" follows the phone.
    private var appIsDark: Bool {
        if appThemeID == QuireTheme.auto { return ExternalDisplayModel.shared.colorScheme == .dark }
        return QuireTheme.all.first { $0.id == appThemeID }?.dark ?? false
    }

    func items() -> [Item] {
        _ = tick
        let themes = QuireTheme.all
        let ids = [QuireTheme.auto] + themes.filter { !$0.dark }.map(\.id) + themes.filter(\.dark).map(\.id)
        func name(_ id: String) -> String { id == QuireTheme.auto ? "Auto" : (themes.first { $0.id == id }?.name ?? id) }
        func next(_ id: String, in list: [String]) -> String {
            list[((list.firstIndex(of: id) ?? -1) + 1) % list.count]
        }
        /// The theme the phone and the monitor both take, so they match.
        func setBoth(_ id: String) {
            defaults.set(id, forKey: QuireTheme.storageKey)
            let concrete = id == QuireTheme.auto ? (ExternalDisplayModel.shared.colorScheme == .dark ? "cinema" : "almanac") : id
            if ExternalTheme.all.contains(where: { $0.id == concrete }) { defaults.set(concrete, forKey: ExternalTheme.key) }
        }
        let monitorIDs = ExternalTheme.all.map(\.id)
        let size = ExternalTextSize(rawValue: defaults.string(forKey: ExternalTextSize.key) ?? "") ?? .regular
        let sizes = ExternalTextSize.allCases
        let hints = flag(ShortcutHints.key, default: true)
        let dim = flag(ExternalDisplayModel.autoDimKey)
        let prompts = flag(PromptDeck.enabledKey)

        var backupValue = "Not set up"
        if let store {
            if store.backupRunning { backupValue = "Running…" }
            else if store.backupFolderName == nil { backupValue = "Choose a folder on the phone" }
            else if let last = store.lastBackupAt {
                backupValue = "Last " + last.formatted(date: .abbreviated, time: .shortened)
            } else { backupValue = "Never" }
        }

        return [
            Item(id: "dark", title: "Dark mode", value: appIsDark ? "On" : "Off") {
                setBoth(self.appIsDark ? "almanac" : "cinema")
            },
            Item(id: "theme", title: "Theme", value: name(self.appThemeID)) {
                setBoth(next(self.appThemeID, in: ids))
            },
            Item(id: "monitor", title: "Monitor theme", value: ExternalTheme.selected(self.monitorThemeID)?.name ?? "—") {
                guard !monitorIDs.isEmpty else { return }
                self.defaults.set(next(self.monitorThemeID, in: monitorIDs), forKey: ExternalTheme.key)
            },
            Item(id: "size", title: "Monitor text size", value: size.label) {
                let i = sizes.firstIndex(of: size) ?? 1
                self.defaults.set(sizes[(i + 1) % sizes.count].rawValue, forKey: ExternalTextSize.key)
            },
            Item(id: "hints", title: "Key hints on the monitor", value: hints ? "On" : "Off") {
                ShortcutHints.toggle()
            },
            Item(id: "dim", title: "Dim the phone screen", value: dim ? "On" : "Off") {
                self.defaults.set(!dim, forKey: ExternalDisplayModel.autoDimKey)
                ExternalDisplayModel.shared.autoDimPreferenceChanged()
            },
            Item(id: "prompts", title: "Prompts on an empty page", value: prompts ? "On" : "Off") {
                self.defaults.set(!prompts, forKey: PromptDeck.enabledKey)
            },
            Item(id: "backup", title: "Back up now", value: backupValue) {
                guard let store = self.store, !store.backupRunning else { return }
                self.status = "Backing up…"
                Task { @MainActor in
                    let result = await store.runBackup()
                    self.status = result.ok ? "Backed up." : result.message
                    self.tick += 1
                }
            },
            Item(id: "close", title: "Close settings", value: "") { self.close() },
        ]
    }
}

/// The list as drawn on the monitor: ruled rows in the monitor's own theme.
struct ExternalSettingsView: View {
    let metrics: ExternalDisplayMetrics

    @ObservedObject private var model = ExternalSettingsModel.shared
    @EnvironmentObject private var store: JournalStore
    @Environment(\.externalTheme) private var theme
    @Environment(\.accent) private var accent

    var body: some View {
        let items = model.items()
        let ink = theme?.text ?? .primary
        let muted = theme?.secondary ?? .secondary
        let rule = theme?.rule ?? Color.gray.opacity(0.3)
        VStack(alignment: .leading, spacing: 0) {
            Text("SETTINGS").font(.system(size: metrics.caption, weight: .semibold, design: .monospaced))
                .tracking(metrics.caption * 0.2).foregroundStyle(accent)
            Text("Settings").font(.system(size: metrics.title, weight: theme?.headingWeight ?? .medium, design: .serif))
                .foregroundStyle(ink).padding(.top, metrics.gap * 0.3).padding(.bottom, metrics.gap * 0.6)
            Rectangle().fill(accent).frame(height: max(1, theme?.rule_h ?? 1))
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let on = i == model.selected
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: metrics.gap) {
                        Text(on ? "›" : " ").foregroundStyle(accent)
                            .font(.system(size: metrics.text, weight: .semibold))
                        Text(item.title).foregroundStyle(on ? accent : ink)
                            .font(.system(size: metrics.text, weight: on ? .semibold : .regular, design: .serif))
                        Spacer(minLength: metrics.gap)
                        Text(item.value).foregroundStyle(on ? ink : muted)
                            .font(.system(size: metrics.text * 0.8, design: .monospaced))
                            .lineLimit(1)
                    }
                    .padding(.vertical, metrics.gap * 0.42)
                    Rectangle().fill(rule).frame(height: 1)
                }
            }
            Text(model.status.isEmpty ? " " : model.status)
                .font(.system(size: metrics.caption)).foregroundStyle(muted)
                .padding(.top, metrics.gap * 0.6)
            Spacer(minLength: 0)
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#endif
