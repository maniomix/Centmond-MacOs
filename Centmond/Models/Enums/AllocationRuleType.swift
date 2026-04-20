import Foundation

/// How an allocation rule translates an income transaction into a goal
/// contribution. Phase 3 ships `percentOfIncome` and `fixedPerIncome`;
/// time-driven (`fixedMonthly`) and expense-driven (`roundUpExpense`) are
/// reserved names so future phases can extend the enum without migration.
enum AllocationRuleType: String, Codable, CaseIterable {
    case percentOfIncome
    case fixedPerIncome
    case fixedMonthly      // Phase-later: time-driven
    case roundUpExpense    // Phase-later: expense-driven

    var isIncomeDriven: Bool {
        self == .percentOfIncome || self == .fixedPerIncome
    }

    var displayName: String {
        switch self {
        case .percentOfIncome: return "Percent of income"
        case .fixedPerIncome:  return "Fixed per income"
        case .fixedMonthly:    return "Fixed monthly"
        case .roundUpExpense:  return "Round-up from expense"
        }
    }
}

/// Which income transactions a rule matches. `category` and `payee` narrow
/// to the rule's stored `sourceMatch` string (category UUID or payee name).
enum AllocationRuleSource: String, Codable, CaseIterable {
    case allIncome
    case category
    case payee

    var displayName: String {
        switch self {
        case .allIncome: return "All income"
        case .category:  return "Category"
        case .payee:     return "Payee"
        }
    }
}
