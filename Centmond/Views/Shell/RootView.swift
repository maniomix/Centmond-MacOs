import SwiftUI

/// Root view that gates access through onboarding and app lock before showing the main shell.
struct RootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appPasscode") private var storedPasscode = ""

    @State private var isUnlocked = false

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                OnboardingView()
            } else if appLockEnabled && !storedPasscode.isEmpty && !isUnlocked {
                LockScreenView {
                    isUnlocked = true
                }
            } else {
                AppShell()
            }
        }
        .animation(CentmondTheme.Motion.default, value: hasCompletedOnboarding)
        .animation(CentmondTheme.Motion.default, value: isUnlocked)
    }
}
