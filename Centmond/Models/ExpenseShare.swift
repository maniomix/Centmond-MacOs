import Foundation
import SwiftData

enum ExpenseShareStatus: String, CaseIterable {
    case owed
    case settled
    case waived
}

enum ExpenseShareMethod: String, CaseIterable {
    case equal
    case percent
    case exact
    case shares
}

/// One member's portion of a shared transaction. Sum of `amount` across shares
/// on a transaction should equal the transaction's total (enforced at the
/// split-editor boundary, not the model). `status` tracks the settle-up ledger.
@Model
final class ExpenseShare {
    var id: UUID
    var amount: Decimal
    var percent: Double?
    private var statusRaw: String?
    private var methodRaw: String?
    var createdAt: Date
    var settledAt: Date?

    @Relationship var parentTransaction: Transaction?
    @Relationship var member: HouseholdMember?
    /// If settling this share produced a dedicated settlement transaction,
    /// link it here so the ledger can jump to it.
    @Relationship var settlementTransaction: Transaction?

    var status: ExpenseShareStatus {
        get { statusRaw.flatMap(ExpenseShareStatus.init(rawValue:)) ?? .owed }
        set { statusRaw = newValue.rawValue }
    }

    var method: ExpenseShareMethod {
        get { methodRaw.flatMap(ExpenseShareMethod.init(rawValue:)) ?? .equal }
        set { methodRaw = newValue.rawValue }
    }

    init(
        amount: Decimal,
        percent: Double? = nil,
        status: ExpenseShareStatus = .owed,
        method: ExpenseShareMethod = .equal,
        parentTransaction: Transaction? = nil,
        member: HouseholdMember? = nil
    ) {
        self.id = UUID()
        self.amount = amount
        self.percent = percent
        self.statusRaw = status.rawValue
        self.methodRaw = method.rawValue
        self.createdAt = .now
        self.settledAt = nil
        self.parentTransaction = parentTransaction
        self.member = member
        self.settlementTransaction = nil
    }
}
