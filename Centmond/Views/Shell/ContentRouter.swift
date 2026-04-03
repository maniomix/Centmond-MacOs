import SwiftUI

struct ContentRouter: View {
    let screen: Screen

    var body: some View {
        Group {
            switch screen {
            case .dashboard:
                DashboardView()
            case .transactions:
                TransactionsView()
            case .budget:
                BudgetView()
            case .accounts:
                AccountsView()
            case .goals:
                GoalsView()
            case .subscriptions:
                SubscriptionsView()
            case .recurring:
                RecurringView()
            case .forecasting:
                ForecastingView()
            case .insights:
                InsightsView()
            case .netWorth:
                NetWorthView()
            case .reports:
                ReportsView()
            case .reviewQueue:
                ReviewQueueView()
            case .household:
                HouseholdView()
            }
        }
        .screenBackground()
        .navigationTitle(screen.displayName)
        .toolbarTitleDisplayMode(.inline)
    }
}

