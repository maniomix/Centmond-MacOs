import Foundation
import SwiftData

// ============================================================
// MARK: - AI Subscription Optimizer
// ============================================================
//
// Analyzes active subscriptions for savings opportunities, trial
// risk, price hikes, duplicate billing, and overlap. Pure heuristic
// — no LLM.
//
// Expanded in P6: now produces actionable recommendations with a
// typed `actionType` so the UI can render a row + button ("Pause",
// "Cancel", "Switch to annual") that applies directly via the
// `apply(...)` helper. The chat-surface path still uses `summary()`
// to inline-describe opportunities.
// ============================================================

struct SubscriptionOptimizationResult {
    let totalMonthlyCost: Decimal
    let totalYearlyCost: Decimal
    let recommendations: [Recommendation]
    let potentialSavings: Decimal

    struct Recommendation: Identifiable {
        let id = UUID()
        let type: RecommendationType
        let subscriptionID: UUID?
        let subscriptionName: String
        let reason: String
        let potentialSaving: Decimal
        let confidence: Double
        let urgency: Urgency
        let actionType: ActionType

        enum RecommendationType {
            case cancel
            case downgrade
            case overlap
            case freeAlternative
            case trialEnding
            case priceHike
            case annualSavings
            case pastDue
            case duplicateCharge
        }

        enum Urgency {
            case info
            case suggestion
            case attention   // yellow
            case urgent      // red
        }

        /// Bound to a concrete mutation the UI can perform. Intentionally
        /// narrower than `AIAction` — these are local, reversible, and
        /// don't need the trust/preview layer for the optimizer's
        /// pre-vetted heuristics.
        enum ActionType {
            case cancel
            case pause
            case switchToAnnual
            case acknowledgePriceChange
            case acknowledgeDuplicate
            case review              // no mutation; opens detail view
        }
    }

    func summary() -> String {
        var lines: [String] = []
        lines.append("Total subscriptions: \(fmt(totalMonthlyCost))/month (\(fmt(totalYearlyCost))/year)")

        if recommendations.isEmpty {
            lines.append("No optimization opportunities found.")
        } else {
            lines.append("Found \(recommendations.count) optimization opportunities:")
            for rec in recommendations {
                lines.append("  - \(rec.subscriptionName): \(rec.reason) (save \(fmt(rec.potentialSaving))/mo)")
            }
            lines.append("Potential monthly savings: \(fmt(potentialSavings))")
        }
        return lines.joined(separator: "\n")
    }

    private func fmt(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }
}

@MainActor @Observable
final class AISubscriptionOptimizer {
    static let shared = AISubscriptionOptimizer()

    private init() {}

    // Tuning knobs.
    private let annualSavingsAssumedDiscount: Double = 0.15   // typical "pay annual, save 15-17%"
    private let annualSavingsMinMonthly: Decimal = 5          // don't nag on sub-$5 subs
    private let overlapCoverageShare: Double = 0.25

    func analyze(context: ModelContext) -> SubscriptionOptimizationResult {
        let descriptor = FetchDescriptor<Subscription>()
        let all = (try? context.fetch(descriptor)) ?? []
        let subs = all.filter { $0.status == .active || $0.status == .trial }

        let totalMonthly = subs.reduce(Decimal.zero) { $0 + $1.monthlyCost }
        let totalYearly = totalMonthly * 12

        var recommendations: [SubscriptionOptimizationResult.Recommendation] = []

        recommendations.append(contentsOf: detectTrialsEndingSoon(subs))
        recommendations.append(contentsOf: detectPriceHikes(subs))
        recommendations.append(contentsOf: detectDuplicateCharges(subs))
        recommendations.append(contentsOf: detectPastDue(subs))
        recommendations.append(contentsOf: detectOverlaps(subs))
        recommendations.append(contentsOf: detectHighCost(subs, totalMonthly: totalMonthly))
        recommendations.append(contentsOf: detectAnnualSavings(subs))
        recommendations.append(contentsOf: detectPotentiallyUnused(subs))
        recommendations.append(contentsOf: suggestFreeAlternatives(subs))

        let potentialSavings = recommendations.reduce(Decimal.zero) { $0 + $1.potentialSaving }

        return SubscriptionOptimizationResult(
            totalMonthlyCost: totalMonthly,
            totalYearlyCost: totalYearly,
            recommendations: recommendations.sorted(by: rankRec),
            potentialSavings: potentialSavings
        )
    }

