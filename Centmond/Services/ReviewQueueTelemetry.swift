import Foundation
import Observation

// ============================================================
// MARK: - Review Queue Telemetry (P8)
// ============================================================
//
// Lightweight preferences + counters singleton. Holds per-reason
// mute flags (Settings toggles them, `ReviewQueueService` filters
// by them) and a rolling count of items the user has resolved
// this week. Backed by UserDefaults — no SwiftData model so the
// store stays migration-safe.
// ============================================================

@Observable
@MainActor
final class ReviewQueueTelemetry {
    static let shared = ReviewQueueTelemetry()

    private let defaults = UserDefaults.standard
    private let mutedKey = "reviewQueue.mutedReasons"
    private let weekCountKey = "reviewQueue.weekCount"
    private let weekStartKey = "reviewQueue.weekStart"

    /// Backing store is a comma-separated string of raw values so the key
    /// stays grep-able in a defaults dump.
    private(set) var mutedReasons: Set<ReviewReasonCode>

    /// Number of review-queue items the user has accepted or dismissed
    /// during the current ISO week. Rolls over automatically on first
    /// read in a new week.
    private(set) var resolvedThisWeek: Int

    private init() {
        let raw = UserDefaults.standard.string(forKey: "reviewQueue.mutedReasons") ?? ""
        self.mutedReasons = Set(
            raw.split(separator: ",")
                .compactMap { ReviewReasonCode(rawValue: String($0)) }
        )
        self.resolvedThisWeek = UserDefaults.standard.integer(forKey: "reviewQueue.weekCount")
        self.rolloverIfNeeded()
    }

    // MARK: - Mute

    func isMuted(_ reason: ReviewReasonCode) -> Bool {
        mutedReasons.contains(reason)
    }

    func setMuted(_ reason: ReviewReasonCode, muted: Bool) {
        if muted { mutedReasons.insert(reason) }
        else     { mutedReasons.remove(reason) }
        persistMuted()
    }

    private func persistMuted() {
        let raw = mutedReasons.map(\.rawValue).sorted().joined(separator: ",")
        defaults.set(raw, forKey: mutedKey)
    }

    // MARK: - Resolved counter

    /// Bump the "resolved this week" counter. Called by every code path
    /// that flips `isReviewed`, dismisses an item, or categorizes a row
    /// out of the queue.
    func recordResolved(count: Int = 1) {
        rolloverIfNeeded()
        resolvedThisWeek += count
        defaults.set(resolvedThisWeek, forKey: weekCountKey)
    }

    /// Rolls the counter when we cross into a new ISO week. Week start is
    /// persisted so the rollover is stable across app restarts.
    private func rolloverIfNeeded() {
        let current = currentWeekStart()
        let stored = defaults.object(forKey: weekStartKey) as? Date
        if stored == nil || stored! < current {
            resolvedThisWeek = 0
            defaults.set(0, forKey: weekCountKey)
            defaults.set(current, forKey: weekStartKey)
        }
    }

    private func currentWeekStart() -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        return cal.date(from: comps) ?? .now
    }
}
