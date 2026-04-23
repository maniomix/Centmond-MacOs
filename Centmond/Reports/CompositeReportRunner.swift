import Foundation
import SwiftData

// Runs every enabled section against a single fetched Inputs snapshot,
// so the preview + every export share one pass over SwiftData. Sections
// render in the canonical `ReportSection.orderedAll` order regardless
// of toggle insertion order.

struct CompositeReport: Equatable, Hashable {
    var range: ReportDateRange
    var resolvedStart: Date
    var resolvedEnd: Date
    var filter: ReportFilter
    var sections: [ReportSection]                  // enabled, in canonical order
    var results: [ReportSection: ReportResult]
    var transactionCount: Int
    var currencyCode: String
    var generatedAt: Date
}

@MainActor
enum CompositeReportRunner {

    static func run(
        range: ReportDateRange,
        filter: ReportFilter,
        sections: Set<ReportSection>,
        context: ModelContext,
        currencyCode: String = "USD",
        now: Date = .now
    ) -> CompositeReport {
        // Scrub tombstoned category refs before compute. Launch-time repair
        // only covers app-start state; categories deleted mid-session leave
        // stale FKs on Transaction/TransactionSplit/RecurringTransaction
        // that crash the engine when accessed. Running here is cheap and
        // keeps the composite path independent of launch order.
        CategoryReferenceRepair.run(context: context)

        let inputs = ReportEngine.Inputs(
            transactions:        fetch(Transaction.self,         context: context),
            accounts:            fetch(Account.self,             context: context),
            categories:          fetch(BudgetCategory.self,      context: context),
            netWorthSnapshots:   fetch(NetWorthSnapshot.self,    context: context),
            subscriptions:       fetch(Subscription.self,        context: context),
            recurring:           fetch(RecurringTransaction.self, context: context),
            goals:               fetch(Goal.self,                context: context),
            goalContributions:   fetch(GoalContribution.self,    context: context),
            monthlyBudgets:      fetch(MonthlyBudget.self,       context: context),
            monthlyTotalBudgets: fetch(MonthlyTotalBudget.self,  context: context),
            currencyCode: currencyCode,
            now: now
        )

        // Clamp "All time" (and any range that reaches before the earliest
        // transaction) to the real data floor. Otherwise the engine iterates
        // calendar buckets from 1970 → now = hundreds of empty buckets per
        // section, drives massive sparkline arrays on the merchant
        // leaderboard, and freezes/crashes on big heatmaps.
        let effectiveRange = clamp(range: range, inputs: inputs, now: now)

        let (start, end) = effectiveRange.resolve(now: now)
        let ordered = ReportSection.orderedAll.filter { sections.contains($0) }

        var results: [ReportSection: ReportResult] = [:]
        for section in ordered {
            let def = section.definition(range: effectiveRange, filter: filter)
            results[section] = ReportEngine.run(def, inputs: inputs)
        }

        // Count once from the engine's own filter via any section; fall back
        // to a direct filter pass if no sections are enabled.
        let txCount: Int = {
            if let any = results.values.first { return any.summary.transactionCount }
            return inputs.transactions.filter { $0.date >= start && $0.date <= end }.count
        }()

        return CompositeReport(
            range: effectiveRange,
            resolvedStart: start,
            resolvedEnd: end,
            filter: filter,
            sections: ordered,
            results: results,
            transactionCount: txCount,
            currencyCode: currencyCode,
            generatedAt: now
        )
    }

    private static func fetch<T: PersistentModel>(_: T.Type, context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    /// Only `.allTime` is clamped — it's the one preset whose default
    /// resolution (1970 → now) blows up the bucket-iterating builders
    /// (merchant sparklines, budget heatmap). Every other preset is
    /// honored literally so adjacent ranges (6M vs 12M vs YTD) stay
    /// visually distinct even when the user's data doesn't fill them.
    private static func clamp(
        range: ReportDateRange,
        inputs: ReportEngine.Inputs,
        now: Date
    ) -> ReportDateRange {
        guard case .preset(.allTime) = range else { return range }

        guard let earliest = inputs.transactions.map(\.date).min() else {
            return .custom(start: now, end: now)
        }
        return .custom(start: earliest, end: now)
    }
}
