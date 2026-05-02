import Foundation
import SwiftData

/// Single write path for goal progress. All code that used to do
/// `goal.currentAmount += amount` must route through here so the contribution
/// history stays authoritative and the cached `currentAmount` stays in sync.
enum GoalContributionService {

    // MARK: - Writes

    @discardableResult
    static func addContribution(
        to goal: Goal,
        amount: Decimal,
        kind: GoalContributionKind = .manual,
        date: Date = .now,
        note: String? = nil,
        sourceTransactionID: UUID? = nil,
        context: ModelContext
    ) -> GoalContribution {
        let contribution = GoalContribution(
            amount: amount,
            date: date,
            kind: kind,
            note: note,
            sourceTransactionID: sourceTransactionID,
            goal: goal
        )
        context.insert(contribution)
        goal.contributions.append(contribution)
        goal.currentAmount += amount
        goal.updatedAt = .now
        autoTransitionStatus(goal)
        return contribution
    }

    static func removeContribution(_ contribution: GoalContribution, context: ModelContext) {
        guard let goal = contribution.goal else {
            context.delete(contribution)
            return
        }
        goal.currentAmount -= contribution.amount
        if goal.currentAmount < 0 { goal.currentAmount = 0 }
        goal.updatedAt = .now
        context.delete(contribution)
        autoTransitionStatus(goal)
    }

    /// Delete every contribution that originated from a given transaction —
    /// called when a Transaction is deleted so goal balances don't drift.
    static func removeContributions(forTransactionID txID: UUID, context: ModelContext) {
        let descriptor = FetchDescriptor<GoalContribution>(
            predicate: #Predicate { $0.sourceTransactionID == txID }
        )
        guard let matches = try? context.fetch(descriptor) else { return }
        for c in matches { removeContribution(c, context: context) }
    }

    // MARK: - Lookups

    /// Sum of contributions linked to a single Transaction. Used by row + chart
    /// surfaces that need to show "$X went to goals, $Y left to spend".
    static func totalAllocated(forTransactionID txID: UUID, context: ModelContext) -> Decimal {
        let descriptor = FetchDescriptor<GoalContribution>(
            predicate: #Predicate { $0.sourceTransactionID == txID }
        )
        guard let matches = try? context.fetch(descriptor) else { return 0 }
        return matches.reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// 1-entry cache for the dashboard cash-flow tooltip, which calls this
    /// function on every hover frame (~60 Hz). Without the cache each hover
    /// frame triggered TWO unbounded SwiftData fetches.
    private static var lastIncomeAllocation: (day: Date, value: Decimal, stamp: Date)?

    /// Sum of contributions whose source transaction is an income transaction
    /// dated on the given calendar day. Used by the dashboard tooltip.
    static func totalAllocatedFromIncome(on day: Date, context: ModelContext) -> Decimal {
        let cal = Calendar.current
        guard let dayStart = cal.date(from: cal.dateComponents([.year, .month, .day], from: day)),
              let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else {
            return 0
        }

        // Hover cache — keyed by dayStart with a 1s TTL. Sits inside a single
        // hover session (chart hover stays on one day, fires onContinuousHover
        // at ~60 Hz). Pan to a different day → miss + refetch. Mutate goals
        // mid-hover → tooltip stays stale up to 1s, an acceptable tradeoff
        // versus paying two SwiftData fetches per frame.
        if let last = lastIncomeAllocation,
           last.day == dayStart,
           Date().timeIntervalSince(last.stamp) < 1.0 {
            return last.value
        }

        let txDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate {
                $0.isIncome && !$0.isTransfer && $0.date >= dayStart && $0.date < dayEnd
            }
        )
        guard let txs = try? context.fetch(txDescriptor), !txs.isEmpty else {
            lastIncomeAllocation = (dayStart, 0, Date())
            return 0
        }
        let txIDs = Set(txs.map { $0.id })
        // SwiftData `#Predicate` only allows a single expression, so a
        // proper `txIDs.contains(c.sourceTransactionID!)` scope isn't
        // expressible here. Fetch all and filter in-memory — the hover
        // cache above means this only runs on day-change, not per frame.
        let allDescriptor = FetchDescriptor<GoalContribution>()
        guard let all = try? context.fetch(allDescriptor) else {
            lastIncomeAllocation = (dayStart, 0, Date())
            return 0
        }
        let result = all.reduce(Decimal.zero) { acc, c in
            guard let src = c.sourceTransactionID, txIDs.contains(src) else { return acc }
            return acc + c.amount
        }
        lastIncomeAllocation = (dayStart, result, Date())
        return result
    }

    // MARK: - Integrity

    /// Recompute `goal.currentAmount` from the contribution list. Safe to call
    /// any time — useful after a bulk import or if a bug is suspected.
    static func rebuildCache(for goal: Goal) {
        let sum = goal.contributions.reduce(Decimal.zero) { $0 + $1.amount }
        goal.currentAmount = sum
        goal.updatedAt = .now
        autoTransitionStatus(goal)
    }

    static func rebuildAllCaches(context: ModelContext) {
        guard let goals = try? context.fetch(FetchDescriptor<Goal>()) else { return }
        for g in goals { rebuildCache(for: g) }
    }

    // MARK: - Migration

    /// One-shot migration: for goals that have a non-zero `currentAmount` but
    /// no contribution history, synthesize a single `.manual` seed contribution
    /// so the new model matches the legacy balance without losing money.
    static func migrateLegacyBalances(context: ModelContext) {
        guard let goals = try? context.fetch(FetchDescriptor<Goal>()) else { return }
        var changed = false
        for goal in goals where goal.contributions.isEmpty && goal.currentAmount > 0 {
            let seed = GoalContribution(
                amount: goal.currentAmount,
                date: goal.createdAt,
                kind: .manual,
                note: "Imported from legacy balance",
                goal: goal
            )
            context.insert(seed)
            goal.contributions.append(seed)
            changed = true
        }
        if changed { context.persist() }
    }

    // MARK: - Internal

    private static func autoTransitionStatus(_ goal: Goal) {
        if goal.status == .active, goal.currentAmount >= goal.targetAmount {
            goal.status = .completed
        } else if goal.status == .completed, goal.currentAmount < goal.targetAmount {
            goal.status = .active
        }
    }
}
