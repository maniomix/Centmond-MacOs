import Foundation
import SwiftData

/// A single occurrence of a subscription payment. Created by the
/// reconciliation service (P4) when a `Transaction` is matched to a
/// `Subscription`, or manually via `SubscriptionService.markPaid`. Keeps the
/// per-occurrence history so the detail view can render a timeline, price
/// hikes can be detected by comparing consecutive `amount` values, and
/// missed-charge alerts can fire when an expected date passes without a
/// matching row.
@Model
final class SubscriptionCharge {
    var id: UUID = UUID()
    var date: Date = Date.now
    var amount: Decimal = 0
    var currency: String = "USD"

    /// UUID of the ledger `Transaction` this charge reconciled to, if any.
    /// Stored as a weak UUID pointer rather than a SwiftData relationship so
    /// deleting the Transaction doesn't cascade into charge history — we'd
    /// rather keep the row and mark it orphaned than lose the audit trail.
    var transactionID: UUID?

    /// True when the reconciliation engine created this automatically.
    /// Manual `markPaid` calls set this to false so the UI can distinguish
    /// user-confirmed charges from inferred ones.
    var matchedAutomatically: Bool = false

    /// Confidence score from the matcher, 0...1. Only meaningful when
    /// `matchedAutomatically` is true.
    var matchConfidence: Double = 0

    var notes: String?
    var createdAt: Date = Date.now

    /// Set by the reconciliation service when a charge lands inside the
    /// previous charge's cadence window — almost always a double-billing
    /// or a user accidentally importing the same row twice. Drives a red
    /// "duplicate?" badge on the row, but doesn't suppress the charge —
    /// the user decides what to do.
    var isFlaggedDuplicate: Bool = false

    @Relationship var subscription: Subscription?

    init(
        date: Date,
        amount: Decimal,
        currency: String = "USD",
        transactionID: UUID? = nil,
        matchedAutomatically: Bool = false,
        matchConfidence: Double = 0,
        notes: String? = nil,
        subscription: Subscription? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.amount = amount
        self.currency = currency
        self.transactionID = transactionID
        self.matchedAutomatically = matchedAutomatically
        self.matchConfidence = matchConfidence
        self.notes = notes
        self.subscription = subscription
        self.createdAt = .now
    }
}
