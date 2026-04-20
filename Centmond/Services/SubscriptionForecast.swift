import Foundation

/// Projects upcoming charges for active subscriptions over a date range.
/// Pure compute — no SwiftData fetches. Callers pass already-filtered
/// subscriptions so this can be unit-tested and cached without a context.
///
/// Two primary outputs: a flat `[UpcomingCharge]` list for timeline UIs, and
/// a daily `[Date: Decimal]` histogram for the Prediction page so its chart
/// can split recurring baseline from discretionary spend.
enum SubscriptionForecast {

    struct UpcomingCharge: Identifiable, Hashable {
        let id: UUID
        let subscriptionID: UUID
        let displayName: String
        let iconSymbol: String?
        let colorHex: String?
        let amount: Decimal
        let date: Date
        let isTrialEnd: Bool

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    // MARK: - Timeline

    /// Flat list of projected charges for every active subscription within
    /// [from, to]. Multiple occurrences per subscription if the cycle is
    /// short enough to repeat inside the window. Sorted by date ascending.
    /// Includes trial-end markers as zero-amount entries — the UI decides
    /// whether to render them.
    static func upcomingCharges(
        for subscriptions: [Subscription],
        from: Date,
        to: Date,
        includeTrialEnds: Bool = true
    ) -> [UpcomingCharge] {
        guard from <= to else { return [] }
        var out: [UpcomingCharge] = []

        for sub in subscriptions where sub.status == .active || sub.status == .trial {
            // Project the charge date forward from `nextPaymentDate`, emitting
            // one row per occurrence that falls in the window. Guard against
            // a zero or negative cadence looping forever.
            let cadence = max(sub.effectiveCadenceDays, 1)
            var cursor = sub.nextPaymentDate
            var safety = 0
            let maxIterations = 500 // ~10 years of weekly ≈ safety ceiling

            // Step backward once in case nextPaymentDate is slightly in the
            // past (sub.isPastDue case) so we don't miss the overdue charge.
            if cursor < from {
                while cursor < from, safety < maxIterations {
                    guard let next = advance(cursor, cycle: sub.billingCycle, customDays: sub.customCadenceDays) else { break }
                    if next <= cursor { break } // cadence produced no forward progress
                    cursor = next
                    safety += 1
                }
            }

            while cursor <= to, safety < maxIterations {
                if cursor >= from {
                    out.append(UpcomingCharge(
                        id: UUID(),
                        subscriptionID: sub.id,
                        displayName: sub.serviceName,
                        iconSymbol: sub.iconSymbol,
                        colorHex: sub.colorHex,
                        amount: sub.amount,
                        date: cursor,
                        isTrialEnd: false
                    ))
                }
                guard let next = advance(cursor, cycle: sub.billingCycle, customDays: sub.customCadenceDays) else { break }
                if next <= cursor { break }
                cursor = next
                safety += 1
                if cadence >= 365 && out.count > 100 { break } // paranoia ceiling
            }

            if includeTrialEnds, sub.isTrial,
               let trialEnd = sub.trialEndsAt,
               trialEnd >= from, trialEnd <= to {
                out.append(UpcomingCharge(
                    id: UUID(),
                    subscriptionID: sub.id,
                    displayName: sub.serviceName,
                    iconSymbol: sub.iconSymbol,
                    colorHex: sub.colorHex,
                    amount: 0,
                    date: trialEnd,
                    isTrialEnd: true
                ))
            }
        }

        return out.sorted { $0.date < $1.date }
    }

    // MARK: - Rolling window totals

    static func total(for charges: [UpcomingCharge]) -> Decimal {
        charges.reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// Daily buckets of projected charges — used by the Prediction page so
    /// its chart can render recurring baseline as a distinct layer under
    /// discretionary spend. Key is calendar-day start; value is the summed
    /// amount scheduled for that day.
    static func dailyBaseline(
        for subscriptions: [Subscription],
        from: Date,
        to: Date
    ) -> [Date: Decimal] {
        let charges = upcomingCharges(for: subscriptions, from: from, to: to, includeTrialEnds: false)
        var buckets: [Date: Decimal] = [:]
        let cal = Calendar.current
        for c in charges {
            let day = cal.startOfDay(for: c.date)
            buckets[day, default: 0] += c.amount
        }
        return buckets
    }

    /// Total recurring outflow projected for the next N days from `anchor`.
    /// Handy for summary-bar stats ("Next 7 days: $42.98").
    static func projected(
        for subscriptions: [Subscription],
        next days: Int,
        from anchor: Date = .now
    ) -> Decimal {
        let to = Calendar.current.date(byAdding: .day, value: days, to: anchor) ?? anchor
        let charges = upcomingCharges(for: subscriptions, from: anchor, to: to, includeTrialEnds: false)
        return total(for: charges)
    }

    /// Groups upcoming charges by day for a simple timeline list.
    static func groupedByDay(_ charges: [UpcomingCharge]) -> [(day: Date, charges: [UpcomingCharge])] {
        let cal = Calendar.current
        var buckets: [Date: [UpcomingCharge]] = [:]
        for c in charges {
            let day = cal.startOfDay(for: c.date)
            buckets[day, default: []].append(c)
        }
        return buckets.keys.sorted().map { ($0, buckets[$0] ?? []) }
    }

    // MARK: - Date math (mirrors the reconciliation service so both stay in step)

    private static func advance(_ date: Date, cycle: BillingCycle, customDays: Int?) -> Date? {
        let cal = Calendar.current
        switch cycle {
        case .weekly:    return cal.date(byAdding: .weekOfYear, value: 1, to: date)
        case .biweekly:  return cal.date(byAdding: .weekOfYear, value: 2, to: date)
        case .monthly:   return cal.date(byAdding: .month,      value: 1, to: date)
        case .quarterly: return cal.date(byAdding: .month,      value: 3, to: date)
        case .semiannual:return cal.date(byAdding: .month,      value: 6, to: date)
        case .annual:    return cal.date(byAdding: .year,       value: 1, to: date)
        case .custom:    return cal.date(byAdding: .day,        value: max(customDays ?? 30, 1), to: date)
        }
    }
}
