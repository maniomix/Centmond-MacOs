import Foundation
import SwiftData

// ============================================================
// MARK: - AI Proactive Engine
// ============================================================
//
// Generates timely, structured, dismissable proactive items
// that surface finance guidance without waiting for user to ask.
//
// macOS Centmond: @Observable instead of ObservableObject,
// ModelContext instead of Store, Decimal instead of cents.
// Stubs: AIAssistantModeManager (P8), AIDuplicateDetector (P9),
// SubscriptionEngine-style queries replaced with SwiftData.
//
// ============================================================

// MARK: - Proactive Item Types

enum ProactiveItemType: String, Codable, CaseIterable {
    case morningBriefing          = "morning_briefing"
    case weeklyReview             = "weekly_review"
    case monthlyClosePrompt       = "monthly_close_prompt"
    case budgetRisk               = "budget_risk"
    case upcomingBill             = "upcoming_bill"
    case unusualSpending          = "unusual_spending"
    case goalOffTrack             = "goal_off_track"
    case uncategorizedReminder    = "uncategorized_reminder"
    case subscriptionReviewPrompt = "subscription_review_prompt"

    var icon: String {
        switch self {
        case .morningBriefing:          return "sun.max.fill"
        case .weeklyReview:             return "calendar.badge.clock"
        case .monthlyClosePrompt:       return "calendar.badge.checkmark"
        case .budgetRisk:               return "exclamationmark.triangle.fill"
        case .upcomingBill:             return "clock.badge.exclamationmark.fill"
        case .unusualSpending:          return "exclamationmark.circle.fill"
        case .goalOffTrack:             return "target"
        case .uncategorizedReminder:    return "tag.fill"
        case .subscriptionReviewPrompt: return "repeat"
        }
    }

    var sortPriority: Int {
        switch self {
        case .budgetRisk:               return 0
        case .unusualSpending:          return 1
        case .upcomingBill:             return 2
        case .goalOffTrack:             return 3
        case .monthlyClosePrompt:       return 4
        case .uncategorizedReminder:    return 5
        case .subscriptionReviewPrompt: return 6
        case .morningBriefing:          return 7
        case .weeklyReview:             return 8
        }
    }
}

enum ProactiveSeverity: String, Codable, Comparable {
    case critical
    case warning
    case info
    case positive

    private var order: Int {
        switch self {
        case .critical: return 0
        case .warning:  return 1
        case .info:     return 2
        case .positive: return 3
        }
    }

    static func < (lhs: ProactiveSeverity, rhs: ProactiveSeverity) -> Bool {
        lhs.order < rhs.order
    }
}

struct ProactiveAction: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let kind: ActionKind

    var isDismissOnly: Bool {
        if case .dismissOnly = kind { return true }
        return false
    }

    enum ActionKind {
        case startWorkflow(WorkflowType)
        case openChat
        case openIngestion
        case dismissOnly
    }
}

struct ProactiveItem: Identifiable {
    let id: UUID
    let type: ProactiveItemType
    let severity: ProactiveSeverity
    let title: String
    let summary: String
    var detail: String?
    let signals: [String]
    let createdAt: Date
    var updatedAt: Date
    var isDismissed: Bool = false
    var dismissedAt: Date?
    var isActedOn: Bool = false
    var actedOnAt: Date?
    let action: ProactiveAction?
    let dedupKey: String
    var sections: [BriefingSection] = []
}

struct BriefingSection: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let lines: [String]
    var severity: ProactiveSeverity = .info
}

// MARK: - Proactive Engine

@MainActor @Observable
final class AIProactiveEngine {
    static let shared = AIProactiveEngine()

    private(set) var items: [ProactiveItem] = []

    var topItems: [ProactiveItem] {
        Array(items.filter { !$0.isDismissed && $0.severity <= .warning }.prefix(3))
    }

    var morningBriefing: ProactiveItem? {
        items.first { $0.type == .morningBriefing && !$0.isDismissed }
    }

    var weeklyReview: ProactiveItem? {
        items.first { $0.type == .weeklyReview && !$0.isDismissed }
    }

    private var dismissedKeys: Set<String> = []
    private let dismissedKeysStorageKey = "ai.proactive.dismissedKeys"

    private init() {
        loadDismissedKeys()
    }

    // MARK: - Public API

    func refresh(context: ModelContext) {
        // TODO: P8 — Check AIAssistantModeManager.shared.proactiveIntensity

        var generated: [ProactiveItem] = []

        generated.append(contentsOf: generateBudgetRiskItems(context: context))
        generated.append(contentsOf: generateUpcomingBillItems(context: context))
        generated.append(contentsOf: generateGoalItems(context: context))
        generated.append(contentsOf: generateUncategorizedReminder(context: context))
        // TODO: P9 — generateDuplicateWarnings, generateUnusualSpendingItems

        generated = generated.filter { !dismissedKeys.contains($0.dedupKey) }

        generated.sort { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            return a.type.sortPriority < b.type.sortPriority
        }

        items = generated
    }

    func dismiss(_ itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[idx].isDismissed = true
        items[idx].dismissedAt = Date()
        dismissedKeys.insert(items[idx].dedupKey)
        items.remove(at: idx)
        saveDismissedKeys()
    }

    func markActedOn(_ itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[idx].isActedOn = true
        items[idx].actedOnAt = Date()
    }

    func clearStaleDismissals() {
        let today = Calendar.current.startOfDay(for: Date())
        let key = "ai.proactive.lastClear"
        let lastClear = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        if lastClear < today {
            dismissedKeys.removeAll()
            saveDismissedKeys()
            UserDefaults.standard.set(Date(), forKey: key)
        }
    }

