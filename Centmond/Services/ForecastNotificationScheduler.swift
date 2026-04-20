import Foundation
import SwiftData
@preconcurrency import UserNotifications

/// Local notification scheduling for forecast-derived watch points.
/// Mirrors `RecurringNotificationScheduler` — wipes and rebuilds the
/// full plan on every call so stale alerts don't accumulate when
/// balances, obligations, or goal contributions change.
///
/// Three alert classes, fired the morning before the relevant date:
///   1. **Overdraft** — expected balance line crosses zero inside the
///      horizon. Highest-priority; fired regardless of threshold.
///   2. **Tight window** — P10 confidence band dips below zero (but
///      the expected line stays positive). Plausible-overdraft warning.
///   3. **Low-balance watch point** — the lowest expected balance in
///      the horizon drops below `lowBalanceThresholdKey` (default $500).
///      Fires the morning before `lowestExpectedBalanceDate`.
///
/// Identifier scheme: `forecast-<kind>-<isoDate>` so we can target
/// removals without clearing unrelated notifications.
///
/// Call sites:
///   - App launch / scene active (see `CentmondApp`).
///   - After large user-driven data changes (bulk import, settings
///     toggle) — same pattern as the recurring/subscription schedulers.
enum ForecastNotificationScheduler {

    // MARK: - UserDefaults keys

    static let masterEnabledKey       = "forecastAlertsEnabled"
    static let lowBalanceThresholdKey = "forecastAlertsLowBalanceThreshold"

    // MARK: - Constants

    private static let identifierPrefix = "forecast-"
    private static let horizonDays = 60
    private static let alertHour = 9
    private static let defaultLowBalance: Double = 500

    // MARK: - Public API

    /// Request authorization. Only call when the user toggles alerts on
    /// — we don't silently prompt at app launch.
    static func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    @MainActor
    static func rescheduleAll(context: ModelContext) {
        let defaults = UserDefaults.standard
        let masterEnabled = defaults.object(forKey: masterEnabledKey) as? Bool ?? false
        clearAll {
            guard masterEnabled else { return }
            let threshold = defaults.object(forKey: lowBalanceThresholdKey) as? Double ?? defaultLowBalance
            Task { @MainActor in
                await scheduleFromHorizon(context: context, lowBalanceThreshold: threshold)
            }
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

    // MARK: - Scheduling

    @MainActor
    private static func scheduleFromHorizon(context: ModelContext, lowBalanceThreshold: Double) async {
        guard let subs = try? context.fetch(FetchDescriptor<Subscription>()),
              let recurring = try? context.fetch(FetchDescriptor<RecurringTransaction>()),
              let goals = try? context.fetch(FetchDescriptor<Goal>()),
              let accounts = try? context.fetch(FetchDescriptor<Account>())
        else { return }

        let history = fetchRecentHistory(context: context)
        let startingBalance = accounts
            .filter { !$0.isArchived && !$0.isClosed && $0.includeInNetWorth }
            .reduce(Decimal.zero) { $0 + $1.currentBalance }

        let horizon = ForecastEngine.build(
            ForecastEngine.Inputs(
                startingBalance: startingBalance,
                subscriptions: subs,
                recurring: recurring,
                goals: goals,
                history: history
            ),
            horizonDays: horizonDays
        )

        let summary = horizon.summary

        if let neg = summary.firstExpectedNegativeDate {
            schedule(
                id: idFor(kind: "overdraft", date: neg),
                title: "Balance will hit $0",
                body: "Projected to go negative on \(shortDate(neg)). Take a look at upcoming obligations.",
                category: "FORECAST_OVERDRAFT",
                fireAt: morningOf(neg, daysBefore: 1)
            )
        } else if let risk = summary.firstAtRiskDate {
            schedule(
                id: idFor(kind: "tight", date: risk),
                title: "Tight week ahead",
                body: "Budget gets snug around \(shortDate(risk)). Review your forecast.",
                category: "FORECAST_TIGHT",
                fireAt: morningOf(risk, daysBefore: 2)
            )
        }

        let low = NSDecimalNumber(decimal: summary.lowestExpectedBalance).doubleValue
        if low < lowBalanceThreshold && summary.lowestExpectedBalanceDate > Date() {
            schedule(
                id: idFor(kind: "lowbalance", date: summary.lowestExpectedBalanceDate),
                title: "Low-balance watch point",
                body: "Lowest projected balance \(format(summary.lowestExpectedBalance)) on \(shortDate(summary.lowestExpectedBalanceDate)).",
                category: "FORECAST_LOW_BALANCE",
                fireAt: morningOf(summary.lowestExpectedBalanceDate, daysBefore: 3)
            )
        }
    }

    // MARK: - Helpers

    private static func fetchRecentHistory(context: ModelContext) -> [Transaction] {
        let start = Calendar.current.date(byAdding: .day, value: -60, to: .now) ?? .now
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.date >= start }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func schedule(id: String, title: String, body: String, category: String, fireAt: Date) {
        guard fireAt > .now else { return }
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

    private static func idFor(kind: String, date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return "\(identifierPrefix)\(kind)-\(f.string(from: date))"
    }

    private static func morningOf(_ date: Date, daysBefore: Int) -> Date {
        let cal = Calendar.current
        let target = cal.date(byAdding: .day, value: -daysBefore, to: date) ?? date
        var comps = cal.dateComponents([.year, .month, .day], from: target)
        comps.hour = alertHour
        comps.minute = 0
        return cal.date(from: comps) ?? target
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private static func format(_ amount: Decimal) -> String {
        let d = NSDecimalNumber(decimal: amount).doubleValue
        if abs(d) >= 1000 {
            return String(format: "$%.1fk", d / 1000)
        }
        return String(format: "$%.0f", d)
    }
}
