//
//  QuireKeys.swift
//  Quire
//
//  The keyboard, as in the terminal app: ↑/↓ or j/k move through a list, Return
//  opens, Esc lets go, and letters act on the selected row (f file, e edit,
//  s star, u return to the inbox, d delete). The selection is mirrored to a
//  connected monitor as a browse list with a preview. Letters sit at the end of
//  the responder chain (see KeyboardNavigation.swift), so typing is never touched.
//

#if os(iOS)

import SwiftUI

extension View {
    /// Arrow-key selection over `entries` with a per-row letter handler.
    /// `index` is the host's selection, so the list can highlight and scroll to it.
    func qKeyList(entries: [Entry],
                  index: Binding<Int?>,
                  listTitle: String,
                  autoSelect: Bool = false,
                  onOpen: @escaping (Entry) -> Void,
                  letter: @escaping (Entry, String) -> Bool = { _, _ in false }) -> some View {
        modifier(QKeyList(entries: entries, index: index, listTitle: listTitle, autoSelect: autoSelect, onOpen: onOpen, letter: letter))
    }

    /// While a sheet or full-screen page is up, keep every key away from the list
    /// beneath it.
    func qKeyBlocker(active: Bool) -> some View { modifier(QKeyBlocker(active: active)) }
}

private struct QKeyList: ViewModifier {
    let entries: [Entry]
    @Binding var index: Int?
    let listTitle: String
    let autoSelect: Bool
    let onOpen: (Entry) -> Void
    let letter: (Entry, String) -> Bool

    @State private var routerID = UUID()
    @State private var didAutoSelect = false

    func body(content: Content) -> some View {
        content
            .background(KeyCommandCatcher().frame(width: 0, height: 0).allowsHitTesting(false))
            .onAppear { adopt(); register(); publish() }
            .onChange(of: index) { _, _ in register(); publish() }
            .onChange(of: entries.map(\.ts)) { _, _ in
                adopt()
                if let i = index, i >= entries.count { index = entries.isEmpty ? nil : entries.count - 1 }
                register(); publish()
            }
            .onDisappear {
                KeyCommandRouter.shared.unregister(routerID)
                ExternalDisplayModel.shared.clearBrowse(listTitle: listTitle)
            }
    }

    /// A list opens with its top row selected, so ↵ and the letters work at once.
    private func adopt() {
        if autoSelect, !didAutoSelect, index == nil, !entries.isEmpty { index = 0; didAutoSelect = true }
    }

    private func register() {
        // An empty list leaves the keys to the screen beneath (↓ from Look back
        // still goes to the Journal).
        // It keeps its place in the stack (see `deactivate`), so its first row
        // doesn't lift it above the composer.
        guard !entries.isEmpty else { KeyCommandRouter.shared.deactivate(routerID); return }
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: { move(-1) },
            moveDown: { move(1) },
            open: { if let e = selected { onOpen(e) } },
            clear: { if index != nil, !autoSelect { index = nil } else { KeyCommandRouter.shared.onBack?() } },
            key: { k in
                // The terminal's j/k: down and up, as the arrows.
                if k == "j" { move(1); return true }
                if k == "k" { move(-1); return true }
                guard let e = selected else { return false }
                return letter(e, k)
            }
        ))
    }

    private var selected: Entry? {
        guard let i = index, entries.indices.contains(i) else { return nil }
        return entries[i]
    }

    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        // The first press adopts the top (or bottom) rather than jumping to row 2.
        guard let current = index else { index = delta > 0 ? 0 : entries.count - 1; return }
        index = min(max(current + delta, 0), entries.count - 1)
    }

    private func publish() {
        guard let i = index, entries.indices.contains(i) else {
            ExternalDisplayModel.shared.clearBrowse(listTitle: listTitle)
            return
        }
        ExternalDisplayModel.shared.present(.browsing(listTitle: listTitle,
                                                      rows: ExternalRow.rows(from: entries), selected: i))
    }
}

private struct QKeyBlocker: ViewModifier {
    let active: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: active) { _, on in apply(on) }
            .onAppear { apply(active) }
            .onDisappear { KeyCommandRouter.shared.unregister(id) }
    }

    private func apply(_ on: Bool) {
        if on {
            KeyCommandRouter.shared.register(id, QuireKeyHandlers(
                moveUp: {}, moveDown: {}, open: {}, clear: {}, key: { _ in true }))
        } else {
            KeyCommandRouter.shared.unregister(id)
        }
    }
}

#endif
