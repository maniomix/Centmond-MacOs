import Foundation

// ============================================================
// MARK: - Net Worth Milestone Detector (P7)
// ============================================================
//
// Pure value-type derivation over `NetWorthSnapshot` history.
// Milestones are computed on the fly (not persisted) so they
// stay consistent if the user rebuilds history.
//
// Types:
//   .thresholdCrossed   — first crossing of a canonical dollar
//                         mark: $1k / $5k / $10k / $25k / $50k
//                         / $100k / $250k / $500k / $1M.
//   .allTimeHigh        — today's value equals the max-ever and
//                         was last set inside the recency window.
//   .crossedZero        — net worth flipped from negative to
//                         non-negative at some point.
//   .doubled            — most recent value is ≥ 2× the earliest
//                         recorded positive value.
// ============================================================

struct NetWorthMilestone: Identifiable, Hashable {
    enum Kind: Hashable {
        case thresholdCrossed(Decimal)
        case allTimeHigh
        case crossedZero
        case doubled(since: Date)
    }

    let id: String
    let kind: Kind
    let date: Date
    let value: Decimal
    let title: String
    let detail: String
    let icon: String
}

enum NetWorthMilestoneDetector {

    /// Canonical "round number" thresholds, smallest to largest.
    /// Negative mirror set handles the crawl back toward zero when
    /// the user is in the hole.
    private static let thresholds: [Decimal] = [
        1_000, 5_000, 10_000, 25_000, 50_000,
        100_000, 250_000, 500_000, 1_000_000,
    ]

    static func detect(from snapshots: [NetWorthSnapshot]) -> [NetWorthMilestone] {
        let sorted = snapshots.sorted { $0.date < $1.date }
        guard let latest = sorted.last else { return [] }

        var out: [NetWorthMilestone] = []

        out.append(contentsOf: detectThresholds(sorted: sorted))

        if let ath = detectAllTimeHigh(sorted: sorted, latest: latest) {
            out.append(ath)
        }
        if let zero = detectZeroCross(sorted: sorted) {
            out.append(zero)
        }
        if let doubled = detectDoubled(sorted: sorted, latest: latest) {
            out.append(doubled)
        }

        // Newest first.
        return out.sorted { $0.date > $1.date }
    }

    // MARK: - Threshold crossings

    private static func detectThresholds(sorted: [NetWorthSnapshot]) -> [NetWorthMilestone] {
        guard sorted.count >= 2 else { return [] }
        var out: [NetWorthMilestone] = []
        for threshold in thresholds {
            // First snapshot whose netWorth >= threshold AND whose prev was below.
            for i in 1..<sorted.count {
                let prev = sorted[i - 1].netWorth
                let cur = sorted[i].netWorth
                if prev < threshold && cur >= threshold {
                    out.append(NetWorthMilestone(
                        id: "threshold:\(threshold)",
                        kind: .thresholdCrossed(threshold),
                        date: sorted[i].date,
                        value: cur,
                        title: "Crossed \(CurrencyFormat.compact(threshold))",
                        detail: "First time on \(sorted[i].date.formatted(.dateTime.month(.abbreviated).day().year()))",
                        icon: "flag.checkered"
                    ))
                    break
                }
            }
        }
        return out
    }

    // MARK: - All-time high

    private static func detectAllTimeHigh(sorted: [NetWorthSnapshot], latest: NetWorthSnapshot) -> NetWorthMilestone? {
        guard sorted.count >= 7 else { return nil }  // not meaningful on day 1
        let max = sorted.map(\.netWorth).max() ?? 0
        guard latest.netWorth >= max, latest.netWorth > 0 else { return nil }

        // Only celebrate if the latest is a *new* high set within last 14 days.
        let recent = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .distantPast
        guard latest.date >= recent else { return nil }

        return NetWorthMilestone(
            id: "ath",
            kind: .allTimeHigh,
            date: latest.date,
            value: latest.netWorth,
            title: "All-time high",
            detail: "New peak at \(CurrencyFormat.standard(latest.netWorth))",
            icon: "mountain.2.fill"
        )
    }

    // MARK: - Zero crossing (underwater → above)

    private static func detectZeroCross(sorted: [NetWorthSnapshot]) -> NetWorthMilestone? {
        guard sorted.count >= 2 else { return nil }
        // Latest crossing: most recent day where prev < 0 and cur >= 0.
        for i in stride(from: sorted.count - 1, to: 0, by: -1) {
            let prev = sorted[i - 1].netWorth
            let cur = sorted[i].netWorth
            if prev < 0 && cur >= 0 {
                return NetWorthMilestone(
                    id: "zero-cross",
                    kind: .crossedZero,
                    date: sorted[i].date,
                    value: cur,
                    title: "Out of the red",
                    detail: "Net worth turned positive on \(sorted[i].date.formatted(.dateTime.month(.abbreviated).day()))",
                    icon: "arrow.up.forward.circle.fill"
                )
            }
        }
        return nil
    }

    // MARK: - Doubled since start

    private static func detectDoubled(sorted: [NetWorthSnapshot], latest: NetWorthSnapshot) -> NetWorthMilestone? {
        // Find earliest positive snapshot — doubling from a negative base is nonsense.
        guard let earliest = sorted.first(where: { $0.netWorth > 0 }) else { return nil }
        guard earliest.netWorth > 0,
              latest.netWorth >= earliest.netWorth * 2,
              earliest.date != latest.date else { return nil }

        return NetWorthMilestone(
            id: "doubled:\(earliest.date.timeIntervalSince1970)",
            kind: .doubled(since: earliest.date),
            date: latest.date,
            value: latest.netWorth,
            title: "Doubled",
            detail: "From \(CurrencyFormat.compact(earliest.netWorth)) on \(earliest.date.formatted(.dateTime.month(.abbreviated).year()))",
            icon: "multiply.circle.fill"
        )
    }
}
