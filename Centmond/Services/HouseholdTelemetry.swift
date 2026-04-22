import Foundation
import Observation
import SwiftData

// ============================================================
// MARK: - Household Telemetry (P10)
// ============================================================
//
// Observable counters + derived metrics for the Household hub.
// Surfaces three feature-adoption numbers so the user (and future
// detectors) can see whether the rebuild is actually in use:
//
//  • Attribution coverage — % of this-month's transactions with a
//    householdMember set. High number = attribution discipline is
//    working, low number = default-payer / learner needs tuning.
//  • Splits created this week — ExpenseShare rows per week.
//  • Settlements logged this week — HouseholdSettlement rows per week.
//
// UserDefaults-backed so the numbers survive relaunch without a
// SwiftData model. Not written from detector code — the hub and
// inspector bump the counters directly at the mutation site.
// ============================================================

@Observable
@MainActor
final class HouseholdTelemetry {
    static let shared = HouseholdTelemetry()

    private let defaults = UserDefaults.standard
    private let splitsKey = "household.splitsThisWeek"
    private let settlementsKey = "household.settlementsThisWeek"
    private let weekStartKey = "household.telemetryWeekStart"

    private(set) var splitsThisWeek: Int
    private(set) var settlementsThisWeek: Int

    private init() {
        self.splitsThisWeek = defaults.integer(forKey: splitsKey)
        self.settlementsThisWeek = defaults.integer(forKey: settlementsKey)
        rolloverIfNeeded()
    }

    // MARK: - Record events

    func recordSplitCreated() {
        rolloverIfNeeded()
        splitsThisWeek += 1
        defaults.set(splitsThisWeek, forKey: splitsKey)
    }

    func recordSettlementLogged() {
        rolloverIfNeeded()
        settlementsThisWeek += 1
        defaults.set(settlementsThisWeek, forKey: settlementsKey)
    }

    // MARK: - Derived

    /// Percentage of this-month's transactions that carry a household member.
    /// Returns `nil` when there are no qualifying transactions so callers can
    /// show "—" instead of a misleading 0%. Excludes transfers (attribution
    /// isn't meaningful for them).
    static func attributionCoveragePercent(in context: ModelContext) -> Double? {
        let cal = Calendar.current
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: .now)) else {
            return nil
        }
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.date >= start && $0.isTransfer == false }
        )
        let txns = (try? context.fetch(descriptor)) ?? []
        guard !txns.isEmpty else { return nil }
        let attributed = txns.filter { $0.householdMember != nil }.count
        return Double(attributed) / Double(txns.count)
    }

    // MARK: - Rollover

    /// ISO-week rollover. First record (or first read) in a new week resets
    /// the counters. Matches the pattern used by ReviewQueueTelemetry so the
    /// two feel consistent when surfaced in Settings.
    private func rolloverIfNeeded() {
        let cal = Calendar.current
        let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        let weekKey = "\(components.yearForWeekOfYear ?? 0)-\(components.weekOfYear ?? 0)"
        let stored = defaults.string(forKey: weekStartKey) ?? ""
        if stored != weekKey {
            splitsThisWeek = 0
            settlementsThisWeek = 0
            defaults.set(0, forKey: splitsKey)
            defaults.set(0, forKey: settlementsKey)
            defaults.set(weekKey, forKey: weekStartKey)
        }
    }
}
