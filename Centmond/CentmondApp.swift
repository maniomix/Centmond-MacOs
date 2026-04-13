import SwiftUI
import SwiftData

@main
struct CentmondApp: App {
    /// Single shared container so the main window and the Settings scene
    /// read and write to the same SwiftData store. Previously each scene
    /// declared its own `.modelContainer(for:)`, which silently produced
    /// two separate stores — meaning Settings → Delete All Data could not
    /// see (or wipe) any of the user's actual records.
    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Transaction.self,
            TransactionSplit.self,
            Account.self,
            BudgetCategory.self,
            MonthlyBudget.self,
            MonthlyTotalBudget.self,
            Goal.self,
            Subscription.self,
            RecurringTransaction.self,
            Insight.self,
            HouseholdMember.self,
            Tag.self,
            SmartFolder.self,
            ChatSession.self,
            ChatMessageRecord.self,
        ])
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)

        #if os(macOS)
        Settings {
            SettingsView()
        }
        .modelContainer(sharedModelContainer)
        #endif
    }
}
