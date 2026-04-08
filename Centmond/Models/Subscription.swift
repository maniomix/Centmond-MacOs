import Foundation
import SwiftData

@Model
final class Subscription {
    var id: UUID
    var serviceName: String
    var categoryName: String
    var amount: Decimal
    var billingCycle: BillingCycle
    var nextPaymentDate: Date
    var status: SubscriptionStatus
    var createdAt: Date
    var updatedAt: Date = Date.now

    @Relationship var account: Account?

    init(
        serviceName: String,
        categoryName: String = "Subscriptions",
        amount: Decimal,
        billingCycle: BillingCycle = .monthly,
        nextPaymentDate: Date,
        status: SubscriptionStatus = .active,
        account: Account? = nil
    ) {
        self.id = UUID()
        self.serviceName = serviceName
        self.categoryName = categoryName
        self.amount = amount
        self.billingCycle = billingCycle
        self.nextPaymentDate = nextPaymentDate
        self.status = status
        self.account = account
        self.createdAt = .now
        self.updatedAt = .now
    }

    var annualCost: Decimal {
        switch billingCycle {
        case .weekly: amount * 52
        case .biweekly: amount * 26
        case .monthly: amount * 12
        case .quarterly: amount * 4
        case .semiannual: amount * 2
        case .annual: amount
        }
    }

    var monthlyCost: Decimal {
        annualCost / 12
    }
}
