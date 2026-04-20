import Foundation
import SwiftData

/// Links incoming `Transaction` rows to active `Subscription` records, mints
/// `SubscriptionCharge` rows for the matches, and advances each subscription's
/// `nextPaymentDate`. Also flags price hikes and duplicate charges along the
/// way. Runs in three modes:
///
/// 1. `reconcile(transaction:in:)` — single-row hook fired right after a
///    Transaction is inserted (NewTransactionSheet, AIActionExecutor,
///    ReceiptScanner). Cheap; touches at most one subscription.
/// 2. `reconcileAll(in:)` — bulk pass over every active subscription against
///    every unlinked transaction. Used after CSV import and as a manual
///    "rescan" entry point. O(subs × txns) but both sets stay small in
///    practice (subs ≈ tens, recent txns ≈ hundreds).
/// 3. `reconcile(subscription:in:)` — focused pass for one subscription;
///    used by the detail view "rescan" button (P5/P7).
///
/// Why a separate service from `SubscriptionDetector`: detection invents
/// candidates from raw transaction history, reconciliation links new
/// transactions to *already-confirmed* subscriptions. Different inputs,
/// different outputs, both needed.
enum SubscriptionReconciliationService {

    // Tuning knobs. Mirror `SubscriptionDetector` style — change the number,
    // not the algorithm.
    static let amountTolerancePct: Double = 0.10        // ±10% of stored amount
    static let priceHikeThreshold: Double = 0.05        // > 5% delta = price change
    static let duplicateWindowFraction: Double = 1.0/3  // duplicate if within cadence/3 of prior charge

    // MARK: - Single-transaction hook

    /// Try to link `transaction` to one active subscription. Idempotent —
    /// safe to call twice; the linked-charge guard skips if a charge already
    /// references this transaction id. Returns the matched Subscription
    /// (rarely useful to callers, but handy in tests).

    @discardableResult
    static func reconcile(
        transaction: Transaction,
        in context: ModelContext
    ) -> Subscription? {
        guard !transaction.isIncome, !transaction.isTransfer else { return nil }
        guard !isAlreadyLinked(transactionID: transaction.id, in: context) else { return nil }

        let subs = activeSubscriptions(in: context)
        guard let match = bestMatch(for: transaction, among: subs) else { return nil }
        applyMatch(transaction: transaction, to: match, in: context)
        SubscriptionNotificationScheduler.rescheduleAll(context: context)
        return match
    }

    // MARK: - Bulk


    static func reconcileAll(in context: ModelContext) {
        let subs = activeSubscriptions(in: context)
        guard !subs.isEmpty else { return }
        let candidates = unlinkedRecentTransactions(in: context)
        var matchedAny = false
        for tx in candidates {
            guard let match = bestMatch(for: tx, among: subs) else { continue }
            applyMatch(transaction: tx, to: match, in: context)
            matchedAny = true
        }
        if matchedAny {
            SubscriptionNotificationScheduler.rescheduleAll(context: context)
        }
    }

    // MARK: - Per-subscription rescan


    static func reconcile(subscription: Subscription, in context: ModelContext) {
        guard subscription.status == .active || subscription.status == .trial else { return }
        let candidates = unlinkedRecentTransactions(in: context)
        for tx in candidates where matches(transaction: tx, subscription: subscription) {
            applyMatch(transaction: tx, to: subscription, in: context)
        }
    }

    // MARK: - Matching

    private static func bestMatch(
        for tx: Transaction,
        among subs: [Subscription]
    ) -> Subscription? {
        let candidates = subs.filter { matches(transaction: tx, subscription: $0) }
        guard !candidates.isEmpty else { return nil }
        // Prefer the subscription whose nextPaymentDate is closest to the
        // transaction date — protects against the same merchant appearing
        // under two subscriptions (e.g. user has a paused row and a fresh
        // active one with the same payee).
        return candidates.min { lhs, rhs in
            distance(tx.date, lhs.nextPaymentDate) < distance(tx.date, rhs.nextPaymentDate)
        }
    }

