import Foundation
import SwiftData

// ============================================================
// MARK: - Shared Budget (Household Rebuild P4.4)
// ============================================================
// Per-month shared budget for a household. Mirrors iOS `SharedBudget`.
// Unique on (household, monthKey) — enforced at the engine boundary in P5,
// not as a SwiftData unique attribute (compound uniqueness isn't supported
// natively without a workaround).
// ============================================================

enum BudgetSplitRuleKind: String, CaseIterable {
    case equal
    case percent
    case paidBy
}

@Model
final class SharedBudget {
    var id: UUID
    /// `YYYY-MM` (e.g. "2026-05").
    var monthKey: String
    /// Total cents for the month. Spec §3.6 — money is `Int` cents on both
    /// platforms.
    var totalAmount: Int
    private var splitRuleKindRaw: String?
    /// Used when `splitRuleKindRaw == .percent`. Range 0…100, percent that
    /// the payer covers.
    var splitPercent: Double?
    /// Used when `splitRuleKindRaw == .paidBy`. Member.id of the payer.
    var splitPaidByMemberId: UUID?
    /// `Category.storageKey` → cents. Stored as raw JSON-ish data because
    /// SwiftData doesn't model `[String: Int]` directly.
    private var categoryBudgetsData: Data?
    var createdAt: Date
    var updatedAt: Date

    @Relationship var household: Household?

    var splitRuleKind: BudgetSplitRuleKind {
        get { splitRuleKindRaw.flatMap(BudgetSplitRuleKind.init(rawValue:)) ?? .equal }
        set { splitRuleKindRaw = newValue.rawValue }
    }

    var categoryBudgets: [String: Int] {
        get {
            guard let d = categoryBudgetsData,
                  let dict = try? JSONDecoder().decode([String: Int].self, from: d)
            else { return [:] }
            return dict
        }
        set {
            categoryBudgetsData = try? JSONEncoder().encode(newValue)
            updatedAt = .now
        }
    }

    init(
        monthKey: String,
        totalAmount: Int,
        splitRuleKind: BudgetSplitRuleKind = .equal,
        splitPercent: Double? = nil,
        splitPaidByMemberId: UUID? = nil,
        categoryBudgets: [String: Int] = [:],
        household: Household? = nil
    ) {
        self.id = UUID()
        self.monthKey = monthKey
        self.totalAmount = totalAmount
        self.splitRuleKindRaw = splitRuleKind.rawValue
        self.splitPercent = splitPercent
        self.splitPaidByMemberId = splitPaidByMemberId
        self.categoryBudgetsData = (try? JSONEncoder().encode(categoryBudgets))
        self.createdAt = .now
        self.updatedAt = .now
        self.household = household
    }
}
