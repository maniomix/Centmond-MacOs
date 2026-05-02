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
    /// Legacy. Pre-rebuild storage. New code reads `amountCents`. Kept so
    /// existing call sites compile through the transition; a one-time launch
    /// migration in P4.6 syncs `amountCents` from this when the cents field is
    /// zero on existing rows.
    var amount: Decimal
    /// Cents. Source of truth going forward (Household Rebuild spec §3.4).
    /// Default 0 keeps the SwiftData migration additive; the launch migration
    /// fills it for legacy rows.
    var amountCents: Int = 0
    var percent: Double?
    private var statusRaw: String?
    private var methodRaw: String?
    var createdAt: Date
    var settledAt: Date?
    /// Spec §3.4 — points to the `Settlement` (modeled here as
    /// `HouseholdSettlement`) that closed this share.
    var settlementId: UUID?

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
        // Derive cents at construction so new rows are correct without
        // waiting for the launch migration.
        self.amountCents = ExpenseShare.cents(from: amount)
        self.percent = percent
        self.statusRaw = status.rawValue
        self.methodRaw = method.rawValue
        self.createdAt = .now
        self.settledAt = nil
        self.settlementId = nil
        self.parentTransaction = parentTransaction
        self.member = member
        self.settlementTransaction = nil
    }

    /// Half-even rounding to cents (spec §7.2 macOS migration rule).
    static func cents(from decimal: Decimal) -> Int {
        var d = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &d, 0, .bankers)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
