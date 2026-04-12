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

    private init() {}

    // MARK: - Generate All Insights

    func refresh(context: ModelContext) {
        var new: [AIInsight] = []

        new.append(contentsOf: budgetInsights(context: context))
        new.append(contentsOf: spendingInsights(context: context))
        new.append(contentsOf: goalInsights(context: context))
        new.append(contentsOf: subscriptionInsights(context: context))
        // TODO: P9 — duplicateInsights, recurringInsights
        // TODO: P8 — householdInsights

        new.sort { a, b in
            if a.severity != b.severity { return severityOrder(a.severity) < severityOrder(b.severity) }
            return a.timestamp > b.timestamp
        }

        insights = new
        morningBriefing = buildMorningBriefing(context: context)

        // TODO: P7 — AIEventBus.shared.runDailyCheck(context:)

        if isMorningNotificationEnabled {
            scheduleMorningNotification()
        }
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
                type: .budgetWarning,
                title: "Budget just exceeded!",
                body: "This \(fmtDecimal(txn.amount)) \(catName) expense pushed you over your \(fmtDecimal(budgetAmount)) budget.",
                severity: .critical
            )
            return
        }

        // Crossed 80% threshold
        if ratio >= 0.8 && (spentDouble - txnDouble) / budgetDouble < 0.8 {
            let left = budgetAmount - spent
            eventInsight = AIInsight(
                type: .budgetWarning,
                title: "80% of budget used",
                body: "Only \(fmtDecimal(left)) remaining this month. Consider slowing down spending.",
                severity: .warning
            )
            return
        }

        // Spending anomaly — transaction much larger than category average
        let catName = txn.category?.name
        if let catName {
            let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month))!
            let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
            let txnId = txn.id
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate {
                    !$0.isIncome && $0.date >= monthStart && $0.date < monthEnd && $0.id != txnId
                }
            )
            if let others = try? context.fetch(descriptor) {
                let sameCat = others.filter { $0.category?.name == catName }
                if !sameCat.isEmpty {
                    let total = sameCat.reduce(Decimal.zero) { $0 + $1.amount }
                    let avg = total / Decimal(sameCat.count)
                    if txn.amount > avg * 3 && txn.amount > 10 {
                        let multiplier = NSDecimalNumber(decimal: txn.amount / max(avg, 1)).intValue
                        eventInsight = AIInsight(
                            type: .spendingAnomaly,
                            title: "Unusually large expense",
                            body: "This \(fmtDecimal(txn.amount)) in \(catName) is \(multiplier)x your average for this category.",
                            severity: .warning
                        )
                        return
                    }
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
                type: .patternDetected,
                title: "Expense logged",
                body: "Good habit! Tracking your spending helps you stay in control.",
                severity: .positive
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
            results.append(AIInsight(
                type: .budgetWarning,
                title: "Budget exceeded",
                body: "You've spent \(fmtDecimal(spent)) of your \(fmtDecimal(budgetAmount)) budget this month.",
                severity: .critical
            ))
        } else if ratio > expectedRatio + 0.15 && ratio > 0.5 {
            let pacePercent = Int(ratio * 100)
            let calPercent = Int(expectedRatio * 100)
            results.append(AIInsight(
                type: .budgetWarning,
                title: "Spending pace ahead",
                body: "You've used \(pacePercent)% of your budget but only \(calPercent)% of the month has passed.",
                severity: .warning
            ))
        } else if ratio < expectedRatio - 0.1 && dayOfMonth > 10 {
            let remaining = budgetAmount - spent
            results.append(AIInsight(
                type: .budgetWarning,
                title: "On track",
                body: "You're under budget — \(fmtDecimal(remaining)) remaining with \(daysInMonth - dayOfMonth) days left.",
                severity: .positive
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
                    results.append(AIInsight(
                        type: .budgetWarning,
                        title: "\(catName) over budget",
                        body: "\(catName): \(fmtDecimal(spent)) spent of \(fmtDecimal(cb.amount)) budget.",
                        severity: .warning
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
                type: .patternDetected,
                title: "Top category: \(catName)",
                body: "You've spent \(fmtDecimal(top.value)) on \(catName) this month.",
                severity: .info
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

        for goal in goals {
            let progress = goal.progressPercentage

            if progress >= 0.8 && progress < 1.0 {
                let remaining = goal.targetAmount - goal.currentAmount
                let pct = Int(progress * 100)
                results.append(AIInsight(
                    type: .goalProgress,
                    title: "Almost there!",
                    body: "\"\(goal.name)\" is \(pct)% complete — \(fmtDecimal(remaining)) to go.",
                    severity: .positive,
                    suggestedAction: AIAction(
                        type: .addContribution,
                        params: AIAction.ActionParams(
                            goalName: goal.name,
                            contributionAmount: NSDecimalNumber(decimal: remaining).doubleValue
                        )
                    )
                ))
            } else if let target = goal.targetDate, target < Date() && progress < 1.0 {
                let remaining = goal.targetAmount - goal.currentAmount
                results.append(AIInsight(
                    type: .goalProgress,
                    title: "Goal overdue",
                    body: "\"\(goal.name)\" deadline has passed — \(fmtDecimal(remaining)) remaining.",
                    severity: .warning
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
                    type: .recurringDetected,
                    title: "\(sub.serviceName) renewing soon",
                    body: "\(fmtDecimal(sub.amount)) charge in \(days) day(s).",
                    severity: .info
                ))
            }
        }

        return results
    }

    // MARK: - Morning Briefing

    private func buildMorningBriefing(context: ModelContext) -> AIInsight? {
        let month = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: month)
        let monthNum = cal.component(.month, from: month)
        let dayOfMonth = cal.component(.day, from: month)
        let daysInMonth = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let remaining = daysInMonth - dayOfMonth

        var parts: [String] = []

        // Budget status
        let budgetDescriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == monthNum }
        )
        if let budgetAmount = try? context.fetch(budgetDescriptor).first?.amount, budgetAmount > 0 {
            let spent = monthSpending(context: context, month: month)
            let left = budgetAmount - spent
            parts.append("Budget: \(fmtDecimal(left)) remaining (\(remaining) days left)")
        }

        // Month spending
        let spent = monthSpending(context: context, month: month)
        if spent > 0 { parts.append("Spent \(fmtDecimal(spent)) this month") }

        // Month income
        let income = monthIncome(context: context, month: month)
        if income > 0 { parts.append("Income: \(fmtDecimal(income))") }

        // Active goals
        let activeStatus = GoalStatus.active
        let goalDescriptor = FetchDescriptor<Goal>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        if let goals = try? context.fetch(goalDescriptor), !goals.isEmpty {
            let avgProgress = goals.reduce(0.0) { $0 + $1.progressPercentage } / Double(goals.count)
            parts.append("\(goals.count) active goal(s) — avg \(Int(avgProgress * 100))% complete")
        }

        // Critical insights count
        let critCount = insights.filter { $0.severity == .critical || $0.severity == .warning }.count
        if critCount > 0 {
            parts.append("\(critCount) item(s) need attention")
        }

        guard !parts.isEmpty else { return nil }

        return AIInsight(
            type: .morningBriefing,
            title: "Good morning",
            body: parts.joined(separator: "\n"),
            severity: .info
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

        // Budget status
        let year = calendar.component(.year, from: now)
        let monthNum = calendar.component(.month, from: now)
        let budgetDescriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == monthNum }
        )
        if let budgetAmount = try? context.fetch(budgetDescriptor).first?.amount, budgetAmount > 0 {
            let monthSpent = monthSpending(context: context, month: now)
            let remaining = budgetAmount - monthSpent
            parts.append("Budget remaining: \(fmtDecimal(remaining))")
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
            content.body = briefing.body
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

    func scheduleWeeklyReview() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Your Week in Review"
            content.body = "Tap to see your weekly spending summary."
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

    private func severityOrder(_ s: AIInsight.Severity) -> Int {
        switch s {
        case .critical: return 0
        case .warning: return 1
        case .info: return 2
        case .positive: return 3
        }
    }
}
