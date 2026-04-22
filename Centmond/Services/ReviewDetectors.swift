import Foundation
import SwiftData

/// Pure producers of `ReviewItem`s from a pre-fetched
/// `ReviewQueueContext`. No detector re-queries SwiftData — all data
/// comes off the shared snapshot.
///
/// Performance note: the row-local reasons (uncategorized / pending /
/// missingAccount / negativeIncome / unreviewedTransfer / staleCleared /
/// futureDated) used to each run their own `ctx.transactions.filter`.
/// On a 5k-row store that's 7 full scans of the array every call. They
/// are now collapsed into a single `rowLocal` pass that walks the
/// transaction list once and emits 0+ items per row. Cross-row
/// detectors (duplicate / unusualAmount / unlinkedRecurring) still need
/// their own passes because they group before emitting, but each works
/// off a pre-filtered subset so the cost is proportional to candidate
/// count, not total count.
///
/// We also never capture `tx.account?.id` — that access was a SwiftData
/// relationship fault per row and nothing in the UI used the field.
enum ReviewDetectors {

    // MARK: - Row-local reasons (single pass)

    /// Walks the transaction list ONCE and emits items for every
    /// row-local reason. Replaces the seven individual `.filter` passes
    /// the service used to run; for N transactions this is O(N) instead
    /// of O(7N) plus drastically fewer relationship-faulting accesses.
    static func rowLocal(ctx: ReviewQueueContext) -> [ReviewItem] {
        let now = ctx.now
        let staleCutoff = Calendar.current.date(byAdding: .day, value: -30, to: now)
        var out: [ReviewItem] = []
        out.reserveCapacity(ctx.transactions.count / 4)

        for tx in ctx.transactions {
            // futureDated is the only reason that doesn't require
            // !isReviewed plus some other filter, so check it up front.
            let unreviewed = !tx.isReviewed
            let txDate = tx.date

            if unreviewed && !tx.isTransfer && txDate > now {
                out.append(make(.futureDated, severity: .suggested, for: tx))
            }
            guard unreviewed else { continue }

            // category == nil is a faulting relationship access — do it
            // once per row and reuse the result.
            let hasCategory = (tx.category != nil)
            let hasAccount = (tx.account != nil)

            if !hasCategory {
                out.append(make(.uncategorizedTxn, severity: .suggested, for: tx))
            }
            if tx.status == .pending {
                out.append(make(.pendingTxn, severity: .low, for: tx))
            }
            if !hasAccount {
                out.append(make(.missingAccount, severity: .blocker, for: tx))
            }
            if tx.amount < 0 {
                out.append(make(.negativeIncome, severity: .blocker, for: tx))
            }
            if tx.isTransfer {
                out.append(make(.unreviewedTransfer, severity: .low, for: tx))
            }
            if let cutoff = staleCutoff,
               tx.status == .cleared,
               txDate < cutoff {
                out.append(make(.staleCleared, severity: .low, for: tx))
            }
        }
        return out
    }

    // MARK: - Cross-row reasons

