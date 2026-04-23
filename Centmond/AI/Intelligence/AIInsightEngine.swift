import Foundation
import SwiftData
@preconcurrency import UserNotifications
import os.log

// ============================================================
// MARK: - AI Insight Engine
// ============================================================
//
// Generates proactive insights from the user's financial data
// without requiring a chat interaction. These appear as banners
// on the dashboard, in the morning briefing, etc.
//
// Pure heuristic analysis — no LLM call needed for most insights.
//
// macOS Centmond: @Observable instead of ObservableObject,
// ModelContext instead of Store, Decimal instead of cents,
// os.Logger instead of SecureLogger.
//
// ============================================================

private let logger = Logger(subsystem: "com.centmond.ai", category: "InsightEngine")

@MainActor @Observable
final class AIInsightEngine {

    static let shared = AIInsightEngine()

    // MARK: - State

    private(set) var insights: [AIInsight] = []
    private(set) var morningBriefing: AIInsight?
    var eventInsight: AIInsight?

    var isMorningNotificationEnabled: Bool = UserDefaults.standard.bool(forKey: "ai.morningNotification") {
        didSet {
            UserDefaults.standard.set(isMorningNotificationEnabled, forKey: "ai.morningNotification")
            if isMorningNotificationEnabled {
                scheduleMorningNotification()
            } else {
                cancelMorningNotification()
            }
        }
    }

    var isWeeklyReviewEnabled: Bool = UserDefaults.standard.bool(forKey: "ai.weeklyReview") {
        didSet {
            UserDefaults.standard.set(isWeeklyReviewEnabled, forKey: "ai.weeklyReview")
            if isWeeklyReviewEnabled {
                scheduleWeeklyReview()
            } else {
                cancelWeeklyReview()
            }
        }
    }

