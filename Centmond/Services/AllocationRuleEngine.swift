import Foundation
import SwiftData

/// One proposed contribution from the rule engine. Not persisted — only
/// materialized into a `GoalContribution` when the user confirms in the
/// preview sheet. `amount` is mutable so the preview UI can edit it before
/// applying.
struct AllocationProposal: Identifiable {
    let id = UUID()
    let rule: GoalAllocationRule
    let goal: Goal
    var amount: Decimal
    var enabled: Bool = true
}

/// Evaluates active `GoalAllocationRule`s against an income Transaction and
/// returns capped proposals. The engine is pure — it does not mutate
/// SwiftData. Caller is responsible for:
///   1. showing the preview UI
///   2. writing confirmed proposals via `GoalContributionService`
///      with `kind: .autoRule` and `sourceTransactionID: tx.id`.
enum AllocationRuleEngine {

    /// Build proposals for an income transaction. Subtract any contributions
    /// already earmarked (e.g. manual allocations made in the sheet) from the
    /// cap so rules never push total above 100% of the income.
    static func proposals(
        for transaction: Transaction,
        alreadyAllocated: Decimal = 0,
        context: ModelContext
    ) -> [AllocationProposal] {
        guard transaction.isIncome, transaction.amount > 0 else { return [] }

        // Fetch all active rules; sort by priority desc then createdAt.
        let descriptor = FetchDescriptor<GoalAllocationRule>(
            predicate: #Predicate { $0.isActive }
        )
        guard var rules = try? context.fetch(descriptor) else { return [] }
        rules.sort { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.createdAt < b.createdAt
        }

        var remaining = transaction.amount - alreadyAllocated
        guard remaining > 0 else { return [] }

        var out: [AllocationProposal] = []
        for rule in rules {
            guard let goal = rule.goal, goal.status == .active else { continue }
            guard rule.type.isIncomeDriven else { continue }
            guard matches(rule: rule, tx: transaction) else { continue }

            let raw = rawAmount(for: rule, tx: transaction)
            guard raw > 0 else { continue }

            // Cap to remaining unallocated income and to the goal's own gap.
            let goalGap = max(goal.targetAmount - goal.currentAmount, 0)
            let capped = min(raw, remaining, goalGap)
            guard capped > 0 else { continue }

            out.append(AllocationProposal(rule: rule, goal: goal, amount: capped))
            remaining -= capped
            if remaining <= 0 { break }
        }
        return out
    }

    // MARK: - Internal

    private static func matches(rule: GoalAllocationRule, tx: Transaction) -> Bool {
        switch rule.source {
        case .allIncome:
            return true
        case .category:
            guard let match = rule.sourceMatch,
                  let cat = tx.category else { return false }
            return cat.id.uuidString == match
        case .payee:
            guard let match = rule.sourceMatch else { return false }
            return tx.payee.localizedCaseInsensitiveCompare(match) == .orderedSame
        }
    }

    private static func rawAmount(for rule: GoalAllocationRule, tx: Transaction) -> Decimal {
        switch rule.type {
        case .percentOfIncome:
            return (tx.amount * rule.amount) / 100
        case .fixedPerIncome:
            return rule.amount
        case .fixedMonthly, .roundUpExpense:
            return 0 // reserved for later phases
        }
    }
}
