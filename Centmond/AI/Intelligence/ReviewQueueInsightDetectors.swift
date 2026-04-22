import Foundation
import SwiftData

// ============================================================
// MARK: - Review Queue Insight Detectors (P7)
// ============================================================
//
// Emits insights when the Review Queue grows past engagement
// thresholds or accumulates blockers. Namespaced dedupe keys
// under "review:" so dismissals stay siloed per the shared-key
// prefix rule.
// ============================================================

enum ReviewQueueInsightDetectors {

    /// Aggregate entry the engine calls.
    static func all(context: ModelContext) -> [AIInsight] {
        var out: [AIInsight] = []
        let queue = ReviewQueueService.buildQueue(in: context)
        out.append(contentsOf: backlog(queue: queue))
        out.append(contentsOf: blockers(queue: queue))
        return out
    }

    /// Fires when the queue balloons past 15 items — implies the user is
    /// ignoring review entirely, which silently distorts budget + runway
    /// math.
    private static func backlog(queue: [ReviewItem]) -> [AIInsight] {
        let threshold = 15
        guard queue.count >= threshold else { return [] }
        let title = "Review queue is piling up"
        let warning = "\(queue.count) items are waiting for review. Uncategorized or pending rows skew budget totals and runway projections."
        let advice = "Open the Review Queue and hit Triage — most items take a single keypress."
        return [AIInsight(
            kind: .patternDetected,
            title: title,
            warning: warning,
            severity: .warning,
            advice: advice,
            cause: "Items flagged by Review Queue detectors but not yet accepted or dismissed.",
            dedupeKey: "review:backlog"
        )]
    }

    /// Fires when ≥1 blocker-severity item exists. Blockers (missing
    /// account, negative income, unlinked subscription) silently break
    /// balance math, so they get their own insight even with a small
    /// overall queue.
    private static func blockers(queue: [ReviewItem]) -> [AIInsight] {
        let blockerItems = queue.filter { $0.severity == .blocker }
        guard !blockerItems.isEmpty else { return [] }
        let count = blockerItems.count
        let title = count == 1 ? "1 review-queue blocker" : "\(count) review-queue blockers"
        let warning = "Blockers leave transactions out of balance and net-worth calculations. Resolve them before trusting the numbers."
        return [AIInsight(
            kind: .cashflowRisk,
            title: title,
            warning: warning,
            severity: .critical,
            advice: "Open the Review Queue and filter by the blocker reason (Missing account, Negative income, or Unlinked subscription).",
            cause: "Transactions with missing accounts, negative amounts, or subscriptions with no recent matching charge.",
            dedupeKey: "review:blockers"
        )]
    }
}
