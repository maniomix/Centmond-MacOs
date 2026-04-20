import Foundation
import SwiftData

/// A rule that proposes routing part of an income transaction into a goal.
/// The engine never writes contributions directly — it builds a proposal and
/// the user confirms in a preview sheet (decision locked 2026-04-19: always
/// preview & confirm, never auto-apply silently).
///
/// `sourceMatch` semantics depend on `source`:
///   - `.allIncome` → ignored
///   - `.category`  → stores the matched `BudgetCategory.id.uuidString`
///   - `.payee`     → stores a case-insensitive payee string
///
/// `amount` means percent when `type == .percentOfIncome` (e.g. 10 = 10%),
/// otherwise a dollar amount.
@Model
final class GoalAllocationRule {
    var id: UUID
    var typeRaw: String
    var sourceRaw: String
    var sourceMatch: String?
    var amount: Decimal
    var priority: Int
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    @Relationship var goal: Goal?

    var type: AllocationRuleType {
        get { AllocationRuleType(rawValue: typeRaw) ?? .percentOfIncome }
        set { typeRaw = newValue.rawValue }
    }

    var source: AllocationRuleSource {
        get { AllocationRuleSource(rawValue: sourceRaw) ?? .allIncome }
        set { sourceRaw = newValue.rawValue }
    }

    init(
        goal: Goal? = nil,
        type: AllocationRuleType = .percentOfIncome,
        source: AllocationRuleSource = .allIncome,
        sourceMatch: String? = nil,
        amount: Decimal,
        priority: Int = 0,
        isActive: Bool = true
    ) {
        self.id = UUID()
        self.goal = goal
        self.typeRaw = type.rawValue
        self.sourceRaw = source.rawValue
        self.sourceMatch = sourceMatch
        self.amount = amount
        self.priority = priority
        self.isActive = isActive
        self.createdAt = .now
        self.updatedAt = .now
    }
}
