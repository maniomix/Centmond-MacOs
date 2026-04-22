import Foundation
import SwiftData

@Model
final class Transaction {
    var id: UUID
    var date: Date
    var payee: String
    var amount: Decimal
    var notes: String?
    var isIncome: Bool
    var status: TransactionStatus
    var isReviewed: Bool
    var createdAt: Date
    var updatedAt: Date

    // Transfer pairing (P1.4). Both legs of a transfer share `transferGroupID`
    // and have `isTransfer == true`. Single-sided transactions leave both nil/false.
    var transferGroupID: UUID?
    var isTransfer: Bool = false

    /// Set when this transaction is sourced from (or has been linked to) a
    /// `RecurringTransaction` template. Drives the Review Queue's "From
    /// Recurring" filter, the auto-approve sweep, and dedupe in
    /// `RecurringService.linkPendingMatches`.
    var recurringTemplateID: UUID?

    @Relationship var account: Account?
    @Relationship var category: BudgetCategory?
    @Relationship(inverse: \Tag.transactions) var tags: [Tag]

    // Household attribution (S6). Optional — pre-existing rows and any
    // transaction created without a member assignment stay nil so the
    // Combined view continues to show everything. The inverse + nullify
    // delete rule live on HouseholdMember.transactions, so removing a
    // member clears this pointer instead of cascading and wiping the
    // ledger.
    @Relationship var householdMember: HouseholdMember?

    // Splits are now line items on a dedicated entity, not child transactions.
    @Relationship(deleteRule: .cascade, inverse: \TransactionSplit.parentTransaction)
    var splits: [TransactionSplit]

    // Per-member shares of a shared expense (Household P1). Cascade-delete so a
    // removed transaction cleans up its share rows; the HouseholdMember side
    // is nullify (see HouseholdMember.shares).
    @Relationship(deleteRule: .cascade, inverse: \ExpenseShare.parentTransaction)
    var shares: [ExpenseShare] = []

    init(
        date: Date = .now,
        payee: String,
        amount: Decimal,
        notes: String? = nil,
        isIncome: Bool = false,
        status: TransactionStatus = .cleared,
        isReviewed: Bool = true,
        account: Account? = nil,
        category: BudgetCategory? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.payee = payee
        self.amount = amount
        self.notes = notes
        self.isIncome = isIncome
        self.status = status
        self.isReviewed = isReviewed
        self.account = account
        self.category = category
        self.tags = []
        self.splits = []
        self.transferGroupID = nil
        self.isTransfer = false
        self.recurringTemplateID = nil
        self.createdAt = .now
        self.updatedAt = .now
    }
}
