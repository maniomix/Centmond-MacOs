import Foundation
import SwiftData

/// A single deposit toward a Goal. The authoritative history — `Goal.currentAmount`
/// is a cache maintained by `GoalContributionService` from the sum of these rows.
///
/// `sourceTransactionID` (not a SwiftData relationship) holds the originating
/// Transaction's UUID when the contribution came from an income allocation or a
/// transfer-to-goal; stored as a UUID so deleting the Transaction cascades
/// cleanup explicitly (see service), avoiding SwiftData inverse-relationship
/// fragility with large data sets.
@Model
final class GoalContribution {
    var id: UUID
    var amount: Decimal
    var date: Date
    var kindRaw: String
    var note: String?
    var sourceTransactionID: UUID?
    var createdAt: Date

    @Relationship var goal: Goal?

    var kind: GoalContributionKind {
        get { GoalContributionKind(rawValue: kindRaw) ?? .manual }
        set { kindRaw = newValue.rawValue }
    }

    init(
        amount: Decimal,
        date: Date = .now,
        kind: GoalContributionKind = .manual,
        note: String? = nil,
        sourceTransactionID: UUID? = nil,
        goal: Goal? = nil
    ) {
        self.id = UUID()
        self.amount = amount
        self.date = date
        self.kindRaw = kind.rawValue
        self.note = note
        self.sourceTransactionID = sourceTransactionID
        self.goal = goal
        self.createdAt = .now
    }
}