    /// Ranking: urgency first, then savings. Urgent (past due / duplicate /
    /// trial ending today) always floats to top so the user sees it before
    /// cost-reduction tips.
    private func rankRec(
        _ lhs: SubscriptionOptimizationResult.Recommendation,
        _ rhs: SubscriptionOptimizationResult.Recommendation
    ) -> Bool {
        if lhs.urgency != rhs.urgency { return urgencyRank(lhs.urgency) < urgencyRank(rhs.urgency) }
        return NSDecimalNumber(decimal: lhs.potentialSaving).doubleValue
             > NSDecimalNumber(decimal: rhs.potentialSaving).doubleValue
    }

    private func urgencyRank(_ u: SubscriptionOptimizationResult.Recommendation.Urgency) -> Int {
        switch u {
        case .urgent: return 0
        case .attention: return 1
        case .suggestion: return 2
        case .info: return 3
        }
    }

    // MARK: - New detectors (P6)

    private func detectTrialsEndingSoon(_ subs: [Subscription]) -> [SubscriptionOptimizationResult.Recommendation] {
        let cal = Calendar.current
        return subs.compactMap { sub in
            guard sub.isTrial, let end = sub.trialEndsAt else { return nil }
            let daysLeft = cal.dateComponents([.day], from: .now, to: end).day ?? Int.max
            guard daysLeft <= 7, daysLeft >= 0 else { return nil }
            let urgency: SubscriptionOptimizationResult.Recommendation.Urgency =
                daysLeft <= 1 ? .urgent : (daysLeft <= 3 ? .attention : .suggestion)
            let reason = daysLeft == 0
                ? "Trial ends today — decide to keep or cancel"
                : "Trial ends in \(daysLeft) day\(daysLeft == 1 ? "" : "s") — will start charging \(fmtDec(sub.amount))/\(sub.billingCycle.rawValue)"
            return .init(
                type: .trialEnding,
                subscriptionID: sub.id,
                subscriptionName: sub.serviceName,
                reason: reason,
                potentialSaving: sub.monthlyCost,
                confidence: 0.95,
                urgency: urgency,
                actionType: .cancel
            )
        }
    }

