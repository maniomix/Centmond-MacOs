import Foundation
import SwiftData

/// A single line item inside a split transaction. Replaces the previous
/// `Transaction.splitParent` / `splitChildren` self-relationship: splits are
/// no longer transactions themselves, just categorized slices of the parent's
/// amount. Sum of `splits[].amount` must equal `parent.amount` (enforced in
/// the split editor in P1.3).
@Model
final class TransactionSplit {
    var id: UUID
    var amount: Decimal
    var memo: String?
    var sortOrder: Int

    @Relationship var parentTransaction: Transaction?
    @Relationship var category: BudgetCategory?

    init(
        amount: Decimal,
        memo: String? = nil,
        sortOrder: Int = 0,
        parentTransaction: Transaction? = nil,
        category: BudgetCategory? = nil
    ) {
        self.id = UUID()
        self.amount = amount
        self.memo = memo
        self.sortOrder = sortOrder
        self.parentTransaction = parentTransaction
        self.category = category
    }
}
