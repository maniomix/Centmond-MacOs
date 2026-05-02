import Foundation
import SwiftData

// ============================================================
// MARK: - Shared Goal (Household Rebuild P4.4)
// ============================================================
// Mirrors iOS `SharedGoal`. Cents-only, like every other Household-domain
// money field. Contributions reuse the existing per-platform UserDefaults
// overlay pattern (per `feedback_goal_contribution_writes`) — the engine
// surface in P5 wraps that.
// ============================================================

@Model
final class SharedGoal {
    var id: UUID
    var name: String
    /// SF Symbol name.
    var icon: String
    /// Cents. Must be > 0 at creation (engine-enforced).
    var targetAmount: Int
    /// Cents. May exceed `targetAmount` once completed.
    var currentAmount: Int
    /// Auth uid of the creator. Optional for offline-only stores.
    var createdBy: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship var household: Household?

    init(
        name: String,
        icon: String = "star.fill",
        targetAmount: Int,
        currentAmount: Int = 0,
        createdBy: String? = nil,
        household: Household? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.targetAmount = targetAmount
        self.currentAmount = currentAmount
        self.createdBy = createdBy
        self.createdAt = .now
        self.updatedAt = .now
        self.household = household
    }

    var progress: Double {
        guard targetAmount > 0 else { return 0 }
        return min(1.0, Double(currentAmount) / Double(targetAmount))
    }

    var isCompleted: Bool { currentAmount >= targetAmount }
    var remainingAmount: Int { max(0, targetAmount - currentAmount) }
    var progressPercent: Int { Int(progress * 100) }
}
