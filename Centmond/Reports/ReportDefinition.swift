import Foundation

// Phase 1 scaffold: a single declarative value that fully describes a
// report. ReportEngine consumes it, exporters consume the engine's
// ReportResult — on-screen rendering and exported files share one
// source of truth.

nonisolated struct ReportDefinition: Codable, Equatable, Hashable, Sendable {
    var kind: ReportKind
    var range: ReportDateRange
    var groupBy: ReportGroupBy
    var filter: ReportFilter
    var comparison: ReportComparisonMode
    var display: ReportDisplayOptions

    static let `default` = ReportDefinition(
        kind: .incomeVsExpense,
        range: .preset(.last6Months),
        groupBy: .month,
        filter: ReportFilter(),
        comparison: .none,
        display: ReportDisplayOptions()
    )
}

nonisolated enum ReportKind: String, Codable, CaseIterable, Hashable, Sendable {
    case incomeVsExpense
    case spendingByCategory
    case categoryDeepDive
    case merchantLeaderboard
    case cashFlow
    case netWorth
    case budgetPerformance
    case subscriptions
    case goalsProgress
    case recurringActivity
    case annualSummary
    case custom

    var title: String {
        switch self {
        case .incomeVsExpense:     "Income vs Expense"
        case .spendingByCategory:  "Spending by Category"
        case .categoryDeepDive:    "Category Deep-Dive"
        case .merchantLeaderboard: "Merchant Leaderboard"
        case .cashFlow:            "Cash Flow Statement"
        case .netWorth:            "Net Worth Report"
        case .budgetPerformance:   "Budget Performance"
        case .subscriptions:       "Subscriptions Report"
        case .goalsProgress:       "Goals Progress"
        case .recurringActivity:   "Recurring Activity"
        case .annualSummary:       "Annual Summary"
        case .custom:              "Custom Report"
        }
    }

    var symbol: String {
        switch self {
        case .incomeVsExpense:     "arrow.left.arrow.right"
        case .spendingByCategory:  "chart.pie.fill"
        case .categoryDeepDive:    "magnifyingglass.circle"
        case .merchantLeaderboard: "storefront"
        case .cashFlow:            "waveform.path.ecg"
        case .netWorth:            "chart.line.uptrend.xyaxis"
        case .budgetPerformance:   "gauge.with.needle"
        case .subscriptions:       "repeat.circle"
        case .goalsProgress:       "target"
        case .recurringActivity:   "calendar.badge.clock"
        case .annualSummary:       "doc.richtext"
        case .custom:              "slider.horizontal.3"
        }
    }

    var tagline: String {
        switch self {
        case .incomeVsExpense:     "Month-by-month earnings vs spending"
        case .spendingByCategory:  "Where your money goes, ranked"
        case .categoryDeepDive:    "One category, every angle"
        case .merchantLeaderboard: "Top merchants with trend sparklines"
        case .cashFlow:            "Monthly in, out, net — waterfall view"
        case .netWorth:            "Assets, liabilities, and the gap"
        case .budgetPerformance:   "Category × month heatmap vs budget"
        case .subscriptions:       "Active costs, annualized outlay"
        case .goalsProgress:       "Contributions and projected completion"
        case .recurringActivity:   "Expected vs materialized bills"
        case .annualSummary:       "Tax-style yearly rollup"
        case .custom:              "Your filters, your grouping"
        }
    }
}

// MARK: - Date range

