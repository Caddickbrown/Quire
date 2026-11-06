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
    /// `autoSelect` adopts the first row only while a monitor is connected.
    func qKeyList(entries: [Entry],
                  index: Binding<Int?>,
                  listTitle: String,
                  autoSelect: Bool = false,
                  onOpen: @escaping (Entry) -> Void,
                  letter: @escaping (Entry, String) -> Bool = { _, _ in false }) -> some View {
        modifier(QKeyList(entries: entries, index: index, listTitle: listTitle, autoSelect: autoSelect, onOpen: onOpen, letter: letter))
    }

    /// While a sheet or full-screen page is up, keep every key away from the list
    /// beneath it. `onEscape` closes it: a page with no Esc of its own must never
    /// be a dead end on the monitor, where it may be the only way out.
    func qKeyBlocker(active: Bool, onEscape: @escaping () -> Void = {}) -> some View {
        modifier(QKeyBlocker(active: active, onEscape: onEscape))
    }

    /// ↑/↓ and j/k scroll the page this sits in, for a page with no rows to
    /// select. Goes on the scroll view's content. Esc runs `onEscape`, or backs
    /// out as a list does.
    func qKeyScroll(onEscape: (() -> Void)? = nil) -> some View {
        modifier(QKeyScroll(onEscape: onEscape))
    }
}

/// Moves a SwiftUI `ScrollView` by a fraction of a page. iOS 17 has no way to
/// scroll by a distance, and a page of text has no rows to scroll to, so the
/// handle holds on to the `UIScrollView` underneath (see `QScrollAttach`).
@MainActor final class QScrollHandle {
    fileprivate weak var scroll: UIScrollView?

    /// -1 up, 1 down: a third of the page, so the eye keeps its place.
    func step(_ direction: Int) {
        guard let scroll else { return }
        let inset = scroll.adjustedContentInset
        let top = -inset.top
        let bottom = max(top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
        let y = min(bottom, max(top, scroll.contentOffset.y + CGFloat(direction) * scroll.bounds.height / 3))
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            scroll.contentOffset.y = y
        }
    }
}

/// Goes on a `ScrollView`'s content and tells `handle` which scroll view that is.
struct QScrollAttach: UIViewRepresentable {
    let handle: QScrollHandle

    final class Probe: UIView {
        var handle: QScrollHandle?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            find()
        }

        func find() {
            var view = superview
            while let here = view {
                if let scroll = here as? UIScrollView { handle?.scroll = scroll; return }
                view = here.superview
            }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.handle = handle
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.handle = handle
        probe.find()
    }
}

private struct QKeyScroll: ViewModifier {
    let onEscape: (() -> Void)?
    @State private var id = UUID()
    @State private var handle = QScrollHandle()

    func body(content: Content) -> some View {
        content
            .background(QScrollAttach(handle: handle))
            .onAppear {
                let handle = handle
                KeyCommandRouter.shared.register(id, QuireKeyHandlers(
                    moveUp: { handle.step(-1) },
                    moveDown: { handle.step(1) },
                    open: {},
                    clear: { (onEscape ?? { KeyCommandRouter.shared.onBack?() })() },
                    key: { k in
                        if k == "j" { handle.step(1); return true }
                        if k == "k" { handle.step(-1); return true }
                        return false
                    }))
            }
            .onDisappear { KeyCommandRouter.shared.unregister(id) }
    }
}

private struct QKeyList: ViewModifier {
    let entries: [Entry]
    @Binding var index: Int?
    let listTitle: String
    let autoSelect: Bool
    let onOpen: (Entry) -> Void
    let letter: (Entry, String) -> Bool

    @ObservedObject private var monitor = ExternalDisplayModel.shared

    private var selectsAutomatically: Bool { autoSelect && monitor.isConnected }

    @State private var routerID = UUID()
    @State private var visible = false
    @State private var published: ExternalDisplayContent?

    func body(content: Content) -> some View {
        content
            .background(KeyCommandCatcher().frame(width: 0, height: 0).allowsHitTesting(false))
            .onAppear {
                visible = true
                if !monitor.isConnected { index = nil }
                adopt(); register(); publish()
            }
            .task { adopt(); register(); publish() }
            .onChange(of: monitor.isConnected) { _, connected in
                if !connected { index = nil }
                adopt(); register(); publish()
            }
            .onChange(of: index) { _, _ in register(); publish() }
            .onChange(of: monitor.relistSignal) { _, _ in publish() }
            .onChange(of: entries) { _, _ in
                adopt()
                if let i = index, i >= entries.count { index = entries.isEmpty ? nil : entries.count - 1 }
                register(); publish()
            }
            .onDisappear {
                visible = false
                KeyCommandRouter.shared.unregister(routerID)
                if let published { ExternalDisplayModel.shared.clear(ifShowing: published) }
            }
    }

    /// Desk mode starts ready for ↵; phone-only lists wait for keyboard movement.
    private func adopt() {
        if visible, selectsAutomatically, index == nil, !entries.isEmpty { index = 0 }
    }

    private func register() {
        guard visible else { return }
        // An empty list leaves the keys to the screen beneath (↓ from Look back
        // still goes to the Journal).
        // It keeps its place in the stack (see `deactivate`), so its first row
        // doesn't lift it above the composer.
        guard !entries.isEmpty else { KeyCommandRouter.shared.deactivate(routerID); return }
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: { move(-1) },
            moveDown: { move(1) },
            open: { if let e = selected { onOpen(e) } },
            clear: { if index != nil, !selectsAutomatically { index = nil } else { KeyCommandRouter.shared.onBack?() } },
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
        guard visible else { return }
        let i = index.flatMap { entries.indices.contains($0) ? $0 : nil }
        guard selectsAutomatically || i != nil else {
            if let published { ExternalDisplayModel.shared.clear(ifShowing: published) }
            return
        }
        // Bound the mirror's payload while keeping the selected row visible
        // in journals larger than the monitor's 300-row window.
        let selected = i ?? 0
        let start = min(max(0, selected - ExternalRow.maxRows / 2), max(0, entries.count - ExternalRow.maxRows))
        let end = min(entries.count, start + ExternalRow.maxRows)
        let content = ExternalDisplayContent.browsing(listTitle: listTitle,
            rows: ExternalRow.rows(from: Array(entries[start..<end])), selected: selected - start,
            offset: start, total: entries.count)
        published = content
        ExternalDisplayModel.shared.present(content)
    }

}

private struct QKeyBlocker: ViewModifier {
    let active: Bool
    let onEscape: () -> Void
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
                moveUp: {}, moveDown: {}, open: {}, clear: onEscape, key: { _ in true }))
        } else {
            KeyCommandRouter.shared.unregister(id)
        }
    }
}

#endif
