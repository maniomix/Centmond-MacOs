import Foundation
import SwiftData

/// Records a detected change in a Subscription's recurring amount. Written by
/// the reconciliation engine (P4) when a new charge's amount differs from the
/// subscription's stored `amount` by more than a small tolerance. Powers the
/// price-hike badge on rows, the inline sparkline in the detail sheet, and
/// the "price hike detected" optimizer insight in P6.
@Model
final class SubscriptionPriceChange {
    var id: UUID = UUID()
    var date: Date = Date.now
    var oldAmount: Decimal = 0
    var newAmount: Decimal = 0

    /// Signed percent change: (new - old) / old. Stored so queries can sort
    /// by "biggest hike" without recomputing across a potentially large
    /// price-history collection.
    var changePercent: Double = 0

    /// True when the user acknowledged the change. Unacknowledged changes
    /// drive the red-dot badge on subscription cards.
    var acknowledged: Bool = false

    var notes: String?
    var createdAt: Date = Date.now

    @Relationship var subscription: Subscription?

    init(
        date: Date,
        oldAmount: Decimal,
        newAmount: Decimal,
        notes: String? = nil,
        subscription: Subscription? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.oldAmount = oldAmount
        self.newAmount = newAmount
        if oldAmount > 0 {
            let delta = (newAmount - oldAmount) as NSDecimalNumber
            let base = oldAmount as NSDecimalNumber
            self.changePercent = delta.doubleValue / base.doubleValue
        } else {
            self.changePercent = 0
        }
        self.notes = notes
        self.subscription = subscription
        self.createdAt = .now
    }
}