nonisolated enum ReportDateRange: Codable, Equatable, Hashable, Sendable {
    case preset(Preset)
    case custom(start: Date, end: Date)

    nonisolated enum Preset: String, Codable, CaseIterable, Hashable, Sendable {
        case mtd, qtd, ytd
        case last30Days, last90Days, last365Days
        case last3Months, last6Months, last12Months
        case thisYear, lastYear
        case allTime

        var label: String {
            switch self {
            case .mtd:           "Month to date"
            case .qtd:           "Quarter to date"
            case .ytd:           "Year to date"
            case .last30Days:    "Last 30 days"
            case .last90Days:    "Last 90 days"
            case .last365Days:   "Last 365 days"
            case .last3Months:   "Last 3 months"
            case .last6Months:   "Last 6 months"
            case .last12Months:  "Last 12 months"
            case .thisYear:      "This year"
            case .lastYear:      "Last year"
            case .allTime:       "All time"
            }
        }

        /// Tight label for inspector chips where full `label` would truncate.
        /// Uses spoken shorthand (MTD/QTD/YTD, 30d, 6M) so scan at a glance.
        var shortLabel: String {
            switch self {
            case .mtd:           "MTD"
            case .qtd:           "QTD"
            case .ytd:           "YTD"
            case .last30Days:    "30d"
            case .last90Days:    "90d"
            case .last365Days:   "365d"
            case .last3Months:   "3M"
            case .last6Months:   "6M"
            case .last12Months:  "12M"
            case .thisYear:      "This yr"
            case .lastYear:      "Last yr"
            case .allTime:       "All time"
            }
        }
    }

    func resolve(now: Date = .now, calendar: Calendar = .current) -> (start: Date, end: Date) {
        switch self {
        case .custom(let s, let e):
            return (min(s, e), max(s, e))
        case .preset(let p):
            return Self.resolve(preset: p, now: now, calendar: calendar)
        }
    }

    private static func resolve(preset: Preset, now: Date, calendar: Calendar) -> (Date, Date) {
        let cal = calendar
        switch preset {
        case .mtd:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return (start, now)
        case .qtd:
            let comps = cal.dateComponents([.year, .month], from: now)
            let quarterStartMonth = ((comps.month! - 1) / 3) * 3 + 1
            var s = DateComponents(); s.year = comps.year; s.month = quarterStartMonth; s.day = 1
            return (cal.date(from: s)!, now)
        case .ytd:
            let start = cal.date(from: cal.dateComponents([.year], from: now))!
            return (start, now)
        case .last30Days:
            return (cal.date(byAdding: .day,   value: -30,  to: now)!, now)
        case .last90Days:
            return (cal.date(byAdding: .day,   value: -90,  to: now)!, now)
        case .last365Days:
            return (cal.date(byAdding: .day,   value: -365, to: now)!, now)
        case .last3Months:
            return (cal.date(byAdding: .month, value: -3,   to: now)!, now)
        case .last6Months:
            return (cal.date(byAdding: .month, value: -6,   to: now)!, now)
        case .last12Months:
            return (cal.date(byAdding: .month, value: -12,  to: now)!, now)
        case .thisYear:
            let start = cal.date(from: cal.dateComponents([.year], from: now))!
            let end = cal.date(byAdding: DateComponents(year: 1, second: -1), to: start)!
            return (start, end)
        case .lastYear:
            let thisStart = cal.date(from: cal.dateComponents([.year], from: now))!
            let start = cal.date(byAdding: .year, value: -1, to: thisStart)!
            let end = cal.date(byAdding: DateComponents(second: -1), to: thisStart)!
            return (start, end)
        case .allTime:
            let start = cal.date(from: DateComponents(year: 1970, month: 1, day: 1))!
            return (start, now)
        }
    }
}

// MARK: - Grouping

nonisolated enum ReportGroupBy: String, Codable, CaseIterable, Hashable, Sendable {
    case day, week, month, quarter, year

    var label: String {
        switch self {
        case .day:     "Day"
        case .week:    "Week"
        case .month:   "Month"
        case .quarter: "Quarter"
        case .year:    "Year"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day:     .day
        case .week:    .weekOfYear
        case .month:   .month
        case .quarter: .quarter
        case .year:    .year
        }
    }
}

// MARK: - Filters

nonisolated struct ReportFilter: Codable, Equatable, Hashable, Sendable {
    var accountIDs: Set<UUID> = []
    var categoryIDs: Set<UUID> = []
    var payees: Set<String> = []
    var tagIDs: Set<UUID> = []
    var householdMemberIDs: Set<UUID> = []
    var direction: Direction = .any
    var includeTransfers: Bool = false
    var minAmount: Decimal? = nil
    var maxAmount: Decimal? = nil
    var onlyReviewed: Bool = false

    nonisolated enum Direction: String, Codable, Hashable, CaseIterable, Sendable {
        case any, income, expense
        var label: String {
            switch self {
            case .any:     "All"
            case .income:  "Income only"
            case .expense: "Expenses only"
            }
        }
    }

    var isEmpty: Bool {
        accountIDs.isEmpty && categoryIDs.isEmpty && payees.isEmpty &&
        tagIDs.isEmpty && householdMemberIDs.isEmpty &&
        direction == .any && !includeTransfers &&
        minAmount == nil && maxAmount == nil && !onlyReviewed
    }
}

// MARK: - Comparison

nonisolated enum ReportComparisonMode: String, Codable, Hashable, CaseIterable, Sendable {
    case none
    case priorPeriod
    case priorYear

    var label: String {
        switch self {
        case .none:        "No comparison"
        case .priorPeriod: "vs prior period"
        case .priorYear:   "vs same period last year"
        }
    }
}

// MARK: - Display

nonisolated struct ReportDisplayOptions: Codable, Equatable, Hashable, Sendable {
    var topN: Int = 10
    var showPercentages: Bool = true
    var showTransactions: Bool = false
    var includeNotes: Bool = false
}
