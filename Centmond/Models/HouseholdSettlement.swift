import Foundation
import SwiftData

/// A settle-up event: `fromMember` paid `toMember` `amount` on `date`.
/// Optionally backed by a real `Transaction` so the cash movement shows up in
/// the ledger. Deleting a linked transaction should NOT cascade into the
/// settlement record (history stays intact) — we only nullify the pointer.
@Model
final class HouseholdSettlement {
    var id: UUID
    var amount: Decimal
    var date: Date
    var note: String?
    var createdAt: Date

    @Relationship var fromMember: HouseholdMember?
    @Relationship var toMember: HouseholdMember?
    @Relationship var linkedTransaction: Transaction?

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
        self.date = date
        self.note = note
        self.createdAt = .now
        self.fromMember = fromMember
        self.toMember = toMember
        self.linkedTransaction = linkedTransaction
    }
}
