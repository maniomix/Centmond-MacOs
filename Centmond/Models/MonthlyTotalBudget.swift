import Foundation
import SwiftData

/// The overall spending limit a user sets for a given month.
/// Category budgets are portions allocated *from* this total.
@Model
final class MonthlyTotalBudget {
    var id: UUID
    var year: Int
    var month: Int
    var amount: Decimal

    init(year: Int, month: Int, amount: Decimal) {
        self.id = UUID()
        self.year = year
        self.month = month
        self.amount = amount
    }
}
