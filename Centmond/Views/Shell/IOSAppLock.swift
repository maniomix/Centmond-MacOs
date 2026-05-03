#if os(iOS)
import SwiftUI
import LocalAuthentication

/// iOS app-lock controller, parallel to the macOS `AppLockController`.
/// Uses LocalAuthentication so unlock can be Face ID, Touch ID, or the
/// device passcode (whichever the user has set up). Locks back when the
/// app moves to background so a stolen-but-unlocked phone doesn't expose
/// finances.
@Observable
final class IOSAppLockController {
    /// True when the lock screen should hide. Starts false at app launch
    /// when locking is enabled — RootView gates on this.
    var isUnlocked: Bool = false

    /// Last `evaluatePolicy` failure message, if any. Surfaced on the
    /// lock screen so the user knows why Face ID rejected (e.g. canceled,
    /// failed too many times → device passcode required).
    var lastError: String?

    /// True while LAContext.evaluatePolicy is in flight, so the lock
    /// screen can disable its button + show progress. Without this, a
    /// double-tap can stack two prompts.
    var isAuthenticating: Bool = false

    func unlock() {
        guard !isAuthenticating else { return }
        // Clear the previous attempt's error before we start a fresh one;
        // otherwise a stale "Cancel" from earlier would linger as red text
        // on the lock screen the next time the user taps Unlock.
        lastError = nil

        let context = LAContext()
        // Use deviceOwnerAuthentication (not biometrics-only) so the user
        // can fall back to passcode if biometrics aren't enrolled or fail.
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = error?.localizedDescription ?? "Authentication unavailable"
            return
        }

        isAuthenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Centmond") { [weak self] success, evalError in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.isUnlocked = true
                    self.lastError = nil
                } else {
                    // Distinguish "user canceled" (LAError.userCancel,
                    // LAError.appCancel, LAError.systemCancel) from real
                    // failures — a quiet cancel shouldn't shout in red.
                    if let la = evalError as? LAError,
                       la.code == .userCancel || la.code == .appCancel || la.code == .systemCancel {
                        self.lastError = nil
                    } else {
                        self.lastError = evalError?.localizedDescription ?? "Could not authenticate"
                    }
                }
            }
        }
    }

    func lock() {
        isUnlocked = false
    }
}
#endif
