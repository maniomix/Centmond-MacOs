import Foundation
import SwiftData

/// Stores a per-month budget amount override for a specific BudgetCategory.
/// When no override exists for a (category, year, month) tuple, the category's
/// default `budgetAmount` is used as fallback.
@Model
final class MonthlyBudget {
    var id: UUID
    var categoryID: UUID
    var year: Int
    var month: Int
    var amount: Decimal

    init(categoryID: UUID, year: Int, month: Int, amount: Decimal) {
        self.id = UUID()
        self.categoryID = categoryID
        self.year = year
        self.month = month
        self.amount = amount
    }
}
