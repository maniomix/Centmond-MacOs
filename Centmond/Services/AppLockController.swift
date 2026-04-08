import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Holds the runtime unlocked-state for the app, and re-locks on system sleep
/// or after configured inactivity. The lock *settings* (`appLockEnabled`,
/// `appPasscode`, `lockOnSleep`, `lockTimeoutMinutes`) live in `@AppStorage`;
/// this controller is what actually consumes them.
///
/// Without this, the inactivity and sleep settings exposed in
/// Settings → Security were stored but had no effect — RootView held a
/// local `@State isUnlocked` that nothing else could touch.
@Observable
final class AppLockController {
    var isUnlocked: Bool = false

    private var inactivityTimer: Timer?
    #if os(macOS)
    private var sleepObserver: NSObjectProtocol?
    #endif

    init() {
        #if os(macOS)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemSleep()
        }
        #endif
    }

    deinit {
        #if os(macOS)
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        #endif
        inactivityTimer?.invalidate()
    }

    /// Called by the lock screen when the user successfully authenticates.
    func unlock() {
        isUnlocked = true
        scheduleInactivityTimer()
    }

    /// Forces the app back into the locked state. Used by the menu, sleep
    /// notifications, and the inactivity timer.
    func lock() {
        isUnlocked = false
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    /// Should be called whenever the user interacts with the app, so the
    /// inactivity timer resets. Cheap — just rearms the timer.
    func notifyUserActivity() {
        guard isUnlocked else { return }
        scheduleInactivityTimer()
    }

    private func handleSystemSleep() {
        let lockOnSleep = UserDefaults.standard.object(forKey: "lockOnSleep") as? Bool ?? true
        let lockEnabled = UserDefaults.standard.bool(forKey: "appLockEnabled")
        guard lockEnabled, lockOnSleep else { return }
        lock()
    }

    private func scheduleInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil

        let lockEnabled = UserDefaults.standard.bool(forKey: "appLockEnabled")
        guard lockEnabled else { return }

        let minutes = UserDefaults.standard.object(forKey: "lockTimeoutMinutes") as? Int ?? 5
        guard minutes > 0 else { return } // 0 = Never

        let interval = TimeInterval(minutes * 60)
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.lock() }
        }
    }
}
