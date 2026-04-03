import Foundation
import SwiftData

@Model
final class RecurringTransaction {
    var id: UUID
    var name: String
    var amount: Decimal
    var isIncome: Bool
    var frequency: RecurrenceFrequency
    var nextOccurrence: Date
    var autoCreate: Bool
    var isActive: Bool
    var createdAt: Date

    @Relationship var account: Account?
    @Relationship var category: BudgetCategory?

    init(
        name: String,
        amount: Decimal,
        isIncome: Bool = false,
        frequency: RecurrenceFrequency = .monthly,
        nextOccurrence: Date,
        autoCreate: Bool = false,
        account: Account? = nil,
        category: BudgetCategory? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.amount = amount
        self.isIncome = isIncome
        self.frequency = frequency
        self.nextOccurrence = nextOccurrence
        self.autoCreate = autoCreate
        self.isActive = true
        self.account = account
        self.category = category
        self.createdAt = .now
    }
}
