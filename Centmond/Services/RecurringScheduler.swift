import Foundation
import SwiftData

/// Orchestrates the automatic recurring pipeline. Owns no state of its
/// own — it is a thin entry point that fires the three phases of
/// `RecurringService` in the correct order so callers can't accidentally
/// materialize before linking (which would create duplicate rows).
///
/// Triggered by `AppShell` on app launch, every `scenePhase = .active`
/// transition, and once per midnight rollover. There is no manual "Run
/// Due" button anywhere in the UI — if a template is active and overdue,
/// the next tick will fire it.
enum RecurringScheduler {

    /// Run the full detect → link → drift → materialize → auto-approve →
    /// stale cycle. Order matters:
    ///   - detect must run BEFORE link (it back-tags historical txns the
    ///     linker would otherwise see as orphans) and BEFORE materialize
    ///     (else duplicates appear for not-yet-existing templates).
    ///   - drift must run AFTER link (so freshly-linked manual entries
    ///     feed the price signal) and BEFORE materialize (so any new
    ///     synthetic row uses the corrected amount).
    ///   - autoPauseStale runs LAST so we don't accidentally pause a
    ///     template that the same tick is about to resurrect via link.
    /// Every phase short-circuits on an empty fetch, so a quiet tick is
    /// cheap.
    @MainActor
    @discardableResult
    static func tick(in context: ModelContext, asOf: Date = .now) -> TickResult {
        let detected     = RecurringDetector.autoConfirmHighConfidence(in: context)
        let linked       = RecurringService.linkPendingMatches(in: context, asOf: asOf)
        let drifted      = RecurringDriftService.correctDrift(in: context)
        let materialized = RecurringService.materializeDue(in: context, asOf: asOf)
        let approved     = RecurringService.autoApproveStaleMaterializations(in: context, asOf: asOf)
        let paused       = RecurringDriftService.autoPauseStale(in: context, asOf: asOf)
        // Reschedule notifications LAST so alerts reflect drift-corrected
        // amounts and the post-stale-pause active set. No-op when the
        // master toggle is off — and still clears prior alerts in that
        // case so disabling the toggle silences existing reminders.
        RecurringNotificationScheduler.rescheduleAll(context: context)
        // Piggyback the forecast-derived watch points off the same tick —
        // runway/overdraft/low-balance alerts depend on the same
        // post-pipeline state.
        ForecastNotificationScheduler.rescheduleAll(context: context)
        return TickResult(
            detected: detected,
            linked: linked,
            drifted: drifted,
            materialized: materialized,
            autoApproved: approved,
            autoPaused: paused
        )
    }

    struct TickResult {
        let detected: Int
        let linked: Int
        let drifted: Int
        let materialized: Int
        let autoApproved: Int
        let autoPaused: Int

        var changed: Bool {
            detected + linked + drifted + materialized + autoApproved + autoPaused > 0
        }
    }

    /// Seconds until the next 00:01 local time. Used by AppShell's daily
    /// re-tick loop so that a session left open overnight still fires
    /// the new day's occurrences.
    static func secondsUntilNextMidnight(from now: Date = .now) -> TimeInterval {
        var components = DateComponents()
        components.hour = 0
        components.minute = 1
        let next = Calendar.current.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(86400)
        return max(60, next.timeIntervalSince(now))
    }
}
