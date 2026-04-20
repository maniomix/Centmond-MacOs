import Foundation
import SwiftData

// ============================================================
// MARK: - Insight Detectors (P2)
// ============================================================
//
// Pure heuristic detectors. Each `detect*` function reads from
// SwiftData and returns `[AIInsight]`. Detectors never mutate
// state and never make LLM calls — they're re-run on every
// engine refresh and deduped by `dedupeKey` downstream.
//
// Dedupe-key prefixes (one per detector, per the "DismissedDetection
// Key Prefix" convention):
//   cashflow:runway:*        subscription:unused:*
//   cashflow:incomeDrop:*    subscription:hike:*
//   subscription:duplicate:* recurring:overdue:*
//   anomaly:daySpike:*       anomaly:newMerchant:*
//   duplicate:txn:*
// ============================================================

@MainActor
enum InsightDetectors {

    // MARK: - Cashflow: Runway

    /// Warns when total spend-capable balance divided by average daily spend
    /// falls below 14 days. Uses the last 30 days of spending to estimate
    /// burn rate so one-off large purchases don't distort the signal.
    static func cashflowRunway(context: ModelContext) -> [AIInsight] {
        let accountDescriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isArchived }
        )
        guard let accounts = try? context.fetch(accountDescriptor) else { return [] }

        // Only cash-like accounts count toward runway — credit cards and
        // investments aren't spendable in the "can I pay rent" sense.
        let spendable = accounts.filter {
            $0.type == .checking || $0.type == .savings || $0.type == .cash
        }
        let totalBalance = spendable.reduce(Decimal.zero) { $0 + $1.currentBalance }
        guard totalBalance > 0 else { return [] }

        let dailyBurn = averageDailySpend(context: context, lookbackDays: 30)
        guard dailyBurn > 0 else { return [] }

        let runwayDays = Int(truncating: (totalBalance / dailyBurn) as NSDecimalNumber)

        if runwayDays < 14 {
            return [AIInsight(
                kind: .cashflowRisk,
                title: "Low runway — \(runwayDays) days",
                warning: "At your recent pace (\(fmt(dailyBurn))/day) your spendable balance covers only \(runwayDays) days.",
                severity: .critical,
                advice: "Pause non-essential spending and move funds from savings, or pull a big charge forward.",
                cause: "Based on \(fmt(totalBalance)) spendable balance and 30-day average burn.",
                expiresAt: Calendar.current.date(byAdding: .day, value: 2, to: .now),
                dedupeKey: "cashflow:runway:lt14",
                deeplink: .cashflow
            )]
        }
        if runwayDays < 30 {
            return [AIInsight(
                kind: .cashflowRisk,
                title: "Runway tight — \(runwayDays) days",
                warning: "At your recent pace your spendable balance covers about \(runwayDays) days.",
                severity: .warning,
                advice: "Review upcoming bills and subscriptions this week — small cuts compound fast.",
                cause: "Based on \(fmt(totalBalance)) spendable balance and 30-day average burn.",
                expiresAt: Calendar.current.date(byAdding: .day, value: 3, to: .now),
                dedupeKey: "cashflow:runway:lt30",
                deeplink: .cashflow
            )]
        }
        return []
    }

    // MARK: - Cashflow: Income drop

    /// Compares current month's income against the trailing 3-month average.
    /// Fires in the second half of the month so we don't false-flag when
    /// paychecks simply haven't landed yet.
    static func incomeDrop(context: ModelContext) -> [AIInsight] {
        let cal = Calendar.current
        let now = Date()
        guard cal.component(.day, from: now) >= 15 else { return [] }

        let thisMonth = monthIncome(context: context, monthsBack: 0)
        let m1 = monthIncome(context: context, monthsBack: 1)
        let m2 = monthIncome(context: context, monthsBack: 2)
        let m3 = monthIncome(context: context, monthsBack: 3)
        let prior = [m1, m2, m3].filter { $0 > 0 }
        guard prior.count >= 2 else { return [] }

        let priorAvg = prior.reduce(Decimal.zero, +) / Decimal(prior.count)
        guard priorAvg > 0 else { return [] }

        let ratio = NSDecimalNumber(decimal: thisMonth / priorAvg).doubleValue
        guard ratio < 0.7 else { return [] }

        let gap = priorAvg - thisMonth
        let pct = Int((1 - ratio) * 100)
        return [AIInsight(
            kind: .cashflowRisk,
            title: "Income down \(pct)% this month",
            warning: "You've logged \(fmt(thisMonth)) in income vs a 3-month average of \(fmt(priorAvg)).",
            severity: .warning,
            advice: "Tighten discretionary categories until paycheck pace recovers — or flag the missing income.",
            cause: "Shortfall vs trailing 3-month average: \(fmt(gap)).",
            dedupeKey: "cashflow:incomeDrop:\(yearMonth(now))",
            deeplink: .cashflow
        )]
    }

    // MARK: - Subscriptions: Unused

    /// Active subscription whose `merchantKey` hasn't appeared on a transaction
    /// in 60+ days. The user is still being billed for something that's left
    /// no footprint in the ledger recently.
    static func subscriptionUnused(context: ModelContext) -> [AIInsight] {
        let activeStatus = SubscriptionStatus.active
        let subDescriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        guard let subs = try? context.fetch(subDescriptor), !subs.isEmpty else { return [] }

        guard let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: .now) else { return [] }
        let txnDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= cutoff }
        )
        guard let recent = try? context.fetch(txnDescriptor) else { return [] }

        // Bucket recent transactions by derived merchant key once, up front.
        var seenKeys: Set<String> = []
        for t in recent {
            seenKeys.insert(Subscription.merchantKey(for: t.payee))
        }

        var results: [AIInsight] = []
        for sub in subs {
            guard !sub.merchantKey.isEmpty else { continue }
            if seenKeys.contains(sub.merchantKey) { continue }

            results.append(AIInsight(
                kind: .subscriptionUnused,
                title: "\(sub.serviceName) looks unused",
                warning: "No \(sub.serviceName) charge has touched your accounts in 60+ days — you're paying \(fmt(sub.monthlyCost))/mo for it.",
                severity: .warning,
                advice: "Cancel or pause it — you can always resubscribe if you miss it.",
                cause: "Last matching charge older than \(fmtDate(cutoff)).",
                dedupeKey: "subscription:unused:\(sub.id.uuidString)",
                suggestedAction: AIAction(
                    type: .cancelSubscription,
                    params: AIAction.ActionParams(subscriptionName: sub.serviceName)
                ),
                deeplink: .subscriptions(sub.id)
            ))
        }
        return results
    }

    // MARK: - Subscriptions: Price hike

    /// Unacknowledged `SubscriptionPriceChange` with ≥5% increase in the last
    /// 60 days. One insight per hike — the user can dismiss, which flips
    /// `acknowledged` via the subscription detail sheet separately.
    static func subscriptionPriceHike(context: ModelContext) -> [AIInsight] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: .now) else { return [] }
        let descriptor = FetchDescriptor<SubscriptionPriceChange>(
            predicate: #Predicate { !$0.acknowledged && $0.date >= cutoff }
        )
        guard let changes = try? context.fetch(descriptor) else { return [] }

        var results: [AIInsight] = []
        for change in changes where change.changePercent >= 0.05 {
            guard let sub = change.subscription else { continue }
            let pct = Int(change.changePercent * 100)
            let delta = change.newAmount - change.oldAmount

            results.append(AIInsight(
                kind: .subscriptionRenewal,
                title: "\(sub.serviceName) price hike +\(pct)%",
                warning: "Charge rose from \(fmt(change.oldAmount)) to \(fmt(change.newAmount)) on \(fmtDate(change.date)).",
                severity: .warning,
                advice: "Check if a cheaper tier covers your usage, or cancel if the new price isn't worth it.",
                cause: "Increase of \(fmt(delta))/cycle — \(fmt(delta * 12)) over a year at monthly cadence.",
                dedupeKey: "subscription:hike:\(change.id.uuidString)",
                deeplink: .subscriptions(sub.id)
            ))
        }
        return results
    }

    // MARK: - Subscriptions: Duplicates

    /// Two or more active subscriptions with the same `merchantKey` — usually
    /// a detection artifact or a re-subscribe the user forgot to cancel.
    static func duplicateSubscriptions(context: ModelContext) -> [AIInsight] {
        let activeStatus = SubscriptionStatus.active
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        guard let subs = try? context.fetch(descriptor) else { return [] }

        var byKey: [String: [Subscription]] = [:]
        for sub in subs where !sub.merchantKey.isEmpty {
            byKey[sub.merchantKey, default: []].append(sub)
        }

        var results: [AIInsight] = []
        for (key, group) in byKey where group.count >= 2 {
            let names = group.map(\.serviceName).joined(separator: ", ")
            let total = group.reduce(Decimal.zero) { $0 + $1.monthlyCost }
            results.append(AIInsight(
                kind: .duplicateTransaction,
                title: "Duplicate subscription: \(group.first?.serviceName ?? key)",
                warning: "You have \(group.count) active entries for the same service (\(names)) costing \(fmt(total))/mo combined.",
                severity: .warning,
                advice: "Cancel the duplicates and keep the cheapest entry, or merge them if one is stale.",
                dedupeKey: "subscription:duplicate:\(key)",
                deeplink: .subscriptions(group.first?.id)
            ))
        }
        return results
    }

    // MARK: - Recurring: Overdue

    /// `RecurringTransaction` whose `nextOccurrence` is 3+ days past due and
    /// still marked active. Complements the existing scheduler — if a run
    /// didn't materialize, surface it instead of silently drifting.
    static func recurringOverdue(context: ModelContext) -> [AIInsight] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -3, to: .now) else { return [] }
        let descriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive && $0.nextOccurrence < cutoff }
        )
        guard let overdue = try? context.fetch(descriptor) else { return [] }

        var results: [AIInsight] = []
        for rec in overdue {
            let daysLate = Calendar.current.dateComponents([.day], from: rec.nextOccurrence, to: .now).day ?? 0
            results.append(AIInsight(
                kind: .recurringDetected,
                title: "\(rec.name) overdue by \(daysLate)d",
                warning: "Expected \(fmt(rec.amount)) on \(fmtDate(rec.nextOccurrence)) — no matching transaction has landed.",
                severity: .warning,
                advice: "Log the payment manually, or reschedule the template if the cadence changed.",
                dedupeKey: "recurring:overdue:\(rec.id.uuidString)",
                deeplink: .recurring(rec.id)
            ))
        }
        return results
    }

    // MARK: - Anomaly: Day spike

    /// Today's spending is ≥3× the trailing 30-day daily average. Only fires
    /// once per calendar day. Ignores days below $25 so noise doesn't trigger.
    static func daySpike(context: ModelContext) -> [AIInsight] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: .now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!

        let todayDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= dayStart && $0.date < dayEnd }
        )
        guard let todayTxns = try? context.fetch(todayDescriptor) else { return [] }
        let todaySpend = todayTxns
            .filter { BalanceService.isSpendingExpense($0) }
            .reduce(Decimal.zero) { $0 + $1.amount }
        guard todaySpend >= 25 else { return [] }

        let avg = averageDailySpend(context: context, lookbackDays: 30)
        guard avg > 0 else { return [] }
        let ratio = NSDecimalNumber(decimal: todaySpend / avg).doubleValue
        guard ratio >= 3 else { return [] }

        let multiplier = Int(ratio)
        let topPayee = todayTxns
            .max(by: { $0.amount < $1.amount })?.payee ?? "one large charge"

        return [AIInsight(
            kind: .spendingAnomaly,
            title: "Today's spend is \(multiplier)× normal",
            warning: "You've spent \(fmt(todaySpend)) today vs a \(fmt(avg))/day average.",
            severity: .warning,
            advice: "If it was planned (rent, annual fee), ignore. Otherwise slow down for the next few days.",
            cause: "Largest charge so far: \(topPayee).",
            expiresAt: dayEnd,
            dedupeKey: "anomaly:daySpike:\(yearMonthDay(dayStart))",
            deeplink: .transactions(nil)
        )]
    }

    // MARK: - Anomaly: New large merchant

    /// A payee that's never appeared before just landed a transaction over
    /// $100. Catches one-off large purchases the user may have forgotten
    /// about, and new merchants that could be fraud or a forgotten signup.
    static func newLargeMerchant(context: ModelContext) -> [AIInsight] {
        guard let windowStart = Calendar.current.date(byAdding: .day, value: -3, to: .now) else { return [] }
        let recentDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= windowStart && $0.amount >= 100 }
        )
        guard let recent = try? context.fetch(recentDescriptor), !recent.isEmpty else { return [] }

        // Pull the full history once and build a set of seen payees to
        // classify "new" cheaply. Using an Intersection query per-payee
        // would be O(n) fetches.
        let allDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date < windowStart }
        )
        guard let history = try? context.fetch(allDescriptor) else { return [] }
        let seenPayees = Set(history.map { $0.payee.lowercased() })

        var results: [AIInsight] = []
        for txn in recent where BalanceService.isSpendingExpense(txn) {
            let key = txn.payee.lowercased()
            guard !seenPayees.contains(key), !key.isEmpty else { continue }

            results.append(AIInsight(
                kind: .spendingAnomaly,
                title: "New merchant: \(txn.payee)",
                warning: "\(fmt(txn.amount)) charged to \(txn.payee) — no prior transactions with this payee.",
                severity: .warning,
                advice: "Confirm it's you. If it's a new subscription, add it so renewal tracking kicks in.",
                dedupeKey: "anomaly:newMerchant:\(txn.id.uuidString)",
                deeplink: .transactions(txn.id)
            ))
        }
        return results
    }

    // MARK: - Duplicates: Transactions

    /// Same payee + same amount + same calendar day, filed twice. Common
    /// when a user logs a charge manually and a bank import lands the same
    /// row later. Groups by payee+amount+day and emits one insight per group.
    static func duplicateTransactions(context: ModelContext) -> [AIInsight] {
        guard let windowStart = Calendar.current.date(byAdding: .day, value: -14, to: .now) else { return [] }
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= windowStart && !$0.isTransfer }
        )
        guard let txns = try? context.fetch(descriptor) else { return [] }

        let cal = Calendar.current
        struct Key: Hashable { let payee: String; let amount: Decimal; let day: DateComponents }
        var groups: [Key: [Transaction]] = [:]
        for t in txns {
            let day = cal.dateComponents([.year, .month, .day], from: t.date)
            let key = Key(payee: t.payee.lowercased(), amount: t.amount, day: day)
            groups[key, default: []].append(t)
        }

        var results: [AIInsight] = []
        for (key, group) in groups where group.count >= 2 {
            // Stable dedupeKey using the oldest txn id keeps the insight
            // pinned to the same card across refreshes even if one member
            // gets deleted.
            guard let pinned = group.min(by: { $0.createdAt < $1.createdAt }) else { continue }
            results.append(AIInsight(
                kind: .duplicateTransaction,
                title: "Duplicate: \(pinned.payee)",
                warning: "\(group.count) identical \(fmt(key.amount)) charges to \(pinned.payee) on the same day.",
                severity: .warning,
                advice: "Delete the extra entry if it's a manual + import collision.",
                dedupeKey: "duplicate:txn:\(pinned.id.uuidString)",
                deeplink: .transactions(pinned.id)
            ))
        }
        return results
    }

    // MARK: - Helpers

    private static func averageDailySpend(context: ModelContext, lookbackDays: Int) -> Decimal {
        guard let start = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: .now) else { return 0 }
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= start }
        )
        guard let txns = try? context.fetch(descriptor), !txns.isEmpty else { return 0 }
        let total = txns
            .filter { BalanceService.isSpendingExpense($0) }
            .reduce(Decimal.zero) { $0 + $1.amount }
        return total / Decimal(max(lookbackDays, 1))
    }

    private static func monthIncome(context: ModelContext, monthsBack: Int) -> Decimal {
        let cal = Calendar.current
        guard let base = cal.date(byAdding: .month, value: -monthsBack, to: .now),
              let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: base)),
              let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else { return 0 }
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
        )
        guard let txns = try? context.fetch(descriptor) else { return 0 }
        return txns.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private static func yearMonth(_ date: Date) -> String {
        let cal = Calendar.current
        return "\(cal.component(.year, from: date))-\(cal.component(.month, from: date))"
    }

    private static func yearMonthDay(_ date: Date) -> String {
        let cal = Calendar.current
        return "\(cal.component(.year, from: date))-\(cal.component(.month, from: date))-\(cal.component(.day, from: date))"
    }

    private static func fmt(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }

    private static func fmtDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}
