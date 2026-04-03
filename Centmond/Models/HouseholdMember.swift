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
