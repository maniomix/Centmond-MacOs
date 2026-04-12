import Foundation
import SwiftData

// ============================================================
// MARK: - AI Subscription Optimizer
// ============================================================
//
// Analyzes active subscriptions to find savings opportunities:
// cancellation candidates, overlaps, downgrades, and high-cost.
//
// Pure heuristic -- no LLM needed.
//
// macOS Centmond: ModelContext, Decimal amounts,
// Subscription.serviceName instead of merchantName.
//
// ============================================================

struct SubscriptionOptimizationResult {
    let totalMonthlyCost: Decimal
    let totalYearlyCost: Decimal
    let recommendations: [Recommendation]
    let potentialSavings: Decimal

    struct Recommendation: Identifiable {
        let id = UUID()
        let type: RecommendationType
        let subscriptionName: String
        let reason: String
        let potentialSaving: Decimal
        let confidence: Double

        enum RecommendationType {
            case cancel
            case downgrade
            case overlap
            case freeAlternative
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

    func analyze(context: ModelContext) -> SubscriptionOptimizationResult {
        let activeStatus = SubscriptionStatus.active
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        let subs = (try? context.fetch(descriptor)) ?? []

        let totalMonthly = subs.reduce(Decimal.zero) { $0 + $1.monthlyCost }
        let totalYearly = totalMonthly * 12

        var recommendations: [SubscriptionOptimizationResult.Recommendation] = []

        recommendations.append(contentsOf: detectOverlaps(subs))
        recommendations.append(contentsOf: detectHighCost(subs, totalMonthly: totalMonthly))
        recommendations.append(contentsOf: detectPotentiallyUnused(subs))
        recommendations.append(contentsOf: suggestFreeAlternatives(subs))

        let potentialSavings = recommendations.reduce(Decimal.zero) { $0 + $1.potentialSaving }

        return SubscriptionOptimizationResult(
            totalMonthlyCost: totalMonthly,
            totalYearlyCost: totalYearly,
            recommendations: recommendations.sorted {
                NSDecimalNumber(decimal: $0.potentialSaving).doubleValue >
                NSDecimalNumber(decimal: $1.potentialSaving).doubleValue
            },
            potentialSavings: potentialSavings
        )
    }

    // MARK: - Detection Methods

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
                        subscriptionName: sub.serviceName,
                        reason: "Overlaps with other \(groupName) services",
                        potentialSaving: sub.monthlyCost,
                        confidence: 0.7
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
            if share > 0.25 && subs.count > 2 {
                recs.append(.init(
                    type: .downgrade,
                    subscriptionName: sub.serviceName,
                    reason: "Takes \(Int(share * 100))% of your subscription budget -- consider a cheaper plan",
                    potentialSaving: sub.monthlyCost / 3,
                    confidence: 0.5
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
                    subscriptionName: sub.serviceName,
                    reason: "Active for 6+ months -- worth reviewing if still needed",
                    potentialSaving: sub.monthlyCost,
                    confidence: 0.3
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
                        subscriptionName: sub.serviceName,
                        reason: "Consider \(alternative)",
                        potentialSaving: sub.monthlyCost,
                        confidence: 0.4
                    ))
                }
            }
        }

        return recs
    }
}
