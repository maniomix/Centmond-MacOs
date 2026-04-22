import Foundation
import SwiftData

// ============================================================
// MARK: - Net Worth Insight Detectors (P8)
// ============================================================
//
// Four detectors over `NetWorthSnapshot` history. All dedupe
// keys are namespaced under "networth:" per the
// "DismissedDetection Key Prefix" memory rule so they share a
// dismissal silo cleanly with the other Net-Worth surfaces and
// don't cross-silence Cashflow / Subscriptions / etc.
//
// Detector ID convention used by the engine: first two segments
// of the dedupe key, e.g. "networth:drop". So muting "Net Worth
// drop" insights mutes the whole detector regardless of which
// percent-bucket key fires.
// ============================================================

@MainActor
enum NetWorthInsightDetectors {

    // MARK: - Public entry — all detectors

    static func all(context: ModelContext) -> [AIInsight] {
        let snapshots = (try? context.fetch(FetchDescriptor<NetWorthSnapshot>(
            sortBy: [SortDescriptor(\.date)]
        ))) ?? []
        guard snapshots.count >= 7 else { return [] }   // need at least a week of history

        var out: [AIInsight] = []
        out.append(contentsOf: bigDrop(snapshots: snapshots))
        out.append(contentsOf: liabilityReduced(snapshots: snapshots))
        out.append(contentsOf: newMilestone(snapshots: snapshots))
        out.append(contentsOf: stagnant(snapshots: snapshots))
        return out
    }

    // MARK: - Drop > 5% over the last 30d

    private static func bigDrop(snapshots: [NetWorthSnapshot]) -> [AIInsight] {
        guard let latest = snapshots.last else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: latest.date) ?? .distantPast
        guard let baseline = snapshots.last(where: { $0.date <= cutoff }),
              baseline.netWorth > 0 else { return [] }

        let drop = baseline.netWorth - latest.netWorth
        guard drop > 0 else { return [] }
        let pct = Double(truncating: (drop / baseline.netWorth) as NSDecimalNumber)
        guard pct >= 0.05 else { return [] }

        let bucket: String
        let severity: AIInsight.Severity
        if pct >= 0.15 {
            bucket = "gt15"; severity = .critical
        } else if pct >= 0.10 {
            bucket = "gt10"; severity = .warning
        } else {
            bucket = "gt05"; severity = .watch
        }

        return [AIInsight(
            kind: .netWorthDrop,
            title: "Net worth down \(Int(pct * 100))% in 30 days",
            warning: "You went from \(CurrencyFormat.standard(baseline.netWorth)) to \(CurrencyFormat.standard(latest.netWorth)) — a \(CurrencyFormat.standard(drop)) drop.",
            severity: severity,
            advice: "Open the trend chart and scrub back through the dip — usually it's a known purchase, a market dip, or new debt.",
            cause: "Comparing today's snapshot vs the closest snapshot to 30 days ago.",
            expiresAt: Calendar.current.date(byAdding: .day, value: 4, to: .now),
            dedupeKey: "networth:drop:\(bucket)",
            deeplink: .netWorth
        )]
    }

    // MARK: - Liability reduced ≥10% over 30d (good news)

    private static func liabilityReduced(snapshots: [NetWorthSnapshot]) -> [AIInsight] {
        guard let latest = snapshots.last else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: latest.date) ?? .distantPast
        guard let baseline = snapshots.last(where: { $0.date <= cutoff }),
              baseline.totalLiabilities > 0 else { return [] }

        let drop = baseline.totalLiabilities - latest.totalLiabilities
        guard drop > 0 else { return [] }
        let pct = Double(truncating: (drop / baseline.totalLiabilities) as NSDecimalNumber)
        guard pct >= 0.10 else { return [] }

        return [AIInsight(
            kind: .netWorthMilestone,
            title: "Debt down \(Int(pct * 100))% this month",
            warning: "Your liabilities fell from \(CurrencyFormat.standard(baseline.totalLiabilities)) to \(CurrencyFormat.standard(latest.totalLiabilities)).",
            severity: .positive,
            advice: "Keep the momentum — try the Avalanche strategy in the Debt Payoff card to compound the savings.",
            cause: "Total of all liability balances vs the closest snapshot to 30 days ago.",
            expiresAt: Calendar.current.date(byAdding: .day, value: 7, to: .now),
            dedupeKey: "networth:liabReduced:m\(currentMonthKey())",
            deeplink: .netWorth
        )]
    }

    // MARK: - New milestone hit in the last 7 days

    private static func newMilestone(snapshots: [NetWorthSnapshot]) -> [AIInsight] {
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        let milestones = NetWorthMilestoneDetector.detect(from: snapshots)
            .filter { $0.date >= recentCutoff }
        guard !milestones.isEmpty else { return [] }

        return milestones.prefix(2).map { m in
            AIInsight(
                kind: .netWorthMilestone,
                title: m.title,
                warning: m.detail,
                severity: .positive,
                advice: "Worth taking a beat to acknowledge — small wins compound.",
                cause: "Derived from your snapshot history.",
                expiresAt: Calendar.current.date(byAdding: .day, value: 14, to: .now),
                dedupeKey: "networth:milestone:\(m.id)",
                deeplink: .netWorth
            )
        }
    }

    // MARK: - Stagnant for 60+ days (±2%)

    private static func stagnant(snapshots: [NetWorthSnapshot]) -> [AIInsight] {
        guard let latest = snapshots.last,
              latest.netWorth > 0 else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: latest.date) ?? .distantPast
        let window = snapshots.filter { $0.date >= cutoff }
        guard window.count >= 30 else { return [] }    // need a real window

        let values = window.map { Double(truncating: $0.netWorth as NSDecimalNumber) }
        guard let lo = values.min(), let hi = values.max(), lo > 0 else { return [] }
        let band = (hi - lo) / lo
        guard band <= 0.02 else { return [] }

        return [AIInsight(
            kind: .netWorthStagnant,
            title: "Net worth has been flat for 60+ days",
            warning: "Your balance has barely moved (±\(String(format: "%.1f", band * 100))%) since \(window.first!.date.formatted(.dateTime.month(.abbreviated).day())).",
            severity: .watch,
            advice: "Set a goal contribution rule on your next paycheck — passive saving moves the needle faster than willpower.",
            cause: "Range between min and max net worth over the last 60 days is under 2%.",
            expiresAt: Calendar.current.date(byAdding: .day, value: 14, to: .now),
            dedupeKey: "networth:stagnant:60d",
            deeplink: .netWorth
        )]
    }

    // MARK: - Helpers

    private static func currentMonthKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: .now)
    }
}
