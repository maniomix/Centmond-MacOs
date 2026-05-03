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

    /// True for the seed-on-launch default categories (Groceries, Rent,
    /// Bills, …). Built-ins are protected from delete in the UI and are
    /// NOT synced to cloud — iOS has its own hardcoded copy of the
    /// same defaults, so syncing them would create duplicates. Default
    /// `false` so existing user-created rows migrate cleanly.
    var isBuiltIn: Bool = false

    /// Cross-platform stable identifier matching iOS's `Category.storageKey`.
    /// Built-ins use the lowercased canonical name ("groceries", "rent", …).
    /// User-created categories use `"custom:" + name`. Stored in
    /// `transactions.category_key` and `monthly_category_budgets.category_key`
    /// so iOS and macOS share the same wire format. Empty string for
    /// pre-migration rows; resolved on the fly via `effectiveStorageKey`.
    var storageKey: String = ""

    /// Best-effort storage key. Falls back to a derived value if
    /// `storageKey` is empty (i.e. a row created before the field
    /// existed). Built-ins map to their canonical lowercased name;
    /// user-created rows get the `custom:` prefix.
    var effectiveStorageKey: String {
        if !storageKey.isEmpty { return storageKey }
        return Self.canonicalStorageKey(name: name, isBuiltIn: isBuiltIn)
    }

    /// Pure helper used by seeder and `effectiveStorageKey` so the
    /// derivation rule lives in one place.
    static func canonicalStorageKey(name: String, isBuiltIn: Bool) -> String {
        if isBuiltIn {
            return name.lowercased()
        }
        return "custom:\(name)"
    }

    @Relationship var parentCategory: BudgetCategory?
    @Relationship(inverse: \BudgetCategory.parentCategory) var subcategories: [BudgetCategory]
    @Relationship(inverse: \Transaction.category) var transactions: [Transaction]
    @Relationship(inverse: \RecurringTransaction.category) var recurrings: [RecurringTransaction] = []
    @Relationship(inverse: \TransactionSplit.category) var splits: [TransactionSplit] = []

    init(
        name: String,
        icon: String = "folder.fill",
        colorHex: String = "3B82F6",
        budgetAmount: Decimal = 0,
        isExpenseCategory: Bool = true,
        sortOrder: Int = 0,
        isBuiltIn: Bool = false
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
        self.recurrings = []
        self.splits = []
        self.updatedAt = .now
        self.isBuiltIn = isBuiltIn
        self.storageKey = Self.canonicalStorageKey(name: name, isBuiltIn: isBuiltIn)
    }
}