    private func detectPriceHikes(_ subs: [Subscription]) -> [SubscriptionOptimizationResult.Recommendation] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .month, value: -3, to: .now) ?? .distantPast
        var recs: [SubscriptionOptimizationResult.Recommendation] = []
        for sub in subs {
            // Latest unacknowledged price change in the last 3 months.
            let recent = sub.priceHistory
                .filter { $0.date >= cutoff && !$0.acknowledged }
                .sorted { $0.date > $1.date }
            guard let change = recent.first, change.oldAmount > 0 else { continue }
            let pctText = String(format: "%+.0f%%", change.changePercent * 100)
            let monthlyDeltaDecimal = change.newAmount - change.oldAmount
            let monthlyDelta = max(monthlyDeltaDecimal, 0)
            recs.append(.init(
                type: .priceHike,
                subscriptionID: sub.id,
                subscriptionName: sub.serviceName,
                reason: "Price changed \(pctText) on \(change.date.formatted(.dateTime.month(.abbreviated).day())) — now \(fmtDec(change.newAmount))",
                potentialSaving: monthlyDelta,
                confidence: 0.9,
                urgency: change.changePercent >= 0.20 ? .attention : .suggestion,
                actionType: .acknowledgePriceChange
            ))
        }
        return recs
    }

    private func detectDuplicateCharges(_ subs: [Subscription]) -> [SubscriptionOptimizationResult.Recommendation] {
        var recs: [SubscriptionOptimizationResult.Recommendation] = []
        for sub in subs {
            let dupes = sub.charges.filter(\.isFlaggedDuplicate)
            guard !dupes.isEmpty else { continue }
            let newest = dupes.max { $0.date < $1.date }
            let date = newest?.date.formatted(.dateTime.month(.abbreviated).day()) ?? ""
            recs.append(.init(
                type: .duplicateCharge,
                subscriptionID: sub.id,
                subscriptionName: sub.serviceName,
                reason: "Possible double-billing detected near \(date) — check your statement",
                potentialSaving: dupes.reduce(Decimal.zero) { $0 + $1.amount },
                confidence: 0.75,
                urgency: .urgent,
                actionType: .acknowledgeDuplicate
            ))
        }
        return recs
    }

    private func detectPastDue(_ subs: [Subscription]) -> [SubscriptionOptimizationResult.Recommendation] {
        subs.filter(\.isPastDue).map { sub in
            .init(
                type: .pastDue,
                subscriptionID: sub.id,
                subscriptionName: sub.serviceName,
                reason: "Expected charge on \(sub.nextPaymentDate.formatted(.dateTime.month(.abbreviated).day())) hasn't arrived",
                potentialSaving: 0,
                confidence: 0.8,
                urgency: .attention,
                actionType: .review
            )
        }
    }

    private func detectAnnualSavings(_ subs: [Subscription]) -> [SubscriptionOptimizationResult.Recommendation] {
        subs.compactMap { sub in
            guard sub.billingCycle == .monthly else { return nil }
            guard sub.monthlyCost >= annualSavingsMinMonthly else { return nil }
            // Estimated savings: (monthly × 12) × discount
            let yearly = sub.monthlyCost * 12
            let savings = yearly * Decimal(annualSavingsAssumedDiscount)
            let monthlyEquiv = savings / 12
            return .init(
                type: .annualSavings,
                subscriptionID: sub.id,
                subscriptionName: sub.serviceName,
                reason: "Monthly plan — annual billing typically saves ~15% (~\(fmtDec(savings))/yr)",
                potentialSaving: monthlyEquiv,
                confidence: 0.55,
                urgency: .info,
                actionType: .switchToAnnual
            )
        }
    }

    // MARK: - Existing detectors (kept from prior version)

    private func detectOverlaps(_ subs: [Subscription]) -> [SubscriptionOptimizationResult.Recommendation] {
        var recs: [SubscriptionOptimizationResult.Recommendation] = []

        let overlapGroups: [String: [String]] = [
            "Music Streaming": ["spotify", "apple music", "youtube music", "tidal", "deezer", "amazon music"],
            "Video Streaming": ["netflix", "hulu", "disney+", "disney plus", "hbo", "paramount+", "peacock",
                                "apple tv", "prime video", "amazon prime"],
            "Cloud Storage": ["icloud", "google one", "dropbox", "onedrive"],
            "News": ["nyt", "new york times", "wsj", "wall street journal", "washington post", "apple news"],
            "Fitness": ["peloton", "fitbit", "strava", "nike run", "myfitnesspal"]
        ]

        for (groupName, keywords) in overlapGroups {
            let matching = subs.filter { sub in
                keywords.contains { sub.serviceName.lowercased().contains($0) }
            }
            if matching.count > 1 {
                let sorted = matching.sorted {
                    NSDecimalNumber(decimal: $0.monthlyCost).doubleValue <
                    NSDecimalNumber(decimal: $1.monthlyCost).doubleValue
                }
                for sub in sorted.dropFirst() {
                    recs.append(.init(
                        type: .overlap,
                        subscriptionID: sub.id,
                        subscriptionName: sub.serviceName,
                        reason: "Overlaps with other \(groupName) services",
                        potentialSaving: sub.monthlyCost,
                        confidence: 0.7,
                        urgency: .suggestion,
                        actionType: .cancel
                    ))
                }
            }
        }

        return recs
    }

    private func detectHighCost(_ subs: [Subscription], totalMonthly: Decimal) -> [SubscriptionOptimizationResult.Recommendation] {
        guard totalMonthly > 0 else { return [] }
        var recs: [SubscriptionOptimizationResult.Recommendation] = []

        let totalDouble = NSDecimalNumber(decimal: totalMonthly).doubleValue
        for sub in subs {
            let subDouble = NSDecimalNumber(decimal: sub.monthlyCost).doubleValue
            let share = subDouble / totalDouble
            if share > overlapCoverageShare && subs.count > 2 {
                recs.append(.init(
                    type: .downgrade,
                    subscriptionID: sub.id,
                    subscriptionName: sub.serviceName,
                    reason: "Takes \(Int(share * 100))% of your subscription budget — consider a cheaper plan",
                    potentialSaving: sub.monthlyCost / 3,
                    confidence: 0.5,
                    urgency: .suggestion,
                    actionType: .review
                ))
            }
        }

        return recs
    }

    private func detectPotentiallyUnused(_ subs: [Subscription]) -> [SubscriptionOptimizationResult.Recommendation] {
        var recs: [SubscriptionOptimizationResult.Recommendation] = []

        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
        for sub in subs {
            if sub.createdAt < sixMonthsAgo {
                recs.append(.init(
                    type: .cancel,
                    subscriptionID: sub.id,
                    subscriptionName: sub.serviceName,
                    reason: "Active for 6+ months — worth reviewing if still needed",
                    potentialSaving: sub.monthlyCost,
                    confidence: 0.3,
                    urgency: .info,
                    actionType: .pause
                ))
            }
        }

        return recs
    }

    private func suggestFreeAlternatives(_ subs: [Subscription]) -> [SubscriptionOptimizationResult.Recommendation] {
        var recs: [SubscriptionOptimizationResult.Recommendation] = []

        let freeAlts: [String: String] = [
            "lastpass": "Bitwarden (free)",
            "1password": "Bitwarden (free)",
            "grammarly": "LanguageTool (free tier)",
            "canva": "Canva has a generous free tier",
            "zoom": "Google Meet (free)",
            "slack": "Discord (free)"
        ]

        for sub in subs {
            let lower = sub.serviceName.lowercased()
            for (keyword, alternative) in freeAlts {
                if lower.contains(keyword) {
                    recs.append(.init(
                        type: .freeAlternative,
                        subscriptionID: sub.id,
                        subscriptionName: sub.serviceName,
                        reason: "Consider \(alternative)",
                        potentialSaving: sub.monthlyCost,
                        confidence: 0.4,
                        urgency: .info,
                        actionType: .cancel
                    ))
                }
            }
        }

        return recs
    }

    // MARK: - Goals bridge (P9)

    /// Returns cancel/pause/downgrade candidates whose combined monthly cost
    /// covers `needed`. Greedy — picks the smallest recommendations first
    /// so the user sees the least-painful combination. Returns empty list
    /// when existing active subs can't cover the gap.
    ///
    /// Intended for a Goal detail panel row: "Cancel Netflix + Spotify to
    /// free $22/mo for Vacation Fund." Keeps the cross-feature bridge out of
    /// the UI layer so both the chat persona and the goal inspector can
    /// consume it.
    @MainActor
    static func suggestionsForGoal(
        needing monthlyAmount: Decimal,
        context: ModelContext
    ) -> [SubscriptionOptimizationResult.Recommendation] {
        guard monthlyAmount > 0 else { return [] }
        let result = AISubscriptionOptimizer.shared.analyze(context: context)
        // Only cancel / pause / switchToAnnual recs free real money. Drop
        // acknowledgements and review-only rows.
        let savers = result.recommendations.filter { rec in
            switch rec.actionType {
            case .cancel, .pause, .switchToAnnual: return true
            default: return false
            }
        }
        let sorted = savers.sorted {
            NSDecimalNumber(decimal: $0.potentialSaving).doubleValue
              < NSDecimalNumber(decimal: $1.potentialSaving).doubleValue
        }

        var running: Decimal = 0
        var out: [SubscriptionOptimizationResult.Recommendation] = []
        for rec in sorted {
            out.append(rec)
            running += rec.potentialSaving
            if running >= monthlyAmount { break }
        }
        return running >= monthlyAmount ? out : []
    }

    // MARK: - Apply

    /// Executes a recommendation's `actionType` against the referenced
    /// subscription. UI-initiated mutations — we intentionally skip the
    /// trust/preview layer that `AIActionExecutor` enforces for
    /// LLM-originated actions. The recommendations themselves were produced
    /// by vetted heuristics, not a model, so the user's click is the
    /// authorization.
    @discardableResult
    static func apply(
        _ rec: SubscriptionOptimizationResult.Recommendation,
        in context: ModelContext
    ) -> Bool {
        guard let id = rec.subscriptionID else { return false }
        var descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let sub = (try? context.fetch(descriptor))?.first else { return false }

        switch rec.actionType {
        case .cancel:
            sub.status = .cancelled
            sub.updatedAt = .now
            return true

        case .pause:
            sub.status = .paused
            sub.updatedAt = .now
            return true

        case .switchToAnnual:
            // Scale the current amount to an annual one using the 15%
            // typical-discount assumption. User can edit after — this is
            // a first-pass estimate, not a fact from the provider.
            let discount = Decimal(0.85)
            sub.amount = sub.amount * 12 * discount
            sub.billingCycle = .annual
            sub.updatedAt = .now
            return true

        case .acknowledgePriceChange:
            for change in sub.priceHistory where !change.acknowledged {
                change.acknowledged = true
            }
            sub.updatedAt = .now
            return true

        case .acknowledgeDuplicate:
            for charge in sub.charges where charge.isFlaggedDuplicate {
                charge.isFlaggedDuplicate = false
            }
            sub.updatedAt = .now
            return true

        case .review:
            // No mutation — caller opens the subscription detail view.
            return true
        }
    }

    // MARK: - Helpers

    private func fmtDec(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }
}
