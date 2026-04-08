import Foundation
import SwiftData

@Model
final class HouseholdMember {
    var id: UUID
    var name: String
    var email: String?
    var avatarColor: String
    var isOwner: Bool
    var joinedAt: Date

    // Inverse of Transaction.householdMember (S6). Nullify on delete:
    // removing a member should clear attribution on their transactions,
    // not cascade and destroy ledger history.
    @Relationship(deleteRule: .nullify, inverse: \Transaction.householdMember)
    var transactions: [Transaction] = []

    init(
        name: String,
        email: String? = nil,
        avatarColor: String = "3B82F6",
        isOwner: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.email = email
        self.avatarColor = avatarColor
        self.isOwner = isOwner
        self.joinedAt = .now
    }
}
