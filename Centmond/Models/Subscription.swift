import Foundation
import SwiftData

@Model
final class Subscription {
    var id: UUID = UUID()
    var serviceName: String = ""
    var merchantKey: String = ""
    var categoryName: String = "Subscriptions"
    var amount: Decimal = 0
    var currency: String = "USD"
    var billingCycle: BillingCycle = BillingCycle.monthly
    var customCadenceDays: Int?
    var nextPaymentDate: Date = Date.now
    var lastChargeDate: Date?
    var firstChargeDate: Date?
    var status: SubscriptionStatus = SubscriptionStatus.active

    // Trial tracking. `isTrial` is redundant with `status == .trial` but kept
    // as a flag for detector provenance — the detector can mark a candidate as
    // "started inside trial window" without flipping the user-facing status.
    var isTrial: Bool = false
    var trialEndsAt: Date?

    // Detection / provenance.
    //
    // `sourceRaw` stores the enum as Optional<String> so SwiftData's
    // lightweight migration can read `nil` for rows that pre-date P1.
    // A non-optional `SubscriptionSource` property crashed on launch with
    // "Could not cast value of type 'Swift.Optional<Any>' to 'SubscriptionSource'"
    // because the existing store had no column to migrate from. Keep the
    // backing field optional, and expose a clean `source` accessor for the
    // rest of the app.
    private var sourceRaw: String?
    var source: SubscriptionSource {
        get { sourceRaw.flatMap(SubscriptionSource.init(rawValue:)) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
    var autoDetected: Bool = false
    var detectionConfidence: Double = 0

    /// Set when the subscription was created during the late-night impulse
    /// window (22:00–04:00 local) via the manual New Subscription sheet.
    /// Not used anywhere critical — feeds the emotional-spending engine so
    /// the UI can flag "you signed up at 2 AM, are you sure you want this?"
    /// on the subscription card or in the optimizer banner.
    var wasImpulseSignup: Bool = false

    // Display & lifecycle
    var colorHex: String?
    var iconSymbol: String?
    var notes: String?
    var cancellationURL: String?

    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    @Relationship var account: Account?

    // Household payer (P2). Copied onto every reconciled/materialized charge
    // so subscription spend is attributed to whoever the subscription belongs
    // to — nil means "household-wide / combined" the same way transactions do.
    @Relationship var householdMember: HouseholdMember?

    @Relationship(deleteRule: .cascade, inverse: \SubscriptionCharge.subscription)
    var charges: [SubscriptionCharge] = []

    @Relationship(deleteRule: .cascade, inverse: \SubscriptionPriceChange.subscription)
    var priceHistory: [SubscriptionPriceChange] = []

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
        self.merchantKey = Self.merchantKey(for: serviceName)
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
        case .weekly: return amount * 52
        case .biweekly: return amount * 26
        case .monthly: return amount * 12
        case .quarterly: return amount * 4
        case .semiannual: return amount * 2
        case .annual: return amount
        case .custom:
            let days = max(customCadenceDays ?? 30, 1)
            return amount * Decimal(365) / Decimal(days)
        }
    }

    var monthlyCost: Decimal { annualCost / 12 }

    /// True when the next expected charge is more than 3 days overdue and no
    /// matching `SubscriptionCharge` has landed for it. Reconciliation in P4
    /// advances `nextPaymentDate` whenever it links a charge — anything that
    /// stays past-due means the merchant didn't bill, the user paused, or the
    /// charge came in under a different payee string.
    var isPastDue: Bool {
        guard status == .active || status == .trial else { return false }
        let graceDays = 3
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -graceDays, to: .now) else {
            return false
        }
        return nextPaymentDate < cutoff
    }

    /// Effective cadence in days — used by detection reconciliation and the
    /// upcoming-charges calendar so `.custom` cycles don't have to special-case
    /// every call site.
    var effectiveCadenceDays: Int {
        switch billingCycle {
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 30
        case .quarterly: return 91
        case .semiannual: return 182
        case .annual: return 365
        case .custom: return max(customCadenceDays ?? 30, 1)
        }
    }

    /// Canonical merchant key for matching incoming transactions to this
    /// subscription. Lowercased, stripped of punctuation and collapsed
    /// whitespace — mirrors the approach the detector will use in P2 so
    /// manual rows and auto-detected candidates share a key space.
    static func merchantKey(for serviceName: String) -> String {
        let trimmed = serviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = trimmed.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let collapsed = String(allowed)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed
    }
}
