import SwiftUI
import SwiftData

@main
struct CentmondApp: App {
    @NSApplicationDelegateAdaptor(CentmondAppDelegate.self) private var appDelegate

    /// Single shared container so the main window and the Settings scene
    /// read and write to the same SwiftData store. Previously each scene
    /// declared its own `.modelContainer(for:)`, which silently produced
    /// two separate stores — meaning Settings → Delete All Data could not
    /// see (or wipe) any of the user's actual records.
    let sharedModelContainer: ModelContainer = {
        // Pre-flight: if the previous session set the "nuke store" flag
        // (Settings → Erase All Data), delete the SwiftData store files
        // from disk BEFORE creating the container. In-process deletes
        // can't clear the tombstone cache reliably, so we short-circuit by
        // starting the next launch with a blank store.
        StoreNuke.runIfRequested()

        // Settings always opens on Workspace after a fresh launch. The
        // in-session value still persists via @AppStorage so tabbing
        // between screens preserves the selected domain, but closing the
        // app and reopening it lands on Workspace — the home of everyday
        // preferences (currency, start of week, layout, behavior).
        UserDefaults.standard.set(
            SettingsDomain.workspace.rawValue,
            forKey: "settings.selectedDomain"
        )

        let schema = Schema([
            Transaction.self,
            TransactionSplit.self,
            Account.self,
            BudgetCategory.self,
            MonthlyBudget.self,
            MonthlyTotalBudget.self,
            Goal.self,
            GoalContribution.self,
            GoalAllocationRule.self,
            Subscription.self,
            SubscriptionCharge.self,
            SubscriptionPriceChange.self,
            DismissedDetection.self,
            DismissedInsight.self,
            RecurringTransaction.self,
            HouseholdMember.self,
            HouseholdGroup.self,
            HouseholdSettlement.self,
            ExpenseShare.self,
            Tag.self,
            SmartFolder.self,
            ChatSession.self,
            ChatMessageRecord.self,
            NetWorthSnapshot.self,
            AccountBalancePoint.self,
            ScheduledReport.self,
        ])
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        // Phase 3 — hand the shared container to the Quick Add panel
        // so its floating flow writes into the same SwiftData store.
        QuickAddContainer.shared = sharedModelContainer
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            // "Help → Replay Welcome Tour" — AppShell owns the AppRouter
            // so we hand this off via NotificationCenter rather than
            // trying to inject an Observable into a CommandGroup.
            CommandGroup(after: .help) {
                Divider()
                Button("Replay Welcome Tour") {
                    NotificationCenter.default.post(name: .replayOnboarding, object: nil)
                }
            }

            // Phase 11 — retire the macOS prefs TabView. ⌘, now navigates
            // the main window to the in-app Settings shell so there's one
            // Settings surface instead of two drifting copies.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    NotificationCenter.default.post(name: .openInAppSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Phase 1 — owns the menu bar status item for the app's lifetime.
final class CentmondAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarController.shared.start()
        QuickAddHotkeyService.shared.start()
        QuickAddCoordinator.shared.start()
    }
}