    var activeCount: Int { items.count }

    // MARK: - Budget Risk

    private func generateBudgetRiskItems(context: ModelContext) -> [ProactiveItem] {
        var results: [ProactiveItem] = []
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
        let remaining = budgetAmount - spent
        let daysLeft = daysInMonth - dayOfMonth
        let monthKey = "\(year)-\(monthNum)"

        if ratio >= 1.0 {
            results.append(ProactiveItem(
                id: UUID(), type: .budgetRisk, severity: .critical,
                title: "Budget Exceeded",
                summary: "You've spent \(fmtDecimal(spent)) of your \(fmtDecimal(budgetAmount)) budget.",
                signals: ["ratio:\(Int(ratio * 100))%"],
                createdAt: Date(), updatedAt: Date(),
                action: ProactiveAction(label: "Budget Rescue", icon: "lifepreserver.fill",
                                        kind: .startWorkflow(.budgetRescue)),
                dedupKey: "budget_exceeded_\(monthKey)"
            ))
        } else if ratio > expectedRatio + 0.15 && ratio > 0.5 {
            let dailyAllowance = daysLeft > 0 ? remaining / Decimal(daysLeft) : 0
            results.append(ProactiveItem(
                id: UUID(), type: .budgetRisk, severity: .warning,
                title: "Spending Pace Ahead",
                summary: "\(Int(ratio * 100))% used with \(daysLeft) days left. Safe daily spend: \(fmtDecimal(dailyAllowance)).",
                signals: ["paceAhead"],
                createdAt: Date(), updatedAt: Date(),
                action: ProactiveAction(label: "Review Budget", icon: "chart.bar.fill",
                                        kind: .startWorkflow(.budgetRescue)),
                dedupKey: "budget_pace_\(monthKey)_\(Int(ratio * 10))"
            ))
        }

        return results
    }

    // MARK: - Upcoming Bills

    private func generateUpcomingBillItems(context: ModelContext) -> [ProactiveItem] {
        var results: [ProactiveItem] = []
        let now = Date()
        let threeDaysFromNow = Calendar.current.date(byAdding: .day, value: 3, to: now)!
        let activeStatus = SubscriptionStatus.active
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        guard let subs = try? context.fetch(descriptor) else { return [] }

        for sub in subs {
            let nextDate = sub.nextPaymentDate
            if nextDate > now && nextDate <= threeDaysFromNow {
                let days = Calendar.current.dateComponents([.day], from: now, to: nextDate).day ?? 0
                let dayLabel = days == 0 ? "today" : (days == 1 ? "tomorrow" : "in \(days) days")
                results.append(ProactiveItem(
                    id: UUID(), type: .upcomingBill, severity: days == 0 ? .warning : .info,
                    title: "\(sub.serviceName) Due \(dayLabel.capitalized)",
                    summary: "\(fmtDecimal(sub.amount)) charge \(dayLabel).",
                    signals: ["merchant:\(sub.serviceName)", "days:\(days)"],
                    createdAt: Date(), updatedAt: Date(),
                    action: nil,
                    dedupKey: "bill_\(sub.serviceName.lowercased())_\(days)"
                ))
            }
        }

        return results
    }

    // MARK: - Goal Off-Track

    private func generateGoalItems(context: ModelContext) -> [ProactiveItem] {
        var results: [ProactiveItem] = []
        let activeStatus = GoalStatus.active
        let descriptor = FetchDescriptor<Goal>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        guard let goals = try? context.fetch(descriptor) else { return [] }

        for goal in goals {
            if let target = goal.targetDate, target < Date() && goal.progressPercentage < 1.0 {
                let remaining = goal.targetAmount - goal.currentAmount
                results.append(ProactiveItem(
                    id: UUID(), type: .goalOffTrack, severity: .warning,
                    title: "\"\(goal.name)\" Overdue",
                    summary: "\(fmtDecimal(remaining)) still needed. Deadline has passed.",
                    signals: ["goal:\(goal.name)", "overdue"],
                    createdAt: Date(), updatedAt: Date(),
                    action: ProactiveAction(label: "Contribute", icon: "plus.circle.fill", kind: .openChat),
                    dedupKey: "goal_overdue_\(goal.id.uuidString.prefix(8))"
                ))
            }
        }

        return results
    }

    // MARK: - Uncategorized Reminder

    private func generateUncategorizedReminder(context: ModelContext) -> [ProactiveItem] {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!

        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
        )
        guard let txns = try? context.fetch(descriptor) else { return [] }
        let uncategorized = txns.filter { $0.category == nil }
        guard uncategorized.count >= 3 else { return [] }

        let total = uncategorized.reduce(Decimal.zero) { $0 + $1.amount }
        return [ProactiveItem(
            id: UUID(), type: .uncategorizedReminder, severity: .info,
            title: "\(uncategorized.count) Uncategorized",
            summary: "\(uncategorized.count) transactions (\(fmtDecimal(total))) need categories.",
            signals: ["count:\(uncategorized.count)"],
            createdAt: Date(), updatedAt: Date(),
            action: ProactiveAction(label: "Cleanup", icon: "tag.fill",
                                    kind: .startWorkflow(.cleanupUncategorized)),
            dedupKey: "uncategorized_\(uncategorized.count / 5)"
        )]
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

    private func fmtDecimal(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }

    // MARK: - Dismissed Keys Persistence

    private func loadDismissedKeys() {
        if let array = UserDefaults.standard.stringArray(forKey: dismissedKeysStorageKey) {
            dismissedKeys = Set(array)
        }
    }

    private func saveDismissedKeys() {
        UserDefaults.standard.set(Array(dismissedKeys), forKey: dismissedKeysStorageKey)
    }
}
