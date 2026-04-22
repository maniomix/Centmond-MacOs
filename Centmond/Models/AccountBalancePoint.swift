import Foundation
import SwiftData

/// Per-account balance at a single point in time.
///
/// One row per account per snapshot day. Powers per-account sparklines
/// (P5) and the asset/liability composition history. Has a hard inverse
/// on `Account.balanceHistory` so deleting an account cascades cleanly;
/// `NetWorthReferenceRepair` nullifies any pre-existing dangling rows
/// from earlier builds (per BudgetCategory Inverses memory rule).
@Model
final class AccountBalancePoint {
    var id: UUID
    var date: Date
    var balance: Decimal
    var account: Account?
    var createdAt: Date

    init(date: Date, balance: Decimal, account: Account?) {
        self.id = UUID()
        self.date = date
        self.balance = balance
        self.account = account
        self.createdAt = .now
    }
}
