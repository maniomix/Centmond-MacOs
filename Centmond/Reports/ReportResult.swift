import Foundation

// Single typed result shape shared by the preview UI and every exporter.
// Each kind-specific payload is carried in `body`; `summary` holds the
// universal header (title, range, KPIs) so exporters can render a
// consistent cover without switching on kind.

struct ReportResult: Equatable, Hashable {
    var definition: ReportDefinition
    var summary: ReportSummary
    var body: ReportBody
    var generatedAt: Date
}

struct ReportSummary: Equatable, Hashable {
    var title: String
    var subtitle: String?
    var rangeStart: Date
    var rangeEnd: Date
    var kpis: [ReportKPI]
    var transactionCount: Int
    var currencyCode: String
}

struct ReportKPI: Equatable, Hashable, Identifiable {
    var id: String                    // stable key for exporter + hover linkage
    var label: String
    var value: Decimal
    var valueFormat: ValueFormat
    var tone: Tone
    var deltaVsBaseline: Decimal?     // populated when comparison mode is on

    enum ValueFormat: String, Hashable { case currency, percent, integer }
    enum Tone: String, Hashable { case neutral, positive, negative, warning }
}

enum ReportBody: Equatable, Hashable {
    case periodSeries(PeriodSeries)
    case categoryBreakdown(CategoryBreakdown)
    case merchantLeaderboard(MerchantLeaderboard)
    case heatmap(Heatmap)
    case netWorth(NetWorthBody)
    case subscriptionRoster(SubscriptionRoster)
    case recurringRoster(RecurringRoster)
    case goalsProgress(GoalsProgressBody)
    case empty(reason: EmptyReason)

    enum EmptyReason: String, Hashable {
        case noTransactionsInRange
        case allFilteredOut
        case missingData
    }
}

// MARK: - Period series (Income vs Expense, Cash Flow, Monthly Trend…)

struct PeriodSeries: Equatable, Hashable {
    var buckets: [Bucket]
    var totals: Totals
    var baselineBuckets: [Bucket]?    // prior-period / prior-year comparison

    struct Bucket: Equatable, Hashable, Identifiable {
        var id: String                // stable key: e.g. "2026-03"
        var label: String             // "Mar 26"
        var start: Date
        var end: Date
        var income: Decimal
        var expense: Decimal
        var transactionCount: Int
        var net: Decimal { income - expense }
    }

    struct Totals: Equatable, Hashable {
        var income: Decimal
        var expense: Decimal
        var net: Decimal { income - expense }
        var averagePerBucket: Decimal
        var savingsRate: Double?      // nil when income == 0
    }
}

// MARK: - Category breakdown

struct CategoryBreakdown: Equatable, Hashable {
    var slices: [Slice]
    var uncategorizedAmount: Decimal
    var totalAmount: Decimal

    struct Slice: Equatable, Hashable, Identifiable {
        var id: String                // category UUID or "uncategorized"
        var name: String
        var colorHex: String?
        var amount: Decimal
        var transactionCount: Int
        var percentOfTotal: Double
        var deltaVsBaseline: Decimal?
        var sparkline: [Decimal]?     // per-bucket amounts, optional
    }
}

// MARK: - Merchant leaderboard

struct MerchantLeaderboard: Equatable, Hashable {
    var rows: [Row]
    var totalAmount: Decimal

    struct Row: Equatable, Hashable, Identifiable {
        var id: String                // normalized payee key
        var displayName: String
        var amount: Decimal
        var transactionCount: Int
        var averageAmount: Decimal
        var percentOfTotal: Double
        var firstSeen: Date
        var lastSeen: Date
        var sparkline: [Decimal]
    }
}

// MARK: - Heatmap (budget performance, seasonality)

struct Heatmap: Equatable, Hashable {
    var rowLabels: [String]
    var columnLabels: [String]
    var cells: [Cell]
    var valueFormat: ReportKPI.ValueFormat

    struct Cell: Equatable, Hashable {
        var row: Int
        var column: Int
        var value: Decimal
        var baseline: Decimal?        // e.g. monthly budget for budget-perf
        var overBudget: Bool
    }
}

// MARK: - Subscription roster

struct SubscriptionRoster: Equatable, Hashable {
    var rows: [Row]
    var totalMonthly: Decimal
    var totalAnnual: Decimal
    var activeCount: Int
    var pausedCount: Int
    var cancelledCount: Int

    struct Row: Equatable, Hashable, Identifiable {
        var id: String
        var serviceName: String
        var categoryName: String
        var statusLabel: String
        var monthlyCost: Decimal
        var annualCost: Decimal
        var nextPaymentDate: Date?
        var firstChargeDate: Date?
        var isTrial: Bool
    }
}

// MARK: - Recurring roster

struct RecurringRoster: Equatable, Hashable {
    var expenseRows: [Row]
    var incomeRows: [Row]
    var totalMonthlyExpense: Decimal
    var totalMonthlyIncome: Decimal

    struct Row: Equatable, Hashable, Identifiable {
        var id: String
        var name: String
        var amount: Decimal
        var frequencyLabel: String
        var normalizedMonthly: Decimal
        var isIncome: Bool
        var nextOccurrence: Date
        var isActive: Bool
    }
}

// MARK: - Goals progress

struct GoalsProgressBody: Equatable, Hashable {
    var rows: [Row]
    var totalTarget: Decimal
    var totalCurrent: Decimal
    var contributionsInRange: Decimal

    struct Row: Equatable, Hashable, Identifiable {
        var id: String
        var name: String
        var icon: String
        var currentAmount: Decimal
        var targetAmount: Decimal
        var percentComplete: Double
        var monthlyContribution: Decimal?
        var projectedCompletion: Date?
        var contributionsInRange: Decimal
    }
}

// MARK: - Net worth

struct NetWorthBody: Equatable, Hashable {
    var snapshots: [Point]
    var startingNetWorth: Decimal
    var endingNetWorth: Decimal
    var assetsEnd: Decimal
    var liabilitiesEnd: Decimal

    struct Point: Equatable, Hashable, Identifiable {
        var id: Date { date }
        var date: Date
        var assets: Decimal
        var liabilities: Decimal
        var netWorth: Decimal
    }
}
