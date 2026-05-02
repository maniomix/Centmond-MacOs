import Foundation
import SwiftData

// ============================================================
// MARK: - Household Invite (P4.3)
// ============================================================
//
// Local-only in v1. Cross-user redemption is deferred to the Tier-B
// multi-user phase per spec §2 / §5. Until then this row exists so the
// engine surface (P5) has somewhere to write `regenerateInviteCode` and
// future invite-creation events without a schema-change PR.
// ============================================================

enum HouseholdInviteStatus: String, CaseIterable {
    case pending
    case accepted
    case declined
    case expired

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        case .expired: return "Expired"
        }
    }
}

@Model
final class HouseholdInvite {
    var id: UUID
    /// Auth uid of the user who issued the invite. Optional — same reason as
    /// `Household.createdBy` (offline stores have no auth).
    var invitedBy: String?
    var inviteCode: String
    /// Stored as raw string so the household-role enum can grow without a
    /// schema migration.
    private var roleRaw: String?
    private var statusRaw: String?
    var createdAt: Date
    var expiresAt: Date

    @Relationship var household: Household?

    var role: HouseholdRole {
        get { roleRaw.flatMap(HouseholdRole.init(rawValue:)) ?? .partner }
        set { roleRaw = newValue.rawValue }
    }

    var status: HouseholdInviteStatus {
        get { statusRaw.flatMap(HouseholdInviteStatus.init(rawValue:)) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(
        inviteCode: String,
        invitedBy: String? = nil,
        role: HouseholdRole = .partner,
        status: HouseholdInviteStatus = .pending,
        expiresAt: Date = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now.addingTimeInterval(7 * 86_400),
        household: Household? = nil
    ) {
        self.id = UUID()
        self.inviteCode = inviteCode
        self.invitedBy = invitedBy
        self.roleRaw = role.rawValue
        self.statusRaw = status.rawValue
        self.createdAt = .now
        self.expiresAt = expiresAt
        self.household = household
    }

    var isExpired: Bool { Date() > expiresAt }
}
