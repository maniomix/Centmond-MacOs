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

    @Relationship var account: Account?
    @Relationship var category: BudgetCategory?
    @Relationship(inverse: \Tag.transactions) var tags: [Tag]
    @Relationship var splitParent: Transaction?
    @Relationship(inverse: \Transaction.splitParent) var splitChildren: [Transaction]

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
        self.splitChildren = []
        self.createdAt = .now
        self.updatedAt = .now
    }
}
