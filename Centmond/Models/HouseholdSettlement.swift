import Foundation
import SwiftData

/// A settle-up event: `fromMember` paid `toMember` `amount` on `date`.
/// Optionally backed by a real `Transaction` so the cash movement shows up in
/// the ledger. Deleting a linked transaction should NOT cascade into the
/// settlement record (history stays intact) — we only nullify the pointer.
@Model
final class HouseholdSettlement {
    var id: UUID
    /// Legacy `Decimal` — see `ExpenseShare.amount` for the same rationale.
    var amount: Decimal
    /// Cents. Source of truth going forward (Household Rebuild spec §3.5).
    var amountCents: Int = 0
    var date: Date
    var note: String?
    var createdAt: Date
    /// Tombstone — `unsettle` sets this; balance math filters
    /// `deletedAt == nil`. Spec §3.5.
    var deletedAt: Date?
    /// `ExpenseShare.id` values that were closed by this settlement. Spec §3.5
    /// (`closedShareIds`). Empty until the engine surface in P5 starts
    /// populating it.
    private var closedShareIdsData: Data?

    @Relationship var fromMember: HouseholdMember?
    @Relationship var toMember: HouseholdMember?
    @Relationship var linkedTransaction: Transaction?

    var closedShareIds: [UUID] {
        get {
            guard let d = closedShareIdsData,
                  let arr = try? JSONDecoder().decode([UUID].self, from: d)
            else { return [] }
            return arr
        }
        set {
            closedShareIdsData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Active = not tombstoned. Engine balance math filters on this.
    var isActive: Bool { deletedAt == nil }

    init(
        amount: Decimal,
        date: Date = .now,
        note: String? = nil,
        fromMember: HouseholdMember? = nil,
        toMember: HouseholdMember? = nil,
        linkedTransaction: Transaction? = nil
    ) {
        self.id = UUID()
        self.amount = amount
        self.amountCents = HouseholdSettlement.cents(from: amount)
        self.date = date
        self.note = note
        self.createdAt = .now
        self.deletedAt = nil
        self.closedShareIdsData = nil
        self.fromMember = fromMember
        self.toMember = toMember
        self.linkedTransaction = linkedTransaction
    }

    static func cents(from decimal: Decimal) -> Int {
        var d = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &d, 0, .bankers)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
