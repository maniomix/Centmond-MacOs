import Foundation
import SwiftData

/// Optional sub-grouping inside a household: "parents", "roommates", "kids".
/// Used by reports, split rules, and per-group budget envelopes in later
/// phases. Deleting a group does NOT remove its members — only the grouping.
@Model
final class HouseholdGroup {
    var id: UUID
    var name: String
    var colorHex: String
    var createdAt: Date

    /// Inverse is declared on HouseholdMember.groups.
    @Relationship var members: [HouseholdMember] = []

    init(
        name: String,
        colorHex: String = "8B5CF6"
    ) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.createdAt = .now
        self.members = []
    }
}
