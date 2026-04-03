import Foundation

enum InsightType: String, Codable, CaseIterable, Identifiable {
    case spendingAnomaly
    case budgetAlert
    case subscriptionChange
    case savingsOpportunity
    case goalProgress
    case netWorthMilestone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spendingAnomaly: "Spending Anomaly"
        case .budgetAlert: "Budget Alert"
        case .subscriptionChange: "Subscription Change"
        case .savingsOpportunity: "Savings Opportunity"
        case .goalProgress: "Goal Progress"
        case .netWorthMilestone: "Net Worth Milestone"
        }
    }

    var iconName: String {
        switch self {
        case .spendingAnomaly: "exclamationmark.triangle.fill"
        case .budgetAlert: "chart.pie.fill"
        case .subscriptionChange: "arrow.triangle.2.circlepath"
        case .savingsOpportunity: "lightbulb.fill"
        case .goalProgress: "target"
        case .netWorthMilestone: "star.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .spendingAnomaly: "F59E0B"
        case .budgetAlert: "EF4444"
        case .subscriptionChange: "3B82F6"
        case .savingsOpportunity: "22C55E"
        case .goalProgress: "22C55E"
        case .netWorthMilestone: "8B5CF6"
        }
    }
}
