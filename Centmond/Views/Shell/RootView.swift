import SwiftUI

/// Root view that gates access through onboarding and app lock before showing the main shell.
struct RootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appPasscode") private var storedPasscode = ""

    /// Lives at the root so the same instance can be re-locked from sleep
    /// notifications and the inactivity timer inside `AppLockController`.
    @State private var lockController = AppLockController()

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                OnboardingView()
            } else if appLockEnabled && !storedPasscode.isEmpty && !lockController.isUnlocked {
                LockScreenView {
                    lockController.unlock()
                }
            } else {
                AppShell()
                    .onAppear { lockController.notifyUserActivity() }
            }
        }
        .environment(lockController)
        .animation(CentmondTheme.Motion.default, value: hasCompletedOnboarding)
        .animation(CentmondTheme.Motion.default, value: lockController.isUnlocked)
    }
}
