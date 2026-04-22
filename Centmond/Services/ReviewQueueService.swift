import Foundation
import SwiftData

/// Central producer of `ReviewItem`s surfaced by the Review Queue hub.
///
/// Performance note: every detector used to run its own FetchDescriptor
/// over `Transaction`, so `buildQueue` triggered 9+ full table scans and
/// any view that inspected it a few times per body pass paid that cost
/// multiple times. The refactor below fetches transactions (and the
/// other shared tables) exactly once, passes the snapshot to every
/// detector via `ReviewQueueContext`, and lets detectors filter + group
/// in memory. On a 5 k row store this drops hub-render CPU from ~110 %
/// to idle-range.
enum ReviewQueueService {

    // MARK: - Tunables

    /// Keep any one reason from drowning the hub — matches the cap the
    /// Insights rebuild settled on.
    static let perReasonCap = 50

    // MARK: - Entry point

    /// Build the full queue from the current context. Results are sorted
    /// by severity (blocker first) → sortDate (newest first) → amount
    /// magnitude (largest first), then capped per-reason.
    static func buildQueue(in context: ModelContext) -> [ReviewItem] {
        let ctx = ReviewQueueContext.load(from: context)

        var items: [ReviewItem] = []
        items.reserveCapacity(256)
        // One pass over ctx.transactions covers 7 row-local reasons.
        items.append(contentsOf: ReviewDetectors.rowLocal(ctx: ctx))
        items.append(contentsOf: ReviewDetectors.duplicateCandidate(ctx: ctx))
        items.append(contentsOf: ReviewDetectors.unusualAmount(ctx: ctx))
        items.append(contentsOf: ReviewDetectors.unlinkedRecurring(ctx: ctx))
        items.append(contentsOf: ReviewDetectors.unlinkedSubscription(ctx: ctx))

        let telemetry = MainActor.assumeIsolated { ReviewQueueTelemetry.shared }
        let muted = telemetry.mutedReasons
        let filtered = items.filter {
            !ctx.dismissedKeys.contains($0.dismissalKey) && !muted.contains($0.reason)
        }
        return capped(sorted(filtered))
    }

    static func counts(in context: ModelContext) -> [ReviewReasonCode: Int] {
        let queue = buildQueue(in: context)
        return Dictionary(grouping: queue, by: \.reason).mapValues(\.count)
    }

    // MARK: - Dismissal

    /// Persist a dismissal so the item stops surfacing. Reuses
    /// `DismissedDetection` with the "review:" prefix, per the shared-key
    /// prefix rule.
    static func dismiss(_ item: ReviewItem, in context: ModelContext) {
        let key = item.dismissalKey
        let existing = try? context.fetch(FetchDescriptor<DismissedDetection>(
            predicate: #Predicate { $0.merchantKey == key }
        ))
        if (existing ?? []).isEmpty {
            let record = DismissedDetection(
                merchantKey: key,
                lastDetectedAmount: item.amountMagnitude,
                lastDetectedCycle: .monthly
            )
            context.insert(record)
        }
        MainActor.assumeIsolated { ReviewQueueTelemetry.shared.recordResolved() }
    }

    static func undismiss(_ item: ReviewItem, in context: ModelContext) {
        let key = item.dismissalKey
        let matches = (try? context.fetch(FetchDescriptor<DismissedDetection>(
            predicate: #Predicate { $0.merchantKey == key }
        ))) ?? []
        for record in matches { context.delete(record) }
    }

    // MARK: - Pipeline helpers

    private static func sorted(_ items: [ReviewItem]) -> [ReviewItem] {
        items.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            if a.sortDate != b.sortDate { return a.sortDate > b.sortDate }
            return a.amountMagnitude > b.amountMagnitude
        }
    }

    private static func capped(_ items: [ReviewItem]) -> [ReviewItem] {
        var perReason: [ReviewReasonCode: Int] = [:]
        var out: [ReviewItem] = []
        out.reserveCapacity(items.count)
        for item in items {
            let used = perReason[item.reason, default: 0]
            guard used < perReasonCap else { continue }
            perReason[item.reason] = used + 1
            out.append(item)
        }
        return out
    }
}

// MARK: - Shared snapshot

/// Single pre-fetched snapshot fed to every detector so `buildQueue`
/// runs exactly one SwiftData query per entity type per call, no matter
/// how many detectors are active. Built once by `ReviewQueueService`;
/// detectors treat it as read-only.
struct ReviewQueueContext {
    let now: Date
    let transactions: [Transaction]
    let subscriptions: [Subscription]
    let activeTemplates: [RecurringTransaction]
    let dismissedKeys: Set<String>

    static func load(from context: ModelContext) -> ReviewQueueContext {
        let txDescriptor = FetchDescriptor<Transaction>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let subDescriptor = FetchDescriptor<Subscription>()
        let tmplDescriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive }
        )
        let dismissedDescriptor = FetchDescriptor<DismissedDetection>(
            predicate: #Predicate { $0.merchantKey.starts(with: "review:") }
        )

        let txs = (try? context.fetch(txDescriptor)) ?? []
        let subs = (try? context.fetch(subDescriptor)) ?? []
        let tmpls = (try? context.fetch(tmplDescriptor)) ?? []
        let dismissed = (try? context.fetch(dismissedDescriptor)) ?? []

        return ReviewQueueContext(
            now: .now,
            transactions: txs,
            subscriptions: subs,
            activeTemplates: tmpls,
            dismissedKeys: Set(dismissed.map(\.merchantKey))
        )
    }
}
