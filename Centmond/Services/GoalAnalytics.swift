import Foundation
import SwiftData

/// Pure read-only derivations from a Goal's contribution history. Used by
/// the Goals grid cards, the goal inspector timeline, and the dashboard to
/// surface richer information than the raw `currentAmount` cache offers.
enum GoalAnalytics {

    /// Sum of contributions dated in the current calendar month.
    static func thisMonthContribution(_ goal: Goal) -> Decimal {
        let cal = Calendar.current
        let now = Date()
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        return goal.contributions.reduce(Decimal.zero) { acc, c in
            guard cal.component(.year, from: c.date) == y,
                  cal.component(.month, from: c.date) == m else { return acc }
            return acc + c.amount
        }
    }

    /// Rolling average monthly contribution over the last `months` complete
    /// calendar months (excluding the current month so partial data doesn't
    /// drag the average down). Returns 0 when the goal is too young.
    static func averageMonthlyContribution(_ goal: Goal, months: Int = 3) -> Decimal {
        guard months > 0 else { return 0 }
        let cal = Calendar.current
        let now = Date()
        guard let windowStart = cal.date(
            byAdding: .month,
            value: -months,
            to: cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        ) else { return 0 }
        let monthStartNow = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        let total = goal.contributions
            .filter { $0.date >= windowStart && $0.date < monthStartNow }
            .reduce(Decimal.zero) { $0 + $1.amount }
        return total / Decimal(months)
    }

    /// Per-kind sum, suitable for a funding-source breakdown badge row.
    static func breakdownByKind(_ goal: Goal) -> [GoalContributionKind: Decimal] {
        var out: [GoalContributionKind: Decimal] = [:]
        for c in goal.contributions {
            out[c.kind, default: 0] += c.amount
        }
        return out
    }

    /// Projected completion date assuming the goal keeps receiving
    /// `averageMonthlyContribution(goal, 3)` per month. Returns nil when the
    /// goal is already complete, has no target gap, or the average is zero.
    static func projectedCompletion(_ goal: Goal) -> Date? {
        let gap = goal.targetAmount - goal.currentAmount
        guard gap > 0 else { return nil }
        let avg = averageMonthlyContribution(goal, months: 3)
        guard avg > 0 else { return nil }
        let monthsNeededDecimal = gap / avg
        let monthsNeeded = Int((monthsNeededDecimal as NSDecimalNumber).doubleValue.rounded(.up))
        guard monthsNeeded > 0, monthsNeeded < 600 else { return nil }
        return Calendar.current.date(byAdding: .month, value: monthsNeeded, to: .now)
    }

    // MARK: - Unallocated income (for Goals view banner)

    /// Income transactions in the current calendar month that have no
    /// associated GoalContribution via sourceTransactionID. Used by the
    /// banner to nudge users to allocate idle income.
    static func unallocatedIncomeThisMonth(context: ModelContext) -> (total: Decimal, count: Int) {
        let cal = Calendar.current
        let now = Date()
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)),
              let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else {
            return (0, 0)
        }
        let txDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate {
                $0.isIncome && !$0.isTransfer && $0.date >= monthStart && $0.date < monthEnd
            }
        )
        guard let incomeTxs = try? context.fetch(txDescriptor), !incomeTxs.isEmpty else {
            return (0, 0)
        }
        let contribDescriptor = FetchDescriptor<GoalContribution>()
        let linkedIDs: Set<UUID> = {
            guard let all = try? context.fetch(contribDescriptor) else { return [] }
            return Set(all.compactMap { $0.sourceTransactionID })
        }()
        var total = Decimal.zero
        var count = 0
        for tx in incomeTxs where !linkedIDs.contains(tx.id) {
            total += tx.amount
            count += 1
        }
        return (total, count)
    }
}
