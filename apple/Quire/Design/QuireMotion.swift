//
//  QuireMotion.swift
//  Quire
//
//  How Quire moves: one set of timings, one vocabulary of haptics, and the
//  handful of small moments that make the journal feel like paper and ink
//  rather than a list of rows. Everything here stands still under Reduce
//  Motion (the content still arrives), and nothing animates per keystroke:
//  each moment is keyed to a real change -- a page arriving, an entry filed,
//  a goal reached.
//

import SwiftUI

// MARK: - Timings

enum QMotion {
    /// A press, a toggle, a word changing. 120 ms.
    static let micro = Animation.easeOut(duration: 0.12)
    /// Panels and rows arriving. 200 ms, out-expo.
    static let standard = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.2)
    /// Something crossing the page: a page turning, a rule drawing. 320 ms.
    static let move = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.32)
    /// Anything leaving. Faster than it arrived.
    static let exit = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.14)
    /// Something landing: a stamp, a filed entry, a rolled prompt.
    static let settle = Animation.spring(duration: 0.35, bounce: 0.15)
    /// The moments that earn a little theatre: figures counting up.
    static let story = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.6)
}

// MARK: - Haptics

/// One place that decides which moments are felt: success when an entry is
/// filed or the day's goal is met, a light land when something is saved or a
/// prompt rolls, a warning when a write fails.
enum QHaptic {
    case success, land, warning

    var feedback: SensoryFeedback {
        switch self {
        case .success: return .success
        case .land:    return .impact(weight: .light)
        case .warning: return .warning
        }
    }
}

extension View {
    /// Plays `haptic` whenever `trigger` changes.
    func qHaptic<T: Equatable>(_ haptic: QHaptic, trigger: T) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger)
    }
}

// MARK: - Arrival
// A page arrives rather than appears: its title, labels and rows rise 6 pt and
// fade in, top to bottom, the whole page inside about 150 ms. Only on arrival
// -- a tab switched to, an entry opened -- never while scrolling or typing.
// Each face carries an arrival stamp; `qArrive()` plays only for views that
// appear just after it, delayed by how far down the screen they sit.

struct QArrival: Equatable {
    var date = Date()
    var token = UUID()
}

extension EnvironmentValues {
    @Entry var qArrival: QArrival? = nil
}

private struct QArrivalRoot<Key: Equatable>: ViewModifier {
    let key: Key
    @State private var arrival = QArrival()

    func body(content: Content) -> some View {
        content
            .environment(\.qArrival, arrival)
            .onChange(of: key) { _, _ in arrival = QArrival() }
    }
}

private struct QArrive: ViewModifier {
    @Environment(\.qArrival) private var arrival
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var played: UUID?
    @State private var shown = true
    @State private var y: CGFloat = 0

    /// Views appearing later than this after the page arrived were scrolled
    /// to, not arriving, and just show.
    private static let window: TimeInterval = 0.6

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { y = $0 }
            .onAppear(perform: play)
            .onChange(of: arrival) { _, _ in play() }
    }

    private func play() {
        guard let arrival, played != arrival.token else { return }
        played = arrival.token
        guard !reduceMotion, Date().timeIntervalSince(arrival.date) < Self.window else {
            shown = true
            return
        }
        shown = false
        #if os(iOS)
        let screen = max(1, UIScreen.main.bounds.height)
        #else
        let screen: CGFloat = 900
        #endif
        let delay = 0.15 * min(1, max(0, y / screen))
        DispatchQueue.main.async {
            withAnimation(QMotion.standard.delay(delay)) { shown = true }
        }
    }
}

extension View {
    /// Marks a page; a new `key` (another tab, another entry) is a new arrival.
    func qArrivalRoot<Key: Equatable>(key: Key) -> some View {
        modifier(QArrivalRoot(key: key))
    }

    /// Rises into place when the page it is on arrives.
    func qArrive() -> some View {
        modifier(QArrive())
    }
}

// MARK: - Drawing in
// A rule drawn as if by a pen: it grows from its left end when it first
// appears. Used under a title, where the accent rule is the page's signature.

private struct QDrawIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var delay: Double = 0.08
    @State private var drawn = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: drawn || reduceMotion ? 1 : 0.001, y: 1, anchor: .leading)
            .onAppear {
                guard !reduceMotion, !drawn else { return }
                withAnimation(QMotion.move.delay(delay)) { drawn = true }
            }
    }
}

/// A bar growing up from its baseline, once.
private struct QGrowUp: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var delay: Double = 0
    @State private var grown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: grown || reduceMotion ? 1 : 0.001, anchor: .bottom)
            .onAppear {
                guard !reduceMotion, !grown else { return }
                withAnimation(QMotion.settle.delay(delay)) { grown = true }
            }
    }
}

