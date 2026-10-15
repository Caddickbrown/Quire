//
//  AppLock.swift
//  Quire
//
//  Face ID / Touch ID / passcode gate over the app (Settings → Privacy).
//  This locks the *app*, not the files — the journal stays plain markdown on
//  disk, readable in Files/Finder, by design; the setting's copy says so.
//
//  RootView puts a veil up while locked *and* while the app is on its way out
//  of the foreground — `veiled` goes true on the first sign of resigning
//  active, which is when iOS takes the app-switcher snapshot, so entry text
//  never ends up in it. Coming back inside the grace period drops the veil
//  without asking for a face; outside it, the lock engages and the veil stays
//  until you authenticate. The second screen is a window of its own that no
//  veil reaches, so it is told separately to fall back to its idle screen.
//

import Foundation
import LocalAuthentication

@MainActor
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    static let enabledKey = "appLock"
    static let graceKey = "appLockGraceSeconds"   // relock after this long in background

    @Published private(set) var isLocked: Bool
    @Published private(set) var unlocking = false
    /// Covered but not necessarily locked: the veil the moment the app stops
    /// being frontmost, before the system's snapshot is taken.
    @Published private(set) var veiled = false

    /// Whether anything should be covering the app right now.
    var showsVeil: Bool { isLocked || veiled }

    private var leftForegroundAt: Date?

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    private var grace: TimeInterval {
        UserDefaults.standard.object(forKey: Self.graceKey) as? TimeInterval ?? 0
    }

    private init() {
        isLocked = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Whether this device can evaluate any authentication at all.
    static func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func lock() {
        guard enabled else { return }
        isLocked = true
        veiled = true
        syncExternalDisplay()
    }

    func unlock() {
        guard isLocked, !unlocking else { return }
        unlocking = true
        let context = LAContext()
        context.localizedReason = "Unlock your journal"
        Task { @MainActor in
            defer { unlocking = false }
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
                // No passcode set on the device — nothing to gate behind.
                clearVeil()
                return
            }
            let ok = (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your journal")) ?? false
            if ok { clearVeil() }
        }
    }

    private func clearVeil() {
        isLocked = false
        veiled = false
        syncExternalDisplay()
    }

    // MARK: Scene phase

    /// Resigning active — a system prompt, the app switcher, a swipe home.
    /// The veil has to be up *here*: by `didEnterBackground` the snapshot the
    /// switcher shows has already been taken.
    func willResignActive() {
        guard enabled else { return }
        veiled = true
        syncExternalDisplay()
    }

    func didEnterBackground() {
        guard enabled else { return }
        veiled = true
        leftForegroundAt = Date()
        syncExternalDisplay()
    }

    func didBecomeActive() {
        guard enabled else { clearVeil(); return }
        if let left = leftForegroundAt, Date().timeIntervalSince(left) >= grace {
            isLocked = true
        } else if !isLocked {
            // Back inside the grace period (or straight back from a system
            // prompt): uncover without asking for a face.
            veiled = false
        }
        leftForegroundAt = nil
        syncExternalDisplay()
    }

    /// The setting flipped: lock immediately when turned on, release when off.
    func preferenceChanged() {
        if enabled {
            // Newly enabled: stay unlocked for this session; the veil goes up
            // on the way out of the foreground.
        } else {
            clearVeil()
        }
    }

    /// The external display is a separate window the veil can't cover, so it
    /// is told directly: the idle stats screen while the app is covered, and
    /// back to whatever it was showing once the lock lifts.
    private func syncExternalDisplay() {
        ExternalDisplayModel.shared.applyLockState(locked: showsVeil)
    }
}
