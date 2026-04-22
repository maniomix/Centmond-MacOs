import Foundation
import SwiftData

// ============================================================
// MARK: - Household Insight Detectors (P7)
// ============================================================
//
// Four detectors surfaced in the Insights hub + AI chat context.
// All dedupe keys are namespaced under "household:" per the
// DismissedDetection Key Prefix rule so they share a dismissal
// silo and never cross-silence other detector families.
// ============================================================

@MainActor
enum HouseholdInsightDetectors {

    // MARK: - Tunables

    /// Minimum unsettled amount owed to any one member before we raise the
    /// imbalance insight. Below this, it's not worth bugging the user.
    private static let imbalanceThreshold: Decimal = 100

    /// A share counts as "aging" once it has sat `.owed` past this many days.
    /// User-configurable via Settings → Household (P9). Clamp at the call
    /// site — trusting the UI to stay in range is fragile per
    /// feedback_settings_clamp_at_callsite.
    private static let defaultUnpaidAgeDays = 30
    private static var unpaidAgeDays: Int {
        let raw = UserDefaults.standard.object(forKey: "householdUnsettledReminderDays") as? Int
        ?? defaultUnpaidAgeDays
        return max(7, min(raw, 90))
    }

    /// Household insight surfacing toggle (P9).
    private static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "householdNotificationsEnabled") as? Bool ?? true
    }

    /// Spender spike: a single member's share of monthly spending must be at
    /// least this fraction of household total AND at least 2x their usual
    /// share over the last 3 months.
    private static let spikeShareFloor = 0.5

    // MARK: - Public entry

    static func all(context: ModelContext) -> [AIInsight] {
        guard notificationsEnabled else { return [] }
        let memberDescriptor = FetchDescriptor<HouseholdMember>()
        let members = ((try? context.fetch(memberDescriptor)) ?? []).filter(\.isActive)
        guard !members.isEmpty else { return [] }

        var out: [AIInsight] = []
        out.append(contentsOf: imbalance(members: members, context: context))
        out.append(contentsOf: unpaidShares(context: context))
        out.append(contentsOf: unattributedRecurring(members: members, context: context))
        if members.count >= 2 {
            out.append(contentsOf: spenderSpike(members: members, context: context))
        }
        return out
    }

    // MARK: - Imbalance > threshold

    private static func imbalance(members: [HouseholdMember], context: ModelContext) -> [AIInsight] {
        let balances = HouseholdService.balances(in: context)
        guard let top = balances.max(by: { $0.amount < $1.amount }),
              top.amount >= imbalanceThreshold else { return [] }

        let debtor = balances.min(by: { $0.amount < $1.amount })
        let debtorName = (debtor?.amount ?? 0) < 0 ? debtor?.member.name : nil

        let bucket: String
        let severity: AIInsight.Severity
        if top.amount >= 500 {
            bucket = "gt500"; severity = .warning
        } else if top.amount >= 250 {
            bucket = "gt250"; severity = .watch
        } else {
            bucket = "gt100"; severity = .watch
        }

        let owedStr = CurrencyFormat.standard(top.amount)
        let title = "\(top.member.name) is owed \(owedStr)"
        let warning: String
        if let d = debtorName {
            warning = "\(d) owes \(top.member.name) \(owedStr) across pending splits. Record a settlement so both ledgers balance."
        } else {
            warning = "Open split shares total \(owedStr) owed to \(top.member.name). Record a settlement to zero the ledger."
        }

        return [AIInsight(
            kind: .householdImbalance,
            title: title,
            warning: warning,
            severity: severity,
            advice: "Open Settle Up and log the payment — it'll also mark the open shares as settled.",
            cause: "Computed from open ExpenseShare rows minus HouseholdSettlement entries.",
            expiresAt: Calendar.current.date(byAdding: .day, value: 7, to: .now),
            dedupeKey: "household:imbalance:\(bucket)",
            deeplink: .householdSettleUp
        )]
    }

    // MARK: - Unpaid share aging

    private static func unpaidShares(context: ModelContext) -> [AIInsight] {
        let descriptor = FetchDescriptor<ExpenseShare>()
        let shares = (try? context.fetch(descriptor)) ?? []
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -unpaidAgeDays, to: .now)
        else { return [] }

        let aging = shares.filter { s in
            s.status == .owed && s.createdAt <= cutoff && s.member != nil
        }
        guard !aging.isEmpty else { return [] }

        let total = aging.reduce(Decimal.zero) { $0 + $1.amount }
        guard total >= 25 else { return [] }

        return [AIInsight(
            kind: .householdUnpaidShare,
            title: "\(aging.count) share\(aging.count == 1 ? "" : "s") pending > \(unpaidAgeDays) days",
            warning: "\(CurrencyFormat.standard(total)) in split shares has been sitting unsettled for over \(unpaidAgeDays) days.",
            severity: .watch,
            advice: "Open Settle Up and clear the oldest balances — or mark them waived if the household never planned to collect.",
            cause: "ExpenseShare rows with status == .owed and createdAt older than \(unpaidAgeDays) days.",
            expiresAt: Calendar.current.date(byAdding: .day, value: 7, to: .now),
            dedupeKey: "household:unpaid:\(aging.count)",
            deeplink: .householdSettleUp
        )]
    }

    // MARK: - Unattributed recurring (household has members but template has no payer)

    private static func unattributedRecurring(members: [HouseholdMember],
                                              context: ModelContext) -> [AIInsight] {
        guard members.count >= 2 else { return [] }
        let descriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive }
        )
        let templates = (try? context.fetch(descriptor)) ?? []
        let unattributed = templates.filter { $0.householdMember == nil }
        guard unattributed.count >= 2 else { return [] }

        let names = unattributed.prefix(3).map(\.name).joined(separator: ", ")
        let more = unattributed.count > 3 ? " and \(unattributed.count - 3) more" : ""

        return [AIInsight(
            kind: .householdUnattributedRecurring,
            title: "\(unattributed.count) recurring bills have no payer",
            warning: "These templates aren't attributed to anyone: \(names)\(more).",
            severity: .watch,
            advice: "Open each and set the payer — future auto-materialized transactions will inherit it and your per-member totals stop drifting.",
            cause: "Active RecurringTransaction templates with householdMember == nil in a multi-member household.",
            expiresAt: Calendar.current.date(byAdding: .day, value: 14, to: .now),
            dedupeKey: "household:unattributedRecurring:\(unattributed.count)",
            deeplink: .recurring(nil)
        )]
    }

    // MARK: - Spender spike

    private static func spenderSpike(members: [HouseholdMember],
                                     context: ModelContext) -> [AIInsight] {
        let cal = Calendar.current
        let now = Date()
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)),
              let threeMonthStart = cal.date(byAdding: .month, value: -3, to: monthStart) else { return [] }

        let allDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.date >= threeMonthStart }
        )
        let all = (try? context.fetch(allDescriptor)) ?? []
        let thisMonth = all.filter { $0.date >= monthStart && BalanceService.isSpendingExpense($0) }
        let priorWindow = all.filter {
            $0.date >= threeMonthStart && $0.date < monthStart && BalanceService.isSpendingExpense($0)
        }

        let monthTotal = thisMonth.reduce(Decimal.zero) { $0 + $1.amount }
        guard monthTotal > 0 else { return [] }

        // Find each member's share of this month + prior 3-month window.
        var monthShares: [UUID: Decimal] = [:]
        for tx in thisMonth {
            guard let mid = tx.householdMember?.id else { continue }
            monthShares[mid, default: 0] += tx.amount
        }
        var priorTotals: [UUID: Decimal] = [:]
        for tx in priorWindow {
            guard let mid = tx.householdMember?.id else { continue }
            priorTotals[mid, default: 0] += tx.amount
        }

        // Biggest share this month.
        guard let (topID, topAmt) = monthShares.max(by: { $0.value < $1.value }),
              let topMember = members.first(where: { $0.id == topID }) else { return [] }

        let shareOfTotal = Double(truncating: (topAmt / monthTotal) as NSDecimalNumber)
        guard shareOfTotal >= spikeShareFloor else { return [] }

        // Compare to their typical monthly spend over prior 3 months.
        let priorMonthly = (priorTotals[topID] ?? 0) / 3
        guard priorMonthly > 0 else { return [] }
        let ratio = Double(truncating: (topAmt / priorMonthly) as NSDecimalNumber)
        guard ratio >= 2.0 else { return [] }

        return [AIInsight(
            kind: .householdSpenderSpike,
            title: "\(topMember.name) is \(Int(shareOfTotal * 100))% of household spend",
            warning: "\(topMember.name) has spent \(CurrencyFormat.standard(topAmt)) this month — \(String(format: "%.1fx", ratio)) their 3-month average of \(CurrencyFormat.standard(priorMonthly)).",
            severity: .watch,
            advice: "Scan their recent transactions for a one-off large purchase or a new subscription before assuming a real shift in spending.",
            cause: "Comparing member's attributed spend this month vs mean of prior 3 months.",
            expiresAt: Calendar.current.date(byAdding: .day, value: 10, to: .now),
            dedupeKey: "household:spike:\(topMember.id.uuidString.prefix(8))",
            deeplink: .household
        )]
    }
}