/// A card dealt onto the page: it lands from a little to the side and askew,
/// like a postcard put down on a desk.
private struct QFanIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    @State private var dealt = false

    func body(content: Content) -> some View {
        let angle = index.isMultiple(of: 2) ? -2.5 : 2.0
        return content
            .rotationEffect(.degrees(dealt || reduceMotion ? 0 : angle), anchor: .bottomLeading)
            .offset(x: dealt || reduceMotion ? 0 : 18)
            .opacity(dealt || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion, !dealt else { return }
                withAnimation(QMotion.settle.delay(0.12 + Double(index) * 0.07)) { dealt = true }
            }
    }
}

/// A figure that breathes a few times when it arrives -- a live streak -- and
/// then holds still, so it draws the eye once rather than for ever.
private struct QBreathe: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    @State private var beat = 0

    func body(content: Content) -> some View {
        content
            .phaseAnimator([1.0, 1.06, 1.0], trigger: beat) { view, scale in
                view.scaleEffect(scale, anchor: .bottomLeading)
            } animation: { _ in .easeInOut(duration: 0.45) }
            .task {
                guard active, !reduceMotion else { return }
                for _ in 0..<3 {
                    try? await Task.sleep(for: .seconds(0.4))
                    beat += 1
                    try? await Task.sleep(for: .seconds(1.0))
                }
            }
    }
}

/// The rubber stamp: pressed down from a little above and askew, with a small
/// spring, each time `trigger` changes.
private struct QStamp: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trigger: Int

    func body(content: Content) -> some View {
        let still = reduceMotion
        return content
            .keyframeAnimator(initialValue: QStampPose(), trigger: trigger) { view, pose in
                view
                    .scaleEffect(still ? 1 : pose.scale)
                    .rotationEffect(.degrees(still ? -4 : pose.angle))
                    .opacity(still ? 1 : pose.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.5, duration: 0.01)
                    SpringKeyframe(1, duration: 0.4, spring: .init(duration: 0.4, bounce: 0.2))
                }
                KeyframeTrack(\.angle) {
                    CubicKeyframe(-12, duration: 0.01)
                    SpringKeyframe(-4, duration: 0.4, spring: .init(duration: 0.4, bounce: 0.2))
                }
                KeyframeTrack(\.opacity) {
                    CubicKeyframe(0, duration: 0.01)
                    LinearKeyframe(1, duration: 0.12)
                }
            }
    }
}

private struct QStampPose {
    var scale = 1.0
    var angle = -4.0
    var opacity = 1.0
}

/// A placeholder that breathes softly while the page is empty, like a nib
/// hovering over paper; it stops the moment there is text.
private struct QHover: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var low = false

    func body(content: Content) -> some View {
        content
            .opacity(low && !reduceMotion ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { low = true }
            }
    }
}

extension View {
    /// Draws in from the left, as a pen would, when it first appears.
    func qDrawIn(delay: Double = 0.08) -> some View { modifier(QDrawIn(delay: delay)) }
    /// Grows up from its baseline when it first appears.
    func qGrowUp(delay: Double = 0) -> some View { modifier(QGrowUp(delay: delay)) }
    /// Dealt onto the page like a card, `index` setting its turn and tilt.
    func qFanIn(_ index: Int) -> some View { modifier(QFanIn(index: index)) }
    /// Breathes three times on arrival when `active`, then holds still.
    func qBreathe(_ active: Bool) -> some View { modifier(QBreathe(active: active)) }
    /// Lands like a rubber stamp each time `trigger` changes.
    func qStamp(trigger: Int) -> some View { modifier(QStamp(trigger: trigger)) }
    /// Breathes softly while shown: an empty page waiting for the first word.
    func qHover() -> some View { modifier(QHover()) }
}

// MARK: - Counting up
// A figure that counts up from nothing when it arrives -- the Look back
// numbers -- rather than appearing whole. The text is rebuilt per frame of a
// 0.6 s animation, which a handful of figures can afford; it never runs while
// typing.

struct QCount: View, Animatable {
    var value: Double
    let format: (Int) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(format(Int(value.rounded()))) }
}

/// Counts `target` up from zero on first appearance; still under Reduce Motion.
struct QCountUp: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let target: Int
    var format: (Int) -> String = { "\($0)" }
    @State private var shown: Double = 0
    @State private var started = false

    var body: some View {
        QCount(value: reduceMotion ? Double(target) : shown, format: format)
            .accessibilityLabel(format(target))
            .onAppear {
                guard !started else { return }
                started = true
                withAnimation(QMotion.story.delay(0.1)) { shown = Double(target) }
            }
            .onChange(of: target) { _, new in withAnimation(QMotion.standard) { shown = Double(new) } }
    }
}

// MARK: - The time of day

enum QTimeOfDay {
    /// The part of the day, for the Today kicker: "morning", "evening".
    static func phrase(_ date: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12:  return "morning"
        case 12..<17: return "afternoon"
        case 17..<22: return "evening"
        default:      return "late"
        }
    }
}