    /// Duplicate detection is bucketed by `(payee, amount)` so each
    /// bucket is short and the inner loop only runs on transactions
    /// that already agree on the two hardest filters.
    static func duplicateCandidate(ctx: ReviewQueueContext) -> [ReviewItem] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: ctx.now) else {
            return []
        }
        // Scope the candidate set once — avoids re-filtering inside the
        // grouping closure.
        let candidates = ctx.transactions.filter { !$0.isTransfer && $0.date > cutoff }
        guard candidates.count >= 2 else { return [] }

        struct Bucket: Hashable { let payee: String; let amount: Decimal }
        let grouped = Dictionary(grouping: candidates) { Bucket(payee: $0.payee, amount: $0.amount) }

        let window: TimeInterval = 2 * 24 * 60 * 60
        var flagged = Set<UUID>()
        var out: [ReviewItem] = []

        for (_, rows) in grouped where rows.count >= 2 {
            let sorted = rows.sorted { $0.date < $1.date }
            for i in sorted.indices {
                let tx = sorted[i]
                var j = i + 1
                while j < sorted.count,
                      sorted[j].date.timeIntervalSince(tx.date) <= window {
                    let other = sorted[j]
                    for candidate in [tx, other] where flagged.insert(candidate.id).inserted {
                        out.append(make(.duplicateCandidate, severity: .suggested, for: candidate))
                    }
                    j += 1
                }
            }
        }
        return out
    }

    /// Per-payee outlier: amount > 6× the payee's recent median, with
    /// at least 5 prior samples in the 180-day window.
    static func unusualAmount(ctx: ReviewQueueContext) -> [ReviewItem] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -180, to: ctx.now) else {
            return []
        }
        let candidates = ctx.transactions.filter { !$0.isTransfer && $0.date > cutoff }
        let byPayee = Dictionary(grouping: candidates, by: \.payee)
        var out: [ReviewItem] = []

        for (_, group) in byPayee where group.count >= 5 {
            let magnitudes = group.map { abs($0.amount) }.sorted()
            let median = magnitudes[magnitudes.count / 2]
            guard median > 0 else { continue }
            let threshold = median * 6
            for tx in group where !tx.isReviewed && abs(tx.amount) > threshold {
                out.append(make(.unusualAmount, severity: .suggested, for: tx))
            }
        }
        return out
    }

    // MARK: - Template-linked reasons

    static func unlinkedRecurring(ctx: ReviewQueueContext) -> [ReviewItem] {
        guard !ctx.activeTemplates.isEmpty,
              let cutoff = Calendar.current.date(byAdding: .day, value: -45, to: ctx.now) else {
            return []
        }
        let unlinkedTxs = ctx.transactions.filter {
            $0.recurringTemplateID == nil && !$0.isTransfer && $0.date > cutoff && !$0.isReviewed
        }
        guard !unlinkedTxs.isEmpty else { return [] }

        let dayWindow: TimeInterval = 5 * 24 * 60 * 60
        let tolerance = Decimal(0.05)
        var out: [ReviewItem] = []

        for tx in unlinkedTxs {
            for tpl in ctx.activeTemplates where tpl.isIncome == tx.isIncome {
                let anchor = tpl.lastMaterializedDate ?? tpl.nextOccurrence
                guard abs(tx.date.timeIntervalSince(anchor)) <= dayWindow else { continue }
                let delta = abs(tx.amount - tpl.amount)
                guard delta <= tpl.amount * tolerance else { continue }
                out.append(ReviewItem(
                    id: UUID(),
                    reason: .unlinkedRecurring,
                    severity: .suggested,
                    transactionID: tx.id,
                    recurringTemplateID: tpl.id,
                    subscriptionID: nil,
                    dedupeKey: "unlinkedRecurring:\(tx.id.uuidString):\(tpl.id.uuidString)",
                    sortDate: tx.date,
                    amountMagnitude: abs(tx.amount)
                ))
                break
            }
        }
        return out
    }

    static func unlinkedSubscription(ctx: ReviewQueueContext) -> [ReviewItem] {
        let now = ctx.now
        var out: [ReviewItem] = []
        for sub in ctx.subscriptions where sub.status == .active {
            guard let last = sub.lastChargeDate else { continue }
            let grace = sub.effectiveCadenceDays + 10
            let daysSince = Calendar.current.dateComponents([.day], from: last, to: now).day ?? 0
            guard daysSince > grace else { continue }
            out.append(ReviewItem(
                id: UUID(),
                reason: .unlinkedSubscription,
                severity: .suggested,
                transactionID: nil,
                recurringTemplateID: nil,
                subscriptionID: sub.id,
                dedupeKey: "unlinkedSubscription:\(sub.id.uuidString)",
                sortDate: last,
                amountMagnitude: sub.amount
            ))
        }
        return out
    }

    // MARK: - Factory

    /// Standardized transaction-bound item builder. Callers pass only
    /// reason + severity + the transaction — everything else is
    /// boilerplate.
    @inline(__always)
    private static func make(
        _ reason: ReviewReasonCode,
        severity: ReviewSeverity,
        for tx: Transaction
    ) -> ReviewItem {
        ReviewItem(
            id: UUID(),
            reason: reason,
            severity: severity,
            transactionID: tx.id,
            recurringTemplateID: nil,
            subscriptionID: nil,
            dedupeKey: "\(reason.rawValue):\(tx.id.uuidString)",
            sortDate: tx.date,
            amountMagnitude: abs(tx.amount)
        )
    }
}
