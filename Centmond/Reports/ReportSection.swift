import Foundation

// The new single-screen report is composed of these 9 fixed sections.
// Each section maps to a canonical ReportDefinition (reusing the existing
// kind-based engine under the hood), so the rewrite doesn't touch the
// engine, body types, or builders — only the orchestration on top.

nonisolated enum ReportSection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case summary
    case cashFlow
    case categories
    case merchants
    case budgets
    case subscriptions
    case recurring
    case goals
    case netWorth

    nonisolated var id: String { rawValue }

    /// Fixed render + export order.
    nonisolated static let orderedAll: [ReportSection] = [
        .summary, .cashFlow, .categories, .merchants,
        .budgets, .subscriptions, .recurring, .goals, .netWorth
    ]

    nonisolated var title: String {
        switch self {
        case .summary:       "Summary"
        case .cashFlow:      "Cash Flow"
        case .categories:    "Categories"
        case .merchants:     "Merchants"
        case .budgets:       "Budgets"
        case .subscriptions: "Subscriptions"
        case .recurring:     "Recurring"
        case .goals:         "Goals"
        case .netWorth:      "Net Worth"
        }
    }

    nonisolated var subtitle: String {
        switch self {
        case .summary:       "Income, expenses, and net for the selected range"
        case .cashFlow:      "Month-by-month money in, out, net"
        case .categories:    "Where spending went, ranked"
        case .merchants:     "Top merchants with trend sparklines"
        case .budgets:       "Category × month heatmap against budget"
        case .subscriptions: "Active costs and annualized outlay"
        case .recurring:     "Repeating bills and income, normalized monthly"
        case .goals:         "Progress toward every goal"
        case .netWorth:      "Assets, liabilities, and net worth trajectory"
        }
    }

    nonisolated var symbol: String {
        switch self {
        case .summary:       "chart.bar.fill"
        case .cashFlow:      "arrow.left.arrow.right"
        case .categories:    "chart.pie.fill"
        case .merchants:     "storefront"
        case .budgets:       "gauge.with.needle"
        case .subscriptions: "repeat.circle"
        case .recurring:     "calendar.badge.clock"
        case .goals:         "target"
        case .netWorth:      "chart.line.uptrend.xyaxis"
        }
    }

    /// Maps a section to the legacy `ReportKind` that produces its body.
    /// Once the engine is fully rewritten (later phase), this indirection
    /// goes away — each section will own its own builder directly.
    nonisolated var kind: ReportKind {
        switch self {
        case .summary:       return .incomeVsExpense
        case .cashFlow:      return .cashFlow
        case .categories:    return .spendingByCategory
        case .merchants:     return .merchantLeaderboard
        case .budgets:       return .budgetPerformance
        case .subscriptions: return .subscriptions
        case .recurring:     return .recurringActivity
        case .goals:         return .goalsProgress
        case .netWorth:      return .netWorth
        }
    }

    /// Default grouping for this section when the user hasn't overridden it.
    nonisolated var defaultGroupBy: ReportGroupBy {
        switch self {
        case .summary, .cashFlow, .budgets, .netWorth: return .month
        default: return .month
        }
    }

    /// Builds a canonical ReportDefinition for this section from the
    /// user-chosen range and filter. `display.topN` is boosted for
    /// merchants so the leaderboard is worth scrolling.
    nonisolated func definition(range: ReportDateRange, filter: ReportFilter) -> ReportDefinition {
        var display = ReportDisplayOptions()
        if self == .merchants { display.topN = 25 }
        return ReportDefinition(
            kind: kind,
            range: range,
            groupBy: defaultGroupBy,
            filter: filter,
            comparison: .none,
            display: display
        )
    }
}
