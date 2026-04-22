import Foundation
import SwiftData

@Model
final class Goal {
    var id: UUID
    var name: String
    var icon: String
    var targetAmount: Decimal

    /// Cache of `contributions.reduce(0, +).amount`. The contribution history is
    /// authoritative — always write through `GoalContributionService` so this
    /// field stays in sync. Reading it directly is fine and fast.
    var currentAmount: Decimal

    var targetDate: Date?
    var monthlyContribution: Decimal?
    var status: GoalStatus
    var priority: Int = 0
    var createdAt: Date
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \GoalContribution.goal)
    var contributions: [GoalContribution] = []

    // Household ownership (P4). Nil = shared/household goal. Non-nil = private
    // to that member. Filter predicates in GoalsView use this when the app is
    // scoped to a single member (P6 global member-scope).
    @Relationship var householdMember: HouseholdMember?

    init(
        name: String,
        icon: String = "target",
        targetAmount: Decimal,
        currentAmount: Decimal = 0,
        targetDate: Date? = nil,
        monthlyContribution: Decimal? = nil,
        status: GoalStatus = .active,
        priority: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.targetAmount = targetAmount
        self.currentAmount = currentAmount
        self.targetDate = targetDate
        self.monthlyContribution = monthlyContribution
        self.status = status
        self.priority = priority
        self.createdAt = .now
        self.updatedAt = .now
    }

    var progressPercentage: Double {
        guard targetAmount > 0 else { return 0 }
        return Double(truncating: (currentAmount / targetAmount) as NSDecimalNumber)
    }
}
