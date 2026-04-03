import Foundation
import SwiftData

@Model
final class Goal {
    var id: UUID
    var name: String
    var icon: String
    var targetAmount: Decimal
    var currentAmount: Decimal
    var targetDate: Date?
    var monthlyContribution: Decimal?
    var status: GoalStatus
    var createdAt: Date

    init(
        name: String,
        icon: String = "target",
        targetAmount: Decimal,
        currentAmount: Decimal = 0,
        targetDate: Date? = nil,
        monthlyContribution: Decimal? = nil,
        status: GoalStatus = .active
    ) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.targetAmount = targetAmount
        self.currentAmount = currentAmount
        self.targetDate = targetDate
        self.monthlyContribution = monthlyContribution
        self.status = status
        self.createdAt = .now
    }

    var progressPercentage: Double {
        guard targetAmount > 0 else { return 0 }
        return Double(truncating: (currentAmount / targetAmount) as NSDecimalNumber)
    }
}
