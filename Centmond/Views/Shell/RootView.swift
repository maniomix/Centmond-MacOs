import SwiftUI
import SwiftData

/// Root view that gates access through onboarding and app lock before showing the main shell.
struct RootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appPasscode") private var storedPasscode = ""
    @Environment(\.modelContext) private var modelContext

    /// Lives at the root so the same instance can be re-locked from sleep
    /// notifications and the inactivity timer inside `AppLockController`.
    @State private var lockController = AppLockController()

    var body: some View {
        Group {
            if appLockEnabled && !storedPasscode.isEmpty && !lockController.isUnlocked {
                LockScreenView {
                    lockController.unlock()
                }
            } else {
                // Onboarding is now an overlay inside AppShell rather than
                // a root-level gate. This lets the tour share the app's
                // real sheets (CSV import, New Goal) instead of stubbing
                // them. First-run presentation is handled inside AppShell
                // via `router.presentOnboardingIfNeeded(isEmpty:)`.
                AppShell()
                    .onAppear { lockController.notifyUserActivity() }
            }
        }
        .environment(lockController)
        .animation(CentmondTheme.Motion.default, value: lockController.isUnlocked)
        .task {
            GoalContributionService.migrateLegacyBalances(context: modelContext)
        }
    }
}
