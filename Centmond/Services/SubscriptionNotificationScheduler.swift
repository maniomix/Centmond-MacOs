import Foundation
import SwiftData
@preconcurrency import UserNotifications

/// Local notification scheduling for subscription events. Mirrors the
/// `AIInsightEngine` notification pattern (UNUserNotificationCenter +
/// calendar triggers), but rebuilds its full plan on every call instead of
/// trying to diff in-place. Reasoning: notifications are cheap to register,
/// and a clean rebuild guarantees we don't accumulate stale alerts when a
/// subscription is paused, cancelled, or has its date / amount edited.
///
/// Identifier scheme: `sub-<kind>-<id>-<extra>` so we can target removals
/// without nuking unrelated notifications (morning briefing, weekly review).
///
/// Call sites:
/// - `SubscriptionsView.onAppear` — refresh on hub open
/// - `SubscriptionReconciliationService.applyMatch` — re-run after a charge
///    advances `nextPaymentDate` or a price hike is recorded
/// - Settings panel toggle changes
enum SubscriptionNotificationScheduler {

    // MARK: - User defaults keys (mirror what InAppSettingsView reads)

    static let masterEnabledKey = "subscriptionNotificationsEnabled"
    static let trialAlertDaysKey = "subscriptionTrialAlertDays"
    static let chargeAlertEnabledKey = "subscriptionChargeAlertEnabled"
    static let chargeAlertThresholdKey = "subscriptionChargeAlertThreshold"
    static let priceHikeAlertEnabledKey = "subscriptionPriceHikeAlertEnabled"
    static let unusedAlertEnabledKey = "subscriptionUnusedAlertEnabled"

    // MARK: - Constants

    private static let identifierPrefix = "sub-"
    private static let scheduleHorizonDays = 60
    private static let unusedThresholdDays = 60
    private static let defaultTrialLeadDays = 2
    private static let defaultChargeThreshold: Double = 10
    private static let alertHour = 9   // 9 AM local

    // MARK: - Public API

