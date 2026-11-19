// Tapping the tab you're already on goes back to its top (GUIDE, Dan, 19 Nov): the first tap pops a
// pushed screen back to that tab's root, the next scrolls the root list to the top, animated. Every
// tab and bottom-menu destination, and an iPad's sidebar.
//
// `TabReselect` counts re-taps per tab. A counter rather than a Bool: the event is "it happened
// again", and two taps in a row have to be two events. A tab's screens read their own count, so a
// hidden tab's list never moves.
//
// The scroll target is generic, not `AnyHashable`: a List row's id is matched by its own type, and an
// `AnyHashable` wrapping the same String found nothing (Acorn, 19 Nov).

import Foundation

struct TabReselect<Tab: Hashable>: Equatable {
    private var counts: [Tab: Int] = [:]

    init() {}

    /// The re-tap count a tab's screens watch.
    func signal(_ tab: Tab) -> Int { counts[tab, default: 0] }

    /// A tap on `tab` while `current` is showing. True, and that tab's signal moves, when it is the
    /// tab you're on; a move to another tab changes nothing here.
    @discardableResult
    mutating func tapped(_ tab: Tab, current: Tab) -> Bool {
        guard tab == current else { return false }
        counts[tab, default: 0] += 1
        return true
    }

    enum Step: Equatable { case popToRoot, scrollToTop }

    /// What one re-tap does with `pushed` screens over the tab's root.
    static func step(pushed: Int) -> Step { pushed > 0 ? .popToRoot : .scrollToTop }
}

#if canImport(SwiftUI)
import SwiftUI

// iPhone, iPad and the Mac alike: a Mac sidebar re-selects the same way.
extension Binding where Value: Hashable {
    /// A tab selection that also hears a tap on the tab already selected: `TabView` and a
    /// `List(selection:)` sidebar set the same value again, which `onChange` never reports.
    func reselecting(_ onReselect: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { new in
            if new == wrappedValue { onReselect(new) }
            wrappedValue = new
        })
    }
}

@available(iOS 17, macOS 14, *)
extension View {
    /// The first re-tap: back to the tab's root from however deep. At the root the path is empty
    /// and nothing changes here; the scroll that shares the signal is what you see.
    func popsToRootOnReselect(_ path: Binding<NavigationPath>, signal: Int) -> some View {
        onChange(of: signal) { _, _ in
            guard !path.wrappedValue.isEmpty else { return }
            path.wrappedValue = NavigationPath()
        }
    }

    /// The next re-tap: the root list to `target`, its first row (or an anchor at the head of a
    /// ScrollView). `atRoot` is false while a screen is pushed, so the same tap only pops.
    func scrollsToTopOnReselect<ID: Hashable>(_ proxy: ScrollViewProxy, signal: Int, target: ID?,
                                              atRoot: Bool = true) -> some View {
        onChange(of: signal) { _, _ in
            guard atRoot, let target else { return }
            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
        }
    }
}
#endif
