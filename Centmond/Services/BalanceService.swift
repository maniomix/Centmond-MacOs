import Foundation
import SwiftData

/// Centralized rules for keeping `Account.currentBalance` derived from
/// the transactions stored against it, and for filtering "spending" rollups
/// that should ignore transfer legs.
///
/// Mutation sites (sheets, importers, inspector edits, deletes) call
/// `recalculate(account:)` after touching transactions so the stored
/// balance never drifts. Read sites that compute income/expense rollups
/// use `isSpendingIncome(_:)` / `isSpendingExpense(_:)` to filter out
/// transfer legs (which net to zero across the household but would
/// otherwise inflate both sides of the ledger).
enum BalanceService {

    // MARK: - Spending predicates

    /// True for income transactions that count as actual income — i.e.
    /// money flowing in from outside the user's accounts. Transfer legs
    /// are excluded because the matching out-leg cancels them out.
    static func isSpendingIncome(_ tx: Transaction) -> Bool {
        tx.isIncome && !tx.isTransfer
    }

    /// True for expense transactions that count as actual spending —
    /// i.e. money leaving the user's accounts. Transfer legs are excluded.
    static func isSpendingExpense(_ tx: Transaction) -> Bool {
        !tx.isIncome && !tx.isTransfer
    }

    // MARK: - Recalculation

    /// Recompute `account.currentBalance` from `openingBalance` plus the
    /// signed sum of every transaction on the account. Transfer legs DO
    /// participate here — a transfer really does move money between
    /// accounts, so each leg adjusts its own account's balance.
    static func recalculate(account: Account) {
        let signed: Decimal = account.transactions.reduce(0) { running, tx in
            running + (tx.isIncome ? tx.amount : -tx.amount)
        }
        account.currentBalance = account.openingBalance + signed
    }

    /// Recalculate every account in the store. Use after bulk operations
    /// (CSV import, replace-all) where touching individual accounts is
    /// fiddly.
    static func recalculateAll(in context: ModelContext) {
        let descriptor = FetchDescriptor<Account>()
        guard let accounts = try? context.fetch(descriptor) else { return }
        for account in accounts {
            recalculate(account: account)
        }
    }

    /// Convenience: recalculate the union of two optional accounts. Use
    /// after edits that may have moved a transaction from one account to
    /// another, so both old and new balances stay correct.
    static func recalculate(_ a: Account?, _ b: Account?) {
        if let a { recalculate(account: a) }
        if let b, b.id != a?.id { recalculate(account: b) }
    }
}