    private static func matches(transaction tx: Transaction, subscription sub: Subscription) -> Bool {
        guard merchantMatches(tx.payee, sub: sub) else { return false }
        guard amountMatches(tx.amount, sub.amount) else { return false }
        guard dateInWindow(tx.date, sub: sub) else { return false }
        return true
    }

    /// Matches a transaction payee against a subscription's merchant key. Falls
    /// back to deriving the key from `sub.serviceName` for legacy rows that
    /// predate P1 (empty `merchantKey`). Without this fallback, every
    /// manually-added subscription created before the rebuild silently failed
    /// reconciliation — the transaction would land, the subscription would
    /// remain "past due," and the user would see both.
    private static func merchantMatches(_ payee: String, sub: Subscription) -> Bool {
        let txKey = Subscription.merchantKey(for: payee)
        guard !txKey.isEmpty else { return false }
        let subKey = sub.merchantKey.isEmpty
            ? Subscription.merchantKey(for: sub.serviceName)
            : sub.merchantKey
        guard !subKey.isEmpty else { return false }
        if txKey == subKey { return true }
        // Fuzzy: one contains the other. Catches "Netflix" vs "NETFLIX 12345".
        if txKey.contains(subKey) || subKey.contains(txKey) { return true }
        return false
    }

    private static func amountMatches(_ txAmount: Decimal, _ subAmount: Decimal) -> Bool {
        guard subAmount > 0 else { return false }
        let tx = (txAmount as NSDecimalNumber).doubleValue
        let base = (subAmount as NSDecimalNumber).doubleValue
        let delta = abs(tx - base) / base
        // Allow generous tolerance — price hikes inside the threshold here
        // are still "matches", they just trigger the price-change side effect.
        return delta <= max(amountTolerancePct, priceHikeThreshold * 4)
    }

    /// Charge counts as a match when its date sits within ½ cadence of the
    /// subscription's `nextPaymentDate` OR within ½ cadence of the
    /// `lastChargeDate` advanced by one cycle. Two windows because users
    /// frequently log historical transactions out-of-order, and we still want
    /// those linked.
    private static func dateInWindow(_ date: Date, sub: Subscription) -> Bool {
        let cadence = max(sub.effectiveCadenceDays, 1)
        let halfWindow = max(cadence / 2, 3)
        let cal = Calendar.current

        let nextDelta = abs(cal.dateComponents([.day], from: date, to: sub.nextPaymentDate).day ?? Int.max)
        if nextDelta <= halfWindow { return true }

        if let last = sub.lastChargeDate,
           let projectedFromLast = advance(last, cycle: sub.billingCycle, customDays: sub.customCadenceDays) {
            let lastDelta = abs(cal.dateComponents([.day], from: date, to: projectedFromLast).day ?? Int.max)
            if lastDelta <= halfWindow { return true }
        }
        return false
    }

    // MARK: - Apply


    private static func applyMatch(
        transaction tx: Transaction,
        to sub: Subscription,
        in context: ModelContext
    ) {
        let isDup = isDuplicateInCadenceWindow(date: tx.date, subscription: sub)

        let charge = SubscriptionCharge(
            date: tx.date,
            amount: tx.amount,
            currency: sub.currency,
            transactionID: tx.id,
            matchedAutomatically: true,
            matchConfidence: 0.85,
            notes: nil,
            subscription: sub
        )
        charge.isFlaggedDuplicate = isDup
        context.insert(charge)

        // Detect price change BEFORE we mutate sub.amount so we have the
        // pre-change baseline. Threshold-gated to avoid noise from rounding.
        let oldAmount = sub.amount
        let newAmount = tx.amount
        if oldAmount > 0 {
            let delta = ((newAmount - oldAmount) as NSDecimalNumber).doubleValue
                      / (oldAmount as NSDecimalNumber).doubleValue
            if abs(delta) >= priceHikeThreshold {
                let change = SubscriptionPriceChange(
                    date: tx.date,
                    oldAmount: oldAmount,
                    newAmount: newAmount,
                    notes: nil,
                    subscription: sub
                )
                context.insert(change)
                // Adopt the new amount so subsequent matches use the updated
                // baseline. The price-history row preserves the old value for
                // audit / sparkline rendering.
                sub.amount = newAmount
            }
        }

        if sub.firstChargeDate == nil { sub.firstChargeDate = tx.date }
        sub.lastChargeDate = tx.date
        // Opportunistic backfill for legacy rows — once we've confirmed a
        // match, populate the merchantKey so subsequent passes hit the fast
        // equality path instead of the serviceName-derived fallback.
        if sub.merchantKey.isEmpty {
            sub.merchantKey = Subscription.merchantKey(for: sub.serviceName)
        }

        if let projected = advance(tx.date, cycle: sub.billingCycle, customDays: sub.customCadenceDays) {
            // Only advance forward — never set nextPaymentDate to a date in
            // the past just because a back-dated import landed.
            if projected > sub.nextPaymentDate {
                sub.nextPaymentDate = projected
            }
        }
        sub.updatedAt = .now
    }