    /// Authorization helper. Mirrors `AIInsightEngine` style — request only
    /// when the user actually enables a notification class, never silently
    /// at app launch.
    static func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    /// Wipe & rebuild every subscription-prefixed notification. Cheap; safe
    /// to call after any subscription mutation. Skips entirely when the
    /// master toggle is off — also clears anything previously scheduled so
    /// disabling the master kills outstanding alerts.
    @MainActor
    static func rescheduleAll(context: ModelContext) {
        let defaults = UserDefaults.standard
        let masterEnabled = defaults.object(forKey: masterEnabledKey) as? Bool ?? true
        clearAll {
            guard masterEnabled else { return }
            let chargeEnabled = defaults.object(forKey: chargeAlertEnabledKey) as? Bool ?? true
            let priceEnabled = defaults.object(forKey: priceHikeAlertEnabledKey) as? Bool ?? true
            let unusedEnabled = defaults.object(forKey: unusedAlertEnabledKey) as? Bool ?? true
            let trialLeadDays = defaults.object(forKey: trialAlertDaysKey) as? Int ?? defaultTrialLeadDays
            let threshold = defaults.object(forKey: chargeAlertThresholdKey) as? Double ?? defaultChargeThreshold

            // Snapshot model data on the MainActor side so the per-event
            // closures don't hold model references across the async hop.
            let subs = fetchActiveSubscriptions(context: context)

            scheduleTrialAlerts(subs: subs, leadDays: trialLeadDays)

            if chargeEnabled {
                scheduleChargeAlerts(subs: subs, threshold: threshold)
            }
            if priceEnabled {
                schedulePriceHikeAlerts(subs: subs)
            }
            if unusedEnabled {
                scheduleUnusedAlerts(subs: subs)
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

    // MARK: - Schedulers

    @MainActor
    private static func scheduleTrialAlerts(subs: [Subscription], leadDays: Int) {
        let cal = Calendar.current
        for sub in subs where sub.isTrial {
            guard let end = sub.trialEndsAt else { continue }
            guard let alertDate = cal.date(byAdding: .day, value: -max(leadDays, 0), to: end) else { continue }
            guard alertDate > .now else { continue } // skip past-due alerts

            let body: String = {
                if leadDays == 0 { return "Trial ends today — will start charging \(fmt(sub.amount))." }
                return "Trial ends in \(leadDays) day\(leadDays == 1 ? "" : "s") — will start charging \(fmt(sub.amount))."
            }()

            schedule(
                id: "\(identifierPrefix)trial-\(sub.id.uuidString)",
                title: sub.serviceName,
                body: body,
                category: "SUB_TRIAL",
                fireAt: morningOf(alertDate)
            )
        }
    }

    @MainActor
    private static func scheduleChargeAlerts(subs: [Subscription], threshold: Double) {
        let to = Calendar.current.date(byAdding: .day, value: scheduleHorizonDays, to: .now) ?? .now
        let upcoming = SubscriptionForecast.upcomingCharges(
            for: subs, from: .now, to: to, includeTrialEnds: false
        )
        let cal = Calendar.current
        for charge in upcoming {
            let amt = (charge.amount as NSDecimalNumber).doubleValue
            guard amt >= threshold else { continue }
            // Schedule the morning before the charge. If the charge is today
            // or tomorrow morning, fire immediately at the next alert hour.
            let dayBefore = cal.date(byAdding: .day, value: -1, to: charge.date) ?? charge.date
            let fireAt = morningOf(dayBefore)
            guard fireAt > .now else { continue }

            let stamp = String(Int(charge.date.timeIntervalSince1970))
            schedule(
                id: "\(identifierPrefix)charge-\(charge.subscriptionID.uuidString)-\(stamp)",
                title: charge.displayName,
                body: "\(fmt(charge.amount)) charges tomorrow",
                category: "SUB_CHARGE",
                fireAt: fireAt
            )
        }
    }

    @MainActor
    private static func schedulePriceHikeAlerts(subs: [Subscription]) {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -36, to: .now) ?? .now
        for sub in subs {
            for change in sub.priceHistory
                where !change.acknowledged && change.date >= cutoff {
                let pct = Int(abs(change.changePercent) * 100)
                let dir = change.changePercent >= 0 ? "raised" : "dropped"
                let body = "Price \(dir) by \(pct)% — now \(fmt(change.newAmount))."
                let fire = Date().addingTimeInterval(5) // near-immediate
                schedule(
                    id: "\(identifierPrefix)pricehike-\(change.id.uuidString)",
                    title: sub.serviceName,
                    body: body,
                    category: "SUB_PRICE_HIKE",
                    fireAt: fire
                )
            }
        }
    }

    @MainActor
    private static func scheduleUnusedAlerts(subs: [Subscription]) {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -unusedThresholdDays, to: .now) ?? .now
        for sub in subs where sub.status == .active {
            // "Unused" heuristic: charges have been landing (so it's billing
            // fine) but the subscription has been around for ≥ 60 days
            // without the user editing or otherwise touching it. We use
            // `updatedAt` as the touch indicator.
            guard sub.createdAt < cutoff, sub.updatedAt < cutoff else { continue }
            // Schedule a single one-shot reminder for tomorrow morning so the
            // user gets a nudge without being spammed every day.
            let fire = morningOf(cal.date(byAdding: .day, value: 1, to: .now) ?? .now)
            guard fire > .now else { continue }
            schedule(
                id: "\(identifierPrefix)unused-\(sub.id.uuidString)",
                title: sub.serviceName,
                body: "Still using this? No changes in \(unusedThresholdDays) days at \(fmt(sub.amount))/cycle.",
                category: "SUB_UNUSED",
                fireAt: fire
            )
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
    private static func fetchActiveSubscriptions(context: ModelContext) -> [Subscription] {
        let descriptor = FetchDescriptor<Subscription>()
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.status == .active || $0.status == .trial }
    }

    /// Snap a date to its 9 AM local — that's when subscription notifications
    /// should fire, not at the midnight rollover.
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
