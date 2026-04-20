import Foundation
import SwiftData

/// Persistent record that the user rejected a subscription detection candidate
/// with this `merchantKey`. Checked by `SubscriptionDetector` on every run so
/// a dismissed candidate doesn't re-surface after each new charge lands.
///
/// Why a dedicated table instead of a flag on Subscription: a dismissed
/// candidate has no Subscription row by definition — the user said "no, that's
/// not a subscription". We need somewhere to remember the rejection. Keyed by
/// normalized merchant key so a user renaming the merchant in their CSV
/// doesn't flood the review queue again.
@Model
final class DismissedDetection {
    var id: UUID = UUID()
    var merchantKey: String = ""
    var dismissedAt: Date = Date.now

    /// Snapshot of what we last detected — lets the UI show "dismissed at $9.99
    /// monthly" if the user wants to review past rejections.
    var lastDetectedAmount: Decimal = 0
    var lastDetectedCycle: BillingCycle = BillingCycle.monthly

    init(merchantKey: String, lastDetectedAmount: Decimal, lastDetectedCycle: BillingCycle) {
        self.id = UUID()
        self.merchantKey = merchantKey
        self.lastDetectedAmount = lastDetectedAmount
        self.lastDetectedCycle = lastDetectedCycle
        self.dismissedAt = .now
    }
}
