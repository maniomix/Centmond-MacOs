import Foundation
import SwiftData

@Model
final class BudgetCategory {
    var id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var budgetAmount: Decimal
    var isExpenseCategory: Bool
    var sortOrder: Int
    var updatedAt: Date = Date.now

    @Relationship var parentCategory: BudgetCategory?
    @Relationship(inverse: \BudgetCategory.parentCategory) var subcategories: [BudgetCategory]
    @Relationship(inverse: \Transaction.category) var transactions: [Transaction]

    init(
        name: String,
        icon: String = "folder.fill",
        colorHex: String = "3B82F6",
        budgetAmount: Decimal = 0,
        isExpenseCategory: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.budgetAmount = budgetAmount
        self.isExpenseCategory = isExpenseCategory
        self.sortOrder = sortOrder
        self.subcategories = []
        self.transactions = []
        self.updatedAt = .now
    }
}
