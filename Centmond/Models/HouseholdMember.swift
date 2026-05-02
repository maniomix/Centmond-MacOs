import Foundation
import SwiftData

enum HouseholdRole: String, CaseIterable {
    case owner
    case partner
    case adult
    case child
    case viewer
    /// Legacy. Preserved so old `roleRaw == "guest"` rows still decode; the
    /// computed accessor on `HouseholdMember.role` maps it to `.viewer`.
    case guest

    var label: String {
        switch self {
        case .owner: return "Owner"
        case .partner: return "Partner"
        case .adult: return "Adult"
        case .child: return "Child"
        case .viewer, .guest: return "Viewer"
        }
    }

    var icon: String {
        switch self {
        case .owner: return "crown.fill"
        case .partner: return "heart.fill"
        case .adult: return "person.fill"
        case .child: return "figure.child"
        case .viewer, .guest: return "eye.fill"
        }
    }

    /// Budgets / settings / shared goals. Children, viewers, and legacy guests
    /// can't edit. Mirrors iOS spec §4 permission matrix.
    var canEditBudgets: Bool {
        switch self {
        case .owner, .partner, .adult: return true
        case .child, .viewer, .guest: return false
        }
    }

    var canAddExpenses: Bool {
        switch self {
        case .viewer, .guest: return false
        default: return true
        }
    }

    var canManageMembers: Bool { self == .owner }

    var canSettle: Bool {
        switch self {
        case .owner, .partner, .adult: return true
        case .child, .viewer, .guest: return false
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
        get {
            let decoded = roleRaw.flatMap(HouseholdRole.init(rawValue:)) ?? (isOwner ? .owner : .adult)
            // Migration: legacy `.guest` is normalised to `.viewer` per
            // Household Rebuild spec §4. The raw string stays put so old data
            // round-trips losslessly until the next write.
            return decoded == .guest ? .viewer : decoded
        }
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

    // Aggregate root (Household Rebuild P4.2). Optional + nullify so legacy
    // rows that pre-date the aggregate decode cleanly; a one-time migration
    // (P4.6) creates the synthetic root and attaches existing members.
    @Relationship(inverse: \Household.members)
    var household: Household?

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
