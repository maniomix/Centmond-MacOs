import SwiftUI

struct ContentRouter: View {
    let screen: Screen
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            switch screen {
            case .aiChat:
                AIChatView(isEmbedded: true)
            case .aiPredictions:
                AIPredictionView()
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
            case .settings:
                InAppSettingsView()
            }
        }
        .screenBackground()
        .navigationTitle(screen.displayName)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // AI Chat has its own toolbar — keep this empty for it
                if screen == .aiChat {
                    Color.clear.frame(height: 1)
                } else {
                    screenToolbarContent
                }
            }
        }
    }

    // MARK: - Per-Screen Toolbar Content

    @ViewBuilder
    private var screenToolbarContent: some View {
        HStack(spacing: 12) {
            Image(systemName: screen.iconName)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.accent)

            Text(screen.displayName)
                .font(CentmondTheme.Typography.bodyMedium.weight(.semibold))
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .fixedSize()

            screenSubtitle
        }
        .padding(.horizontal, 15)
        .animation(.none, value: router.selectedMonth)
    }

    @ViewBuilder
    private var screenSubtitle: some View {
        let subtitleStyle = Font.system(size: 11, weight: .medium)
        let subtitleColor = CentmondTheme.Colors.textTertiary

        switch screen {
        case .dashboard, .transactions, .budget:
            Text(monthLabel)
                .font(subtitleStyle)
                .foregroundStyle(subtitleColor)
                .fixedSize()

        case .forecasting:
            Text("Projection")
                .font(subtitleStyle)
                .foregroundStyle(subtitleColor)

        case .aiPredictions:
            Text("AI-Powered")
                .font(subtitleStyle)
                .foregroundStyle(subtitleColor)

        case .settings:
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(subtitleStyle)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }

        default:
            EmptyView()
        }
    }

    private var monthLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: router.selectedMonth)
    }
}

