import Foundation
import SwiftData
@preconcurrency import UserNotifications

/// Local notification scheduling for recurring transactions. Mirrors
/// `SubscriptionNotificationScheduler` — wipes and rebuilds the full
/// plan on every call rather than diffing in place. Cheap, and a clean
/// rebuild guarantees we don't accumulate stale alerts when a template
/// is paused, edited, or auto-paused by the drift service.
///
/// Identifier scheme: `rec-<kind>-<templateID>-<extra>` so we can
/// target removals without clearing unrelated notifications.
///
/// Call sites:
///   - `RecurringScheduler.tick` — after the pipeline has settled, so
///     materialized + drift-corrected templates schedule against the
///     latest amounts and dates.
///   - Settings panel toggle changes (via the change observer wired
///     into `RecurringSettingsView`).
enum RecurringNotificationScheduler {

    // MARK: - UserDefaults keys (mirror what RecurringSettingsView writes)

    static let masterEnabledKey      = "recurringNotificationsEnabled"
    static let chargeAlertThresholdKey = "recurringNotificationsThreshold"

    // MARK: - Constants

    private static let identifierPrefix = "rec-"
    private static let scheduleHorizonDays = 60
    private static let alertHour = 9                   // 9 AM local
    private static let defaultThreshold: Double = 100  // off-by-default for small bills

    // MARK: - Public API

    /// Authorization request — call only when the user actually toggles
    /// notifications on, never silently at app launch.
    static func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    /// Wipe & rebuild every recurring-prefixed notification. Cheap; safe
    /// to call after any pipeline pass. When the master toggle is off
    /// we still clear so previously-scheduled alerts don't keep firing.
    @MainActor
    static func rescheduleAll(context: ModelContext) {
        let defaults = UserDefaults.standard
        let masterEnabled = defaults.object(forKey: masterEnabledKey) as? Bool ?? false
        clearAll {
            guard masterEnabled else { return }
            let threshold = defaults.object(forKey: chargeAlertThresholdKey) as? Double ?? defaultThreshold
            let templates = fetchActiveTemplates(context: context)
            scheduleUpcoming(templates: templates, threshold: threshold)
        }
    }

    // MARK: - Clearing

    private static func clearAll(then continuation: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
            DispatchQueue.main.async { continuation() }
        }
    }

    // MARK: - Schedulers

    @MainActor
    private static func scheduleUpcoming(templates: [RecurringTransaction], threshold: Double) {
        let cal = Calendar.current
        guard let horizon = cal.date(byAdding: .day, value: scheduleHorizonDays, to: .now) else { return }
        let cap = scheduleHorizonDays * 2

        for template in templates where !template.isIncome {
            let amount = NSDecimalNumber(decimal: template.amount).doubleValue
            guard amount >= threshold else { continue }

            // Walk forward through projected occurrences and schedule
            // one alert per occurrence within the horizon.
            var cursor = template.nextOccurrence
            var safety = 0
            while cursor < .now && safety < cap {
                cursor = template.frequency.nextDate(after: cursor)
                safety += 1
            }
            var iter = 0
            while cursor <= horizon && iter < cap {
                let dayBefore = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
                let fireAt = morningOf(dayBefore)
                if fireAt > .now {
                    let stamp = String(Int(cursor.timeIntervalSince1970))
                    schedule(
                        id: "\(identifierPrefix)charge-\(template.id.uuidString)-\(stamp)",
                        title: template.name,
                        body: "\(fmt(template.amount)) is due tomorrow.",
                        category: "REC_CHARGE",
                        fireAt: fireAt
                    )
                }
                cursor = template.frequency.nextDate(after: cursor)
                iter += 1
            }
        }
    }

    // MARK: - Low-level

    private static func schedule(id: String, title: String, body: String, category: String, fireAt: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    @MainActor
    private static func fetchActiveTemplates(context: ModelContext) -> [RecurringTransaction] {
        let descriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func morningOf(_ date: Date) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.hour = alertHour
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? date
    }

    private static func fmt(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }
}