    private static func isDuplicateInCadenceWindow(
        date: Date,
        subscription sub: Subscription
    ) -> Bool {
        let cadence = max(sub.effectiveCadenceDays, 1)
        let dupWindow = max(Int(Double(cadence) * duplicateWindowFraction), 1)
        let cal = Calendar.current
        for prior in sub.charges {
            let delta = abs(cal.dateComponents([.day], from: date, to: prior.date).day ?? Int.max)
            if delta <= dupWindow { return true }
        }
        return false
    }

    // MARK: - Fetch helpers


    private static func activeSubscriptions(in context: ModelContext) -> [Subscription] {
        let descriptor = FetchDescriptor<Subscription>()
        let subs = (try? context.fetch(descriptor)) ?? []
        return subs.filter { $0.status == .active || $0.status == .trial }
    }


    private static func isAlreadyLinked(transactionID: UUID, in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<SubscriptionCharge>(
            predicate: #Predicate { $0.transactionID == transactionID }
        )
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.isEmpty == false)
    }

    /// Pull every linked transaction id once, then fetch all transactions and
    /// subtract — cheaper than per-transaction predicate lookups during the
    /// bulk pass. Limit the candidate window to ~120 days so a multi-year
    /// import doesn't try to back-link ancient rows we'd treat as duplicates.

    private static func unlinkedRecentTransactions(in context: ModelContext) -> [Transaction] {
        let chargeDescriptor = FetchDescriptor<SubscriptionCharge>()
        let allCharges = (try? context.fetch(chargeDescriptor)) ?? []
        let linkedIDs = Set(allCharges.compactMap(\.transactionID))

        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: .now) ?? .distantPast
        let txDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && !$0.isTransfer && $0.date >= cutoff },
            sortBy: [SortDescriptor(\.date)]
        )
        let txns = (try? context.fetch(txDescriptor)) ?? []
        return txns.filter { !linkedIDs.contains($0.id) }
    }

    // MARK: - Date math

    private static func advance(_ date: Date, cycle: BillingCycle, customDays: Int?) -> Date? {
        let cal = Calendar.current
        switch cycle {
        case .weekly:    return cal.date(byAdding: .weekOfYear, value: 1, to: date)
        case .biweekly:  return cal.date(byAdding: .weekOfYear, value: 2, to: date)
        case .monthly:   return cal.date(byAdding: .month,      value: 1, to: date)
        case .quarterly: return cal.date(byAdding: .month,      value: 3, to: date)
        case .semiannual:return cal.date(byAdding: .month,      value: 6, to: date)
        case .annual:    return cal.date(byAdding: .year,       value: 1, to: date)
        case .custom:    return cal.date(byAdding: .day,        value: max(customDays ?? 30, 1), to: date)
        }
    }

    private static func distance(_ a: Date, _ b: Date) -> Int {
        abs(Calendar.current.dateComponents([.day], from: a, to: b).day ?? Int.max)
    }
}
