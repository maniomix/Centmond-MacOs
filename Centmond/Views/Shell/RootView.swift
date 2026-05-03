import SwiftUI
import SwiftData

/// Root view that gates access through onboarding and app lock before showing the main shell.
struct RootView: View {
    // Onboarding gating lives on AppRouter now (@Observable state +
    // canonical UserDefaults flag). RootView's leftover @AppStorage for
    // "hasCompletedOnboarding" was removed as dead in Phase 6 polish —
    // along with the legacy 4-step OnboardingView. The real overlay is
    // presented from AppShell via router.isOnboardingVisible.
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appPasscode") private var storedPasscode = ""
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var authManager: AuthManager

    /// Lives at the root so the same instance can be re-locked from sleep
    /// notifications and the inactivity timer inside `AppLockController`.
    @State private var lockController = AppLockController()

    /// Shown once per process launch. The animation lasts ~2.7s and then
    /// fades out to reveal the real shell.
    @State private var splashFinished: Bool = false

    var body: some View {
        ZStack {
            // Real shell ALWAYS mounts immediately so its heavy first-render
            // (SwiftData queries, AppRouter, etc.) runs in parallel with the
            // splash animation. Without this, the splash's final frame
            // appeared to freeze until AppShell finished initializing.
            Group {
                // Outermost gate: cloud auth. Until session is restored OR
                // the user signs in, AppShell never renders.
                if authManager.isCheckingSession {
                    // Brief gap while supabase-swift restores a Keychain session.
                    // The splash sits on top of this, so most users never see it.
                    Color.clear
                } else if !authManager.isAuthenticated {
                    AuthRouterView()
                } else if appLockEnabled && !storedPasscode.isEmpty && !lockController.isUnlocked {
                    LockScreenView {
                        lockController.unlock()
                    }
                } else {
                    AppShell()
                        .onAppear { lockController.notifyUserActivity() }
                }
            }

            if !splashFinished {
                SplashView { splashFinished = true }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: splashFinished)
        .environment(lockController)
        .animation(CentmondTheme.Motion.default, value: lockController.isUnlocked)
        // Cloud sync lifecycle. Starts when the user is authenticated +
        // local app-lock (if any) is unlocked. Stops on sign-out.
        .task(id: authManager.isAuthenticated) {
            if authManager.isAuthenticated {
                CloudSyncCoordinator.shared.start(context: modelContext)
            } else {
                CloudSyncCoordinator.shared.stop()
            }
        }
        .task {
            // Seed default budget categories before any repair sweep so
            // category-reference repairs operate against a complete set.
            DefaultCategoriesSeeder.seedIfNeeded(context: modelContext)
            GoalContributionService.migrateLegacyBalances(context: modelContext)
            // NOTE: `OrphanRecurringSweep.runOnce` was wired here but crashed
            // at launch — `context.save()` after mass-nulling a tombstoned
            // FK still faulted in SwiftData's deletion walker. Disabled;
            // user should use Settings → Data → Erase All Data for a fresh
            // start, which in turn nukes the store file directly.
            CategoryReferenceRepair.run(context: modelContext)
            NetWorthReferenceRepair.run(context: modelContext)
            // Run transaction-ref repair BEFORE HouseholdReferenceRepair so
            // orphan ExpenseShare rows referencing dead Transactions are
            // killed first — otherwise HouseholdReferenceRepair's
            // `share.parentTransaction == nil` check misses them (they
            // have a dangling ref, not a nil one).
            TransactionReferenceRepair.run(context: modelContext)
            HouseholdReferenceRepair.run(context: modelContext)
        }
    }
}
