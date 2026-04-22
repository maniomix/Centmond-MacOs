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

    /// The occurrence date of the most recent Transaction materialized
    /// from this template. `nil` until the first run. RecurringService
    /// uses this purely as observability — the per-step advance of
    /// `nextOccurrence` is what actually prevents double-materialization.
    var lastMaterializedDate: Date?

    @Relationship var account: Account?
    @Relationship var category: BudgetCategory?

    // Household payer (P2). Inherited by every materialized Transaction so a
    // recurring bill stays attributed without the user picking on each run.
    @Relationship var householdMember: HouseholdMember?

    init(
        name: String,
        amount: Decimal,
        isIncome: Bool = false,
        frequency: RecurrenceFrequency = .monthly,
        nextOccurrence: Date,
        autoCreate: Bool = false,
        account: Account? = nil,
        category: BudgetCategory? = nil,
        householdMember: HouseholdMember? = nil
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
        self.householdMember = householdMember
        self.createdAt = .now
    }
}
