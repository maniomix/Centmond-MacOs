import SwiftUI
import SwiftData

@main
struct CentmondApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(for: [
                    Transaction.self,
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
                ])
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)

        #if os(macOS)
        Settings {
            SettingsView()
                .modelContainer(for: [
                    Account.self,
                    BudgetCategory.self,
                ])
        }
        #endif
    }
}