    /// Master toggle for event-driven critical push notifications. Morning
    /// + weekly schedules have their own flags; this gate is separate so a
    /// user can keep the daily digest while muting "you just breached X".
    var isCriticalPushEnabled: Bool = UserDefaults.standard.object(forKey: "ai.criticalPush") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isCriticalPushEnabled, forKey: "ai.criticalPush")
        }
    }

    /// Opt-in LLM enrichment of insight advice strings. Off by default —
    /// heuristic advice ships synchronously; this flag only affects whether
    /// the background Gemma pass rewrites the top few in a punchier tone.
    /// Never triggers a model load on its own; only runs when the model is
    /// already `.ready`.
    var isInsightEnrichmentEnabled: Bool = UserDefaults.standard.bool(forKey: "ai.insightEnrichment") {
        didSet {
            UserDefaults.standard.set(isInsightEnrichmentEnabled, forKey: "ai.insightEnrichment")
        }
    }

    /// Persistent dedupe — the set of dedupeKeys we've already pushed as a
    /// critical notification. Prevents re-pushing the same insight every
    /// refresh while it remains in the feed.
    private var pushedCriticalKeys: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "ai.criticalPush.keys") ?? []
    )

    /// Soft rate-limit — at most one critical push per hour even if several
    /// new criticals land at once. They'll still all appear inside the
    /// Insights hub; the push just batches them into one notification.
    private var lastCriticalPushAt: Date = UserDefaults.standard.object(forKey: "ai.criticalPush.lastAt") as? Date ?? .distantPast

    private init() {}

    // MARK: - Generate All Insights

    func refresh(context: ModelContext) {
        var new: [AIInsight] = []

        new.append(contentsOf: budgetInsights(context: context))
        new.append(contentsOf: spendingInsights(context: context))
        new.append(contentsOf: goalInsights(context: context))
        new.append(contentsOf: subscriptionInsights(context: context))

        // P2 — detector catalogue
        new.append(contentsOf: InsightDetectors.cashflowRunway(context: context))
        new.append(contentsOf: InsightDetectors.incomeDrop(context: context))
        new.append(contentsOf: InsightDetectors.subscriptionUnused(context: context))
        new.append(contentsOf: InsightDetectors.subscriptionPriceHike(context: context))
        new.append(contentsOf: InsightDetectors.duplicateSubscriptions(context: context))
        new.append(contentsOf: InsightDetectors.recurringOverdue(context: context))
        new.append(contentsOf: InsightDetectors.daySpike(context: context))
        new.append(contentsOf: InsightDetectors.newLargeMerchant(context: context))
        new.append(contentsOf: InsightDetectors.duplicateTransactions(context: context))

        // P8 (Net Worth rebuild) — net-worth detectors. Namespaced
        // dedupe keys under "networth:" so dismissals stay siloed.
        new.append(contentsOf: NetWorthInsightDetectors.all(context: context))

        // P7 (Household rebuild) — imbalance/unpaid-share/unattributed-recurring/
        // spender-spike. All dedupe keys under "household:" per the silo rule.
        new.append(contentsOf: HouseholdInsightDetectors.all(context: context))

        // Review Queue hidden — skip its insight detectors too.
        // Uncomment when restoring the section.
        // new.append(contentsOf: ReviewQueueInsightDetectors.all(context: context))

        // P3 — orchestration pipeline: sort → expire → dedupe → dismiss → cap.
        new.sort { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            return a.timestamp > b.timestamp
        }
        let now = Date()
        new = new.filter { ($0.expiresAt ?? .distantFuture) > now }

        var seenKeys: Set<String> = []
        new = new.filter { seenKeys.insert($0.dedupeKey).inserted }

        // Filter against user-dismissed keys. Expired snoozes are reaped
        // opportunistically so the table doesn't grow unbounded.
        let dismissed = activeDismissals(context: context, now: now)
        new = new.filter { !dismissed.contains($0.dedupeKey) }

        // P8 — drop whole detectors the user (or the auto-mute heuristic)
        // has muted. Manual un-mute lives in Settings.
        let telemetry = InsightTelemetry.shared
        new = new.filter { !telemetry.isMuted($0.detectorID) }

        // Per-domain caps — let criticals through, throttle the rest so
        // one noisy detector can't flood the list.
        new = applyDomainCaps(new)

        // Record a single impression per surviving insight for telemetry.
        for insight in new {
            telemetry.recordShown(detectorID: insight.detectorID)
        }

        insights = new
        morningBriefing = buildMorningBriefing(context: context)

        // TODO: P7 — AIEventBus.shared.runDailyCheck(context:)

        if isMorningNotificationEnabled {
            scheduleMorningNotification()
        }
        if isWeeklyReviewEnabled {
            scheduleWeeklyReview(context: context)
        }
        pushNewCriticalsIfNeeded()

        // P7 — fire-and-forget LLM polish of the top few advice strings.
        // Runs only when model is .ready and enrichment flag is on. The
        // detectors' heuristic advice is already visible; this pass just
        // upgrades it. Captures a snapshot of `insights` to avoid racing
        // with a subsequent refresh.
        if isInsightEnrichmentEnabled {
            let snapshot = insights
            Task { @MainActor [weak self] in
                let enriched = await InsightEnricher.enrich(snapshot)
                guard let self else { return }
                // Only apply if the set of dedupeKeys still matches — if
                // another refresh landed in the meantime, skip to avoid
                // stomping newer data.
                let currentKeys = self.insights.map(\.dedupeKey)
                let enrichedKeys = enriched.map(\.dedupeKey)
                guard currentKeys == enrichedKeys else { return }
                self.insights = enriched
            }
        }
    }

    // MARK: - Event-driven critical push (P6)

    /// Fires a local notification when a new `.critical` insight lands that
    /// we haven't pushed before. Debounced to at most 1 push per hour —
    /// multiple new criticals in a burst collapse into one notification
    /// listing the top 3. The Insights hub still shows them all.
    private func pushNewCriticalsIfNeeded() {
        guard isCriticalPushEnabled else { return }

        // Reap dedupeKeys that have left the feed — the underlying condition
        // resolved, so if it ever comes back we want a fresh notification.
        let currentKeys = Set(insights.map(\.dedupeKey))
        let reaped = pushedCriticalKeys.subtracting(currentKeys)
        if !reaped.isEmpty {
            pushedCriticalKeys.subtract(reaped)
            UserDefaults.standard.set(Array(pushedCriticalKeys), forKey: "ai.criticalPush.keys")
        }

        let criticals = insights.filter { $0.severity == .critical }
        let unpushed = criticals.filter { !pushedCriticalKeys.contains($0.dedupeKey) }
        guard !unpushed.isEmpty else { return }

        let now = Date()
        guard now.timeIntervalSince(lastCriticalPushAt) >= 3600 else {
            // Hold until the rate-limit window reopens; next refresh retries.
            return
        }

        let batch = Array(unpushed.prefix(3))
        let title: String
        let body: String
        if batch.count == 1, let only = batch.first {
            title = only.title
            body = only.advice ?? only.warning
        } else {
            title = "\(criticals.count) critical item(s) need attention"
            body = batch.map { "• \($0.title)" }.joined(separator: "\n")
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "AI_CRITICAL"

        let request = UNNotificationRequest(
            identifier: "ai.critical.\(UUID().uuidString)",
            content: content,
            trigger: nil  // deliver immediately
        )
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request) { error in
                if let error {
                    logger.error("Critical push error: \(error.localizedDescription)")
                }
            }
        }

        for insight in batch {
            pushedCriticalKeys.insert(insight.dedupeKey)
        }
        lastCriticalPushAt = now
        UserDefaults.standard.set(Array(pushedCriticalKeys), forKey: "ai.criticalPush.keys")
        UserDefaults.standard.set(now, forKey: "ai.criticalPush.lastAt")
    }

    // MARK: - Event-Driven Insights

    func onTransactionAdded(_ txn: Transaction, context: ModelContext) {
        let month = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: month)
        let monthNum = cal.component(.month, from: month)

        // Get total budget
        let budgetDescriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == monthNum }
        )
        let budgetAmount = (try? context.fetch(budgetDescriptor).first)?.amount ?? 0

        guard budgetAmount > 0, !txn.isIncome, BalanceService.isSpendingExpense(txn) else { return }

        let spent = monthSpending(context: context, month: month)
        let budgetDouble = NSDecimalNumber(decimal: budgetAmount).doubleValue
        let spentDouble = NSDecimalNumber(decimal: spent).doubleValue
        let txnDouble = NSDecimalNumber(decimal: txn.amount).doubleValue
        let ratio = spentDouble / budgetDouble

        // Just pushed over budget
        if ratio >= 1.0 && (spentDouble - txnDouble) / budgetDouble < 1.0 {
            let catName = txn.category?.name ?? "expense"
            eventInsight = AIInsight(
                kind: .budgetWarning,
                title: "Budget just exceeded!",
                warning: "This \(fmtDecimal(txn.amount)) \(catName) expense pushed you over your \(fmtDecimal(budgetAmount)) budget.",
                severity: .critical,
                dedupeKey: "budget:exceeded",
                deeplink: .budgets
            )
            return
        }

        // Crossed 80% threshold
        if ratio >= 0.8 && (spentDouble - txnDouble) / budgetDouble < 0.8 {
            let left = budgetAmount - spent
            eventInsight = AIInsight(
                kind: .budgetWarning,
                title: "80% of budget used",
                warning: "Only \(fmtDecimal(left)) remaining this month.",
                severity: .warning,
                advice: "Slow spending in your top category for the next few days.",
                dedupeKey: "budget:80pct",
                deeplink: .budgets
            )
            return
        }

        // Spending anomaly — transaction much larger than category average
        let catName = txn.category?.name
        let catID = txn.category?.id
        if let catName, let catID {
            let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month))!
            let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
            let txnId = txn.id
            // Pre-filter by category at the store level so we only hydrate
            // same-category txns — was fetching ALL non-income this month
            // then filtering by catName in memory on every insert.
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate {
                    !$0.isIncome
                        && $0.date >= monthStart
                        && $0.date < monthEnd
                        && $0.id != txnId
                        && $0.category?.id == catID
                }
            )
            if let sameCat = try? context.fetch(descriptor), !sameCat.isEmpty {
                let total = sameCat.reduce(Decimal.zero) { $0 + $1.amount }
                let avg = total / Decimal(sameCat.count)
                if txn.amount > avg * 3 && txn.amount > 10 {
                        let multiplier = NSDecimalNumber(decimal: txn.amount / max(avg, 1)).intValue
                        eventInsight = AIInsight(
                            kind: .spendingAnomaly,
                            title: "Unusually large expense",
                            warning: "This \(fmtDecimal(txn.amount)) in \(catName) is \(multiplier)x your average for this category.",
                            severity: .warning,
                            cause: "Average \(catName) expense this month is ~\(fmtDecimal(avg)).",
                            dedupeKey: "anomaly:\(txn.id.uuidString)",
                            deeplink: .transactions(txn.id)
                        )
                    return
                }
            }
        }

        // Positive: first transaction of the day
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!
        let txnIdForToday = txn.id
        let todayDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate {
                $0.date >= todayStart && $0.date < todayEnd && $0.id != txnIdForToday
            }
        )
        let todayCount = (try? context.fetchCount(todayDescriptor)) ?? 0
        if todayCount == 0 && !txn.isIncome {
            eventInsight = AIInsight(
                kind: .patternDetected,
                title: "Expense logged",
                warning: "Good habit! Tracking your spending helps you stay in control.",
                severity: .positive,
                dedupeKey: "pattern:firstLogToday"
            )
        }
    }

    func clearEventInsight() {
        eventInsight = nil
    }

    // MARK: - Budget Insights

    private func budgetInsights(context: ModelContext) -> [AIInsight] {
        var results: [AIInsight] = []
        let month = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: month)
        let monthNum = cal.component(.month, from: month)

        let budgetDescriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == monthNum }
        )
        guard let budgetAmount = try? context.fetch(budgetDescriptor).first?.amount,
              budgetAmount > 0 else { return [] }

        let spent = monthSpending(context: context, month: month)
        let budgetDouble = NSDecimalNumber(decimal: budgetAmount).doubleValue
        let spentDouble = NSDecimalNumber(decimal: spent).doubleValue
        let ratio = spentDouble / budgetDouble
        let dayOfMonth = cal.component(.day, from: month)
        let daysInMonth = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let expectedRatio = Double(dayOfMonth) / Double(daysInMonth)

        if ratio >= 1.0 {
            let over = spent - budgetAmount
            results.append(AIInsight(
                kind: .budgetWarning,
                title: "Budget exceeded",
                warning: "You've spent \(fmtDecimal(spent)) of your \(fmtDecimal(budgetAmount)) budget this month.",
                severity: .critical,
                advice: "Cut discretionary spending by \(fmtDecimal(over)) to stay close to plan next month.",
                dedupeKey: "budget:exceeded:\(year)-\(monthNum)",
                deeplink: .budgets
            ))
        } else if ratio > expectedRatio + 0.15 && ratio > 0.5 {
            let pacePercent = Int(ratio * 100)
            let calPercent = Int(expectedRatio * 100)
            results.append(AIInsight(
                kind: .budgetWarning,
                title: "Spending pace ahead",
                warning: "You've used \(pacePercent)% of your budget but only \(calPercent)% of the month has passed.",
                severity: .warning,
                advice: "Review your top category and pause non-essential charges this week.",
                dedupeKey: "budget:pace:\(year)-\(monthNum)",
                deeplink: .budgets
            ))
        } else if ratio < expectedRatio - 0.1 && dayOfMonth > 10 {
            let remaining = budgetAmount - spent
            results.append(AIInsight(
                kind: .budgetWarning,
                title: "On track",
                warning: "You're under budget — \(fmtDecimal(remaining)) remaining with \(daysInMonth - dayOfMonth) days left.",
                severity: .positive,
                dedupeKey: "budget:onTrack:\(year)-\(monthNum)",
                deeplink: .budgets
            ))
        }

        // Category budget warnings
        let catBudgetDescriptor = FetchDescriptor<MonthlyBudget>(
            predicate: #Predicate { $0.year == year && $0.month == monthNum }
        )
        if let catBudgets = try? context.fetch(catBudgetDescriptor) {
            let catSpending = categorySpending(context: context, month: month)
            for cb in catBudgets where cb.amount > 0 {
                let catId = cb.categoryID
                if let spent = catSpending[catId], spent > cb.amount {
                    let catName = categoryName(for: catId, context: context)
                    let over = spent - cb.amount
                    results.append(AIInsight(
                        kind: .budgetWarning,
                        title: "\(catName) over budget",
                        warning: "\(catName): \(fmtDecimal(spent)) spent of \(fmtDecimal(cb.amount)) budget.",
                        severity: .warning,
                        advice: "Trim \(fmtDecimal(over)) from \(catName) or raise this category's budget.",
                        dedupeKey: "budget:cat:\(catId.uuidString):\(year)-\(monthNum)",
                        deeplink: .budgets
                    ))
                }
            }
        }

        return results
    }

    // MARK: - Spending Insights

    private func spendingInsights(context: ModelContext) -> [AIInsight] {
        var results: [AIInsight] = []
        let catSpending = categorySpending(context: context, month: Date())

        guard !catSpending.isEmpty else { return [] }

        // Top spending category
        if let top = catSpending.max(by: { $0.value < $1.value }) {
            let catName = categoryName(for: top.key, context: context)
            results.append(AIInsight(
                kind: .patternDetected,
                title: "Top category: \(catName)",
                warning: "You've spent \(fmtDecimal(top.value)) on \(catName) this month.",
                severity: .watch,
                dedupeKey: "pattern:topCategory",
                deeplink: .budgets
            ))
        }

        return results
    }

    // MARK: - Goal Insights

    private func goalInsights(context: ModelContext) -> [AIInsight] {
        var results: [AIInsight] = []
        let activeStatus = GoalStatus.active
        let descriptor = FetchDescriptor<Goal>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        guard let goals = try? context.fetch(descriptor) else { return [] }

        // Rule counts — used to gate the "no-rule" variant of the stalled
        // insight so we don't nag users who've set up automation already.
        let ruleDescriptor = FetchDescriptor<GoalAllocationRule>(
            predicate: #Predicate { $0.isActive }
        )
        let activeRules = (try? context.fetch(ruleDescriptor)) ?? []
        let ruleCountByGoal: [UUID: Int] = activeRules.reduce(into: [:]) { acc, rule in
            guard let id = rule.goal?.id else { return }
            acc[id, default: 0] += 1
        }

        let cal = Calendar.current
        let todayDay = cal.component(.day, from: Date())

        for goal in goals {
            let progress = goal.progressPercentage

            if progress >= 0.8 && progress < 1.0 {
                let remaining = goal.targetAmount - goal.currentAmount
                let pct = Int(progress * 100)
                results.append(AIInsight(
                    kind: .goalProgress,
                    title: "Almost there!",
                    warning: "\"\(goal.name)\" is \(pct)% complete — \(fmtDecimal(remaining)) to go.",
                    severity: .positive,
                    advice: "One more contribution of \(fmtDecimal(remaining)) closes this goal.",
                    dedupeKey: "goal:almost:\(goal.id.uuidString)",
                    suggestedAction: AIAction(
                        type: .addContribution,
                        params: AIAction.ActionParams(
                            goalName: goal.name,
                            contributionAmount: NSDecimalNumber(decimal: remaining).doubleValue
                        )
                    ),
                    deeplink: .goals(goal.id)
                ))
            } else if let target = goal.targetDate, target < Date() && progress < 1.0 {
                let remaining = goal.targetAmount - goal.currentAmount
                results.append(AIInsight(
                    kind: .goalProgress,
                    title: "Goal overdue",
                    warning: "\"\(goal.name)\" deadline has passed — \(fmtDecimal(remaining)) remaining.",
                    severity: .warning,
                    advice: "Push the deadline or set up an auto-allocation rule to close the gap.",
                    dedupeKey: "goal:overdue:\(goal.id.uuidString)",
                    deeplink: .goals(goal.id)
                ))
            }

            // Stalled goal: no contributions this month, already past the
            // 15th of the month, and no active rule. Gate by day-of-month so
            // we don't fire on day 1. Skip when progress is 100% already.
            if progress < 1.0, todayDay >= 15 {
                let thisMonth = GoalAnalytics.thisMonthContribution(goal)
                let ruleCount = ruleCountByGoal[goal.id] ?? 0
                if thisMonth == 0 && ruleCount == 0 {
                    results.append(AIInsight(
                        kind: .goalProgress,
                        title: "Goal stalled this month",
                        warning: "\"\(goal.name)\" has received nothing this month and has no auto-allocation rule.",
                        severity: .warning,
                        advice: "Add an auto-allocation rule so it gets funded on your next income.",
                        dedupeKey: "goal:stalled:\(goal.id.uuidString)",
                        deeplink: .goals(goal.id)
                    ))
                }
            }
        }

        // Idle income nudge — fires once globally (not per-goal) when there
        // is at least one active goal AND current-month income has rows
        // with no linked GoalContribution.
        if !goals.isEmpty {
            let unallocated = GoalAnalytics.unallocatedIncomeThisMonth(context: context)
            if unallocated.total > 0 {
                results.append(AIInsight(
                    kind: .goalProgress,
                    title: "Unallocated income",
                    warning: "\(fmtDecimal(unallocated.total)) of income this month is sitting without a goal.",
                    severity: .watch,
                    advice: "Route a slice into a goal on your next income entry, or add an auto-rule.",
                    dedupeKey: "goal:unallocated",
                    deeplink: .goals(nil)
                ))
            }
        }

        return results
    }

    // MARK: - Subscription Insights

    private func subscriptionInsights(context: ModelContext) -> [AIInsight] {
        var results: [AIInsight] = []
        let activeStatus = SubscriptionStatus.active
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        guard let subs = try? context.fetch(descriptor) else { return [] }

        let now = Date()
        let threeDaysFromNow = Calendar.current.date(byAdding: .day, value: 3, to: now)!

        for sub in subs {
            // Upcoming renewals (within 3 days)
            let nextDate = sub.nextPaymentDate
            if nextDate > now && nextDate <= threeDaysFromNow {
                let days = Calendar.current.dateComponents([.day], from: now, to: nextDate).day ?? 0
                results.append(AIInsight(
                    kind: .subscriptionRenewal,
                    title: "\(sub.serviceName) renewing soon",
                    warning: "\(fmtDecimal(sub.amount)) charge in \(days) day(s).",
                    severity: .watch,
                    advice: "Cancel now if you're not using it — otherwise you'll be billed again.",
                    dedupeKey: "sub:renew:\(sub.id.uuidString):\(Calendar.current.component(.day, from: nextDate))",
                    deeplink: .subscriptions(sub.id)
                ))
            }
        }

        return results
    }

    // MARK: - Morning Briefing (P6)

    /// Morning briefing pulls directly from the insight feed: top 3 urgent
    /// (critical+warning) items, plus one positive if the queue isn't all
    /// bad news. Falls back to a short cashflow summary on quiet mornings.
    private func buildMorningBriefing(context: ModelContext) -> AIInsight? {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        let monthNum = cal.component(.month, from: now)
        let dayOfMonth = cal.component(.day, from: now)

        let urgent = insights
            .filter { $0.severity == .critical || $0.severity == .warning }
            .prefix(3)
        let topPositive = insights.first(where: { $0.severity == .positive })

        var bodyLines: [String] = []
        for insight in urgent {
            if let advice = insight.advice, !advice.isEmpty {
                bodyLines.append("• \(insight.title) — \(advice)")
            } else {
                bodyLines.append("• \(insight.title) — \(insight.warning)")
            }
        }
        if let positive = topPositive {
            bodyLines.append("✓ \(positive.title)")
        }

        // Empty insight queue — fall back to a one-line cashflow summary so
        // the morning notification isn't silent when things are genuinely
        // quiet. If even that has no data, don't surface a briefing at all.
        if bodyLines.isEmpty {
            let spent = monthSpending(context: context, month: now)
            let income = monthIncome(context: context, month: now)
            guard spent > 0 || income > 0 else { return nil }
            bodyLines.append("Spent \(fmtDecimal(spent)) this month • Income \(fmtDecimal(income))")
        }

        let title: String
        let severity: AIInsight.Severity
        if insights.contains(where: { $0.severity == .critical }) {
            title = "Needs your attention"
            severity = .critical
        } else if !urgent.isEmpty {
            title = "Worth a look today"
            severity = .warning
        } else {
            title = "Good morning"
            severity = .watch
        }

        return AIInsight(
            kind: .morningBriefing,
            title: title,
            warning: bodyLines.joined(separator: "\n"),
            severity: severity,
            dedupeKey: "briefing:morning:\(year)-\(monthNum)-\(dayOfMonth)",
            deeplink: .dashboard
        )
    }

    // MARK: - Weekly Review

    func buildWeeklyReview(context: ModelContext) -> String? {
        let calendar = Calendar.current
        let now = Date()
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }

        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.date >= weekAgo && $0.date <= now }
        )
        guard let weekTxns = try? context.fetch(descriptor), !weekTxns.isEmpty else { return nil }

        let expenses = weekTxns.filter { !$0.isIncome && BalanceService.isSpendingExpense($0) }
        let incomes = weekTxns.filter { $0.isIncome }
        let totalSpent = expenses.reduce(Decimal.zero) { $0 + $1.amount }
        let totalIncome = incomes.reduce(Decimal.zero) { $0 + $1.amount }

        var parts: [String] = []
        parts.append("This week: \(expenses.count) expenses totaling \(fmtDecimal(totalSpent))")
        if totalIncome > 0 {
            parts.append("Income: \(fmtDecimal(totalIncome))")
        }

        // Top category
        var catTotals: [String: Decimal] = [:]
        for t in expenses {
            let name = t.category?.name ?? "Other"
            catTotals[name, default: 0] += t.amount
        }
        if let top = catTotals.max(by: { $0.value < $1.value }) {
            parts.append("Top category: \(top.key) (\(fmtDecimal(top.value)))")
        }

        // Top 3 urgent insights from the current feed — same source of truth
        // as the morning briefing and the Insights hub.
        let urgent = insights
            .filter { $0.severity == .critical || $0.severity == .warning }
            .prefix(3)
        for insight in urgent {
            if let advice = insight.advice, !advice.isEmpty {
                parts.append("• \(insight.title) — \(advice)")
            } else {
                parts.append("• \(insight.title)")
            }
        }
        if let positive = insights.first(where: { $0.severity == .positive }) {
            parts.append("✓ \(positive.title)")
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Notifications

    private nonisolated static let morningNotificationId = "ai.morning.briefing"
    private nonisolated static let weeklyNotificationId = "ai.weekly.review"

    func scheduleMorningNotification() {
        guard let briefing = morningBriefing else {
            cancelMorningNotification()
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = briefing.title
            content.body = briefing.warning
            content.sound = .default
            content.categoryIdentifier = "AI_MORNING_BRIEFING"

            var dateComponents = DateComponents()
            dateComponents.hour = 8
            dateComponents.minute = 0

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(
                identifier: Self.morningNotificationId,
                content: content,
                trigger: trigger
            )

            center.removePendingNotificationRequests(withIdentifiers: [Self.morningNotificationId])
            center.add(request) { error in
                if let error {
                    logger.error("Morning notification error: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelMorningNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.morningNotificationId])
    }

    func scheduleWeeklyReview(context: ModelContext? = nil) {
        // Pre-bake the review body at schedule-time so the Sunday-evening
        // notification actually lists current insights instead of a generic
        // teaser. Call `refresh(context:)` before relying on this — the
        // engine auto-reschedules whenever the feed updates.
        let body: String
        if let context, let summary = buildWeeklyReview(context: context), !summary.isEmpty {
            body = summary
        } else {
            body = "Tap to see your weekly spending summary."
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Your Week in Review"
            content.body = body
            content.sound = .default
            content.categoryIdentifier = "AI_WEEKLY_REVIEW"

            var dateComponents = DateComponents()
            dateComponents.weekday = 1  // Sunday
            dateComponents.hour = 19
            dateComponents.minute = 0

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(
                identifier: Self.weeklyNotificationId,
                content: content,
                trigger: trigger
            )

            center.removePendingNotificationRequests(withIdentifiers: [Self.weeklyNotificationId])
            center.add(request) { error in
                if let error {
                    logger.error("Weekly review notification error: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelWeeklyReview() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.weeklyNotificationId])
    }

    // MARK: - Helpers

    private func monthSpending(context: ModelContext, month: Date) -> Decimal {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
        )
        guard let txns = try? context.fetch(descriptor) else { return 0 }
        return txns.filter { BalanceService.isSpendingExpense($0) }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func monthIncome(context: ModelContext, month: Date) -> Decimal {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
        )
        guard let txns = try? context.fetch(descriptor) else { return 0 }
        return txns.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func categorySpending(context: ModelContext, month: Date) -> [UUID: Decimal] {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
        )
        guard let txns = try? context.fetch(descriptor) else { return [:] }

        var result: [UUID: Decimal] = [:]
        for t in txns where BalanceService.isSpendingExpense(t) {
            if let catId = t.category?.id {
                result[catId, default: 0] += t.amount
            }
        }
        return result
    }

    private func categoryName(for id: UUID, context: ModelContext) -> String {
        let descriptor = FetchDescriptor<BudgetCategory>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? context.fetch(descriptor).first)?.name ?? "Unknown"
    }

    private func fmtDecimal(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }

    // MARK: - Apply primary action (P4)

    /// Wires an insight's suggested action + deeplink + auto-dismiss in one
    /// call. If the insight has a structured `suggestedAction`, the executor
    /// runs it and the result is returned for the caller to surface. If it
    /// has a `deeplink`, the router jumps to that screen. Either way the
    /// insight is dismissed permanently — acting on it is implicit consent
    /// that it's handled.
    @discardableResult
    func apply(
        _ insight: AIInsight,
        router: AppRouter,
        context: ModelContext
    ) -> AIActionExecutor.ExecutionResult? {
        var result: AIActionExecutor.ExecutionResult?
        if let action = insight.suggestedAction {
            result = AIActionExecutor.execute(action, context: context)
        }
        if let deeplink = insight.deeplink {
            router.follow(deeplink)
        }
        InsightTelemetry.shared.recordActedOn(detectorID: insight.detectorID)
        dismiss(insight, context: context, snoozeDays: nil, recordTelemetry: false)
        return result
    }

    // MARK: - Dismiss / Snooze (P3)

    /// Hides an insight until `snoozeDays` have passed. Pass `nil` to dismiss
    /// permanently. Writes a `DismissedInsight` keyed by the insight's
    /// `dedupeKey` and refreshes the feed in place.
    func dismiss(
        _ insight: AIInsight,
        context: ModelContext,
        snoozeDays: Int? = nil,
        recordTelemetry: Bool = true
    ) {
        let key = insight.dedupeKey
        let snoozeUntil = snoozeDays.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: .now) }

        let existingDescriptor = FetchDescriptor<DismissedInsight>(
            predicate: #Predicate { $0.dedupeKey == key }
        )
        if let existing = try? context.fetch(existingDescriptor).first {
            existing.dismissedAt = .now
            existing.snoozeUntil = snoozeUntil
        } else {
            context.insert(DismissedInsight(dedupeKey: key, snoozeUntil: snoozeUntil))
        }
        context.persist()

        // recordTelemetry is false when called from `apply` — acting on an
        // insight is a positive signal, not a dismissal, and the
        // `recordActedOn` bump has already happened there.
        if recordTelemetry {
            InsightTelemetry.shared.recordDismissed(detectorID: insight.detectorID)
        }

        insights.removeAll { $0.id == insight.id }
        if eventInsight?.id == insight.id { eventInsight = nil }
    }

    /// Dedupe keys that are currently suppressed. Reaps expired snoozes as
    /// a side-effect so the table stays bounded.
    private func activeDismissals(context: ModelContext, now: Date) -> Set<String> {
        let descriptor = FetchDescriptor<DismissedInsight>()
        guard let rows = try? context.fetch(descriptor) else { return [] }

        var active: Set<String> = []
        var reapedAny = false
        for row in rows {
            if let until = row.snoozeUntil, until <= now {
                context.delete(row)
                reapedAny = true
                continue
            }
            active.insert(row.dedupeKey)
        }
        if reapedAny { context.persist() }
        return active
    }

    // MARK: - Domain caps (P3)

    /// Caps per-domain volume by severity. Critical insights bypass the cap
    /// — the user needs every critical regardless of domain quota.
    private func applyDomainCaps(_ sorted: [AIInsight]) -> [AIInsight] {
        var perDomainCount: [AIInsight.Domain: Int] = [:]
        var result: [AIInsight] = []
        for insight in sorted {
            if insight.severity == .critical {
                result.append(insight)
                continue
            }
            let count = perDomainCount[insight.domain, default: 0]
            let cap = perDomainCap(for: insight.severity)
            if count < cap {
                result.append(insight)
                perDomainCount[insight.domain] = count + 1
            }
        }
        return result
    }

    private func perDomainCap(for severity: AIInsight.Severity) -> Int {
        switch severity {
        case .critical: return .max
        case .warning:  return 3
        case .watch:    return 2
        case .positive: return 2
        }
    }
}
