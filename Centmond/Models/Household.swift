import Foundation
import SwiftData

// ============================================================
// MARK: - Household (aggregate root)
// ============================================================
//
// Aggregate root added in Household Rebuild P4.2. Pre-rebuild macOS lacked a
// root entirely — `HouseholdMember`s were top-level @Models with no parent.
// The new shape mirrors iOS so the unified engine surface (P5) compiles
// against the same domain on both platforms.
//
// Migration (runs lazy on first launch in P4.6):
//   1. Look for any existing `HouseholdMember` rows.
//   2. If found and no `Household` exists, create a synthetic Household,
//      attach every existing member, mark the `isOwner` member as `.owner`,
//      copy any pre-existing `HouseholdGroup`s onto it.
//   3. Generate an invite code (matches iOS alphabet & length).
//
// Relationships are optional / nullify-on-delete so existing data decodes
// cleanly before the synthetic-household pass runs. Members without a
// household pointer keep working in legacy "no aggregate" mode until the
// migration runs.
// ============================================================

@Model
final class Household {
    var id: UUID
    var name: String
    /// Auth uid of the creator. Optional because macOS Cloud Port (Centmond
    /// auth integration) is in progress — offline-only stores use `nil`.
    var createdBy: String?
    var inviteCode: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .nullify) var members: [HouseholdMember] = []
    @Relationship(deleteRule: .nullify) var groups: [HouseholdGroup] = []

    init(
        name: String = "Our Household",
        createdBy: String? = nil,
        inviteCode: String = Household.generateInviteCode(),
        members: [HouseholdMember] = [],
        groups: [HouseholdGroup] = []
    ) {
        self.id = UUID()
        self.name = name
        self.createdBy = createdBy
        self.inviteCode = inviteCode
        self.createdAt = .now
        self.updatedAt = .now
        self.members = members
        self.groups = groups
    }

    // MARK: Convenience

    var owner: HouseholdMember? { members.first(where: { $0.role == .owner }) }
    var partner: HouseholdMember? { members.first(where: { $0.role == .partner }) }
    var activeMembers: [HouseholdMember] { members.filter { $0.isActive } }

    func member(for userId: String) -> HouseholdMember? {
        members.first(where: { $0.email == userId })
            ?? members.first(where: { $0.id.uuidString == userId })
    }

    /// Matches iOS alphabet + length so codes generated on either platform are
    /// interchangeable for the future cross-user Tier-B invite flow.
    static func generateInviteCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }
}
