//
//  AppLock.swift
//  Nook
//
//  Face ID / Touch ID / passcode gate over the app (Settings → Privacy).
//  This locks the *app*, not the files — the journal stays plain markdown on
//  disk, readable in Files/Finder, by design; the setting's copy says so.
//
//  RootView overlays a veil while locked and while the app is in the
//  background (so entry text never shows in the app switcher).
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
                isLocked = false
                return
            }
            let ok = (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your journal")) ?? false
            if ok { isLocked = false }
        }
    }

    // MARK: Scene phase

    func didEnterBackground() {
        guard enabled else { return }
        leftForegroundAt = Date()
    }

    func didBecomeActive() {
        guard enabled else { isLocked = false; return }
        if let left = leftForegroundAt, Date().timeIntervalSince(left) >= grace {
            isLocked = true
        }
        leftForegroundAt = nil
    }

    /// The setting flipped: lock immediately when turned on, release when off.
    func preferenceChanged() {
        if enabled {
            // Newly enabled: stay unlocked for this session; lock on background.
        } else {
            isLocked = false
        }
    }
}
