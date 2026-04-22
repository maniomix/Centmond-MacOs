import Foundation
import SwiftData

enum HouseholdRole: String, CaseIterable {
    case owner
    case adult
    case child
    case guest

    var label: String {
        switch self {
        case .owner: return "Owner"
        case .adult: return "Adult"
        case .child: return "Child"
        case .guest: return "Guest"
        }
    }
}

@Model
final class HouseholdMember {
    var id: UUID
    var name: String
    var email: String?
    var avatarColor: String
    var isOwner: Bool
    var joinedAt: Date

    // P1 additions. See feedback_swiftdata_enum_migration — role is stored as
    // optional String and surfaced through a computed accessor so the existing
    // store migrates cleanly.
    private var roleRaw: String?
    var defaultSharePercent: Double?
    var isActive: Bool = true
    var archivedAt: Date?

    var role: HouseholdRole {
        get { roleRaw.flatMap(HouseholdRole.init(rawValue:)) ?? (isOwner ? .owner : .adult) }
        set { roleRaw = newValue.rawValue }
    }

    @Relationship(deleteRule: .nullify, inverse: \Transaction.householdMember)
    var transactions: [Transaction] = []

    // Nullify, not cascade: removing a member must NOT wipe the share rows on
    // a parent transaction — that would desync the share sum from the total.
    // The member pointer just goes nil; repair code reassigns or archives.
    @Relationship(deleteRule: .nullify, inverse: \ExpenseShare.member)
    var shares: [ExpenseShare] = []

    @Relationship(inverse: \HouseholdGroup.members)
    var groups: [HouseholdGroup] = []

    init(
        name: String,
        email: String? = nil,
        avatarColor: String = "3B82F6",
        isOwner: Bool = false,
        role: HouseholdRole? = nil,
        defaultSharePercent: Double? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.email = email
        self.avatarColor = avatarColor
        self.isOwner = isOwner
        self.joinedAt = .now
        self.roleRaw = (role ?? (isOwner ? .owner : .adult)).rawValue
        self.defaultSharePercent = defaultSharePercent
        self.isActive = true
        self.archivedAt = nil
    }
}
