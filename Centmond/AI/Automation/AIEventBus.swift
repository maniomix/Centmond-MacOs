import Foundation
import SwiftData

// ============================================================
// MARK: - AI Event Bus
// ============================================================
//
// Monitors app events and dispatches them to watch rules
// and the insight engine. Acts as the nervous system for
// proactive AI features.
//
// macOS Centmond: @Observable instead of ObservableObject,
// ModelContext instead of Store, amounts in dollars (Decimal).
//
// ============================================================

struct AIEvent: Identifiable {
    let id = UUID()
    let type: EventType
    let timestamp: Date
    let payload: [String: String]

    enum EventType: String, Codable {
        case transactionAdded
        case transactionEdited
        case transactionDeleted
        case budgetSet
        case budgetThreshold50
        case budgetThreshold80
        case budgetExceeded
        case categoryBudgetExceeded
        case goalCreated
        case goalContribution
        case goalMilestone25
        case goalMilestone50
        case goalMilestone75
        case goalCompleted
        case subscriptionAdded
        case subscriptionRenewing
        case subscriptionCancelled
        case subscriptionPriceChange
        case balanceUpdated
        case transferCompleted
        case recurringAdded
        case recurringCancelled
        case dailyCheck
        case weeklyCheck
        case monthStart
        case monthEnd
    }

    init(type: EventType, payload: [String: String] = [:]) {
        self.type = type
        self.timestamp = Date()
        self.payload = payload
    }
}

struct AIWatchRule: Identifiable, Codable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var trigger: WatchTrigger
    var condition: WatchCondition
    var action: WatchAction

    init(name: String, trigger: WatchTrigger, condition: WatchCondition, action: WatchAction) {
        self.id = UUID()
        self.name = name
        self.isEnabled = true
        self.trigger = trigger
        self.condition = condition
        self.action = action
    }

    enum WatchTrigger: String, Codable, CaseIterable {
        case anyExpense
        case categoryExpense
        case budgetThreshold
        case dailySpending
        case weeklySpending
        case goalProgress
        case subscriptionRenewal
        case unusualExpense
    }

    struct WatchCondition: Codable {
        var category: String?
        var thresholdAmount: Double?
        var thresholdPercent: Double?
        var multiplier: Double?
        var daysBefore: Int?
    }

    enum WatchAction: String, Codable, CaseIterable {
        case notification
        case insightBanner
        case both
    }
}

@MainActor @Observable
final class AIEventBus {
    static let shared = AIEventBus()

    private(set) var recentEvents: [AIEvent] = []
    var watchRules: [AIWatchRule] = []
    private(set) var triggeredAlerts: [TriggeredAlert] = []

    private let rulesKey = "ai.watchRules"
    private let maxEvents = 100

    struct TriggeredAlert: Identifiable {
        let id = UUID()
        let rule: AIWatchRule
        let event: AIEvent
        let message: String
        let timestamp: Date
    }

    private init() {
        loadRules()
    }

    // MARK: - Dispatch Events

    func post(_ event: AIEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > maxEvents {
            recentEvents = Array(recentEvents.prefix(maxEvents))
        }
        evaluateRules(for: event)
    }

    func postTransactionAdded(amount: Double, category: String, note: String, type: String) {
        post(AIEvent(type: .transactionAdded, payload: [
            "amount": String(format: "%.2f", amount),
            "category": category,
            "note": note,
            "transactionType": type
        ]))
    }

    func postBudgetThreshold(ratio: Double, spent: Decimal, budget: Decimal) {
        let eventType: AIEvent.EventType
        if ratio >= 1.0 {
            eventType = .budgetExceeded
        } else if ratio >= 0.8 {
            eventType = .budgetThreshold80
        } else if ratio >= 0.5 {
            eventType = .budgetThreshold50
        } else {
            return
        }

        post(AIEvent(type: eventType, payload: [
            "ratio": String(format: "%.2f", ratio),
            "spent": fmtDecimal(spent),
            "budget": fmtDecimal(budget)
        ]))
    }

    func postGoalMilestone(goalName: String, progress: Double) {
        let eventType: AIEvent.EventType
        if progress >= 1.0 {
            eventType = .goalCompleted
        } else if progress >= 0.75 {
            eventType = .goalMilestone75
        } else if progress >= 0.5 {
            eventType = .goalMilestone50
        } else if progress >= 0.25 {
            eventType = .goalMilestone25
        } else {
            return
        }

        post(AIEvent(type: eventType, payload: [
            "goalName": goalName,
            "progress": String(format: "%.0f", progress * 100)
        ]))
    }

    // MARK: - Watch Rules Management

    func addRule(_ rule: AIWatchRule) {
        watchRules.append(rule)
        saveRules()
    }

    func updateRule(_ rule: AIWatchRule) {
        if let idx = watchRules.firstIndex(where: { $0.id == rule.id }) {
            watchRules[idx] = rule
            saveRules()
        }
    }

    func deleteRule(_ id: UUID) {
        watchRules.removeAll { $0.id == id }
        saveRules()
    }

    func toggleRule(_ id: UUID) {
        if let idx = watchRules.firstIndex(where: { $0.id == id }) {
            watchRules[idx].isEnabled.toggle()
            saveRules()
        }
    }

    func setupDefaults() {
        guard watchRules.isEmpty else { return }

        watchRules = [
            AIWatchRule(
                name: "Budget 80% warning",
                trigger: .budgetThreshold,
                condition: .init(thresholdPercent: 0.8),
                action: .both
            ),
            AIWatchRule(
                name: "Large expense alert",
                trigger: .unusualExpense,
                condition: .init(multiplier: 3.0),
                action: .insightBanner
            ),
            AIWatchRule(
                name: "Daily spending limit",
                trigger: .dailySpending,
                condition: .init(thresholdAmount: 100.0),
                action: .insightBanner
            ),
            AIWatchRule(
                name: "Subscription renewal reminder",
                trigger: .subscriptionRenewal,
                condition: .init(daysBefore: 3),
                action: .notification
            )
        ]
        saveRules()
    }

    // MARK: - Rule Evaluation

    private func evaluateRules(for event: AIEvent) {
        for rule in watchRules where rule.isEnabled {
            if let message = ruleMatches(rule, event: event) {
                let alert = TriggeredAlert(
                    rule: rule,
                    event: event,
                    message: message,
                    timestamp: Date()
                )
                triggeredAlerts.insert(alert, at: 0)

                if rule.action == .insightBanner || rule.action == .both {
                    AIInsightEngine.shared.eventInsight = AIInsight(
                        type: .patternDetected,
                        title: rule.name,
                        body: message,
                        severity: .warning
                    )
                }
            }
        }
    }

    private func ruleMatches(_ rule: AIWatchRule, event: AIEvent) -> String? {
        switch rule.trigger {
        case .anyExpense:
            guard event.type == .transactionAdded,
                  event.payload["transactionType"] == "expense" else { return nil }
            let amount = event.payload["amount"] ?? "0"
            return "New expense: $\(amount) for \(event.payload["note"] ?? "unknown")"

        case .categoryExpense:
            guard event.type == .transactionAdded,
                  let cat = event.payload["category"],
                  cat == rule.condition.category else { return nil }
            let amount = event.payload["amount"] ?? "0"
            return "\(cat.capitalized) expense: $\(amount)"

        case .budgetThreshold:
            guard event.type == .budgetThreshold80 || event.type == .budgetExceeded else { return nil }
            let ratio = Double(event.payload["ratio"] ?? "0") ?? 0
            if let threshold = rule.condition.thresholdPercent, ratio >= threshold {
                return "Budget is at \(Int(ratio * 100))%"
            }
            return nil

        case .dailySpending:
            guard event.type == .dailyCheck else { return nil }
            let dailySpent = Double(event.payload["dailySpent"] ?? "0") ?? 0
            if let threshold = rule.condition.thresholdAmount, dailySpent > threshold {
                return String(format: "Daily spending $%.2f exceeds your $%.2f limit", dailySpent, threshold)
            }
            return nil

        case .weeklySpending:
            guard event.type == .weeklyCheck else { return nil }
            let weeklySpent = Double(event.payload["weeklySpent"] ?? "0") ?? 0
            if let threshold = rule.condition.thresholdAmount, weeklySpent > threshold {
                return String(format: "Weekly spending $%.2f exceeds your $%.2f limit", weeklySpent, threshold)
            }
            return nil

        case .goalProgress:
            guard event.type == .goalMilestone50 || event.type == .goalMilestone75 ||
                  event.type == .goalCompleted else { return nil }
            let name = event.payload["goalName"] ?? "Your goal"
            let pct = event.payload["progress"] ?? "?"
            return "\"\(name)\" reached \(pct)%!"

        case .subscriptionRenewal:
            guard event.type == .subscriptionRenewing else { return nil }
            let name = event.payload["subscriptionName"] ?? "A subscription"
            let days = event.payload["daysUntil"] ?? "?"
            return "\(name) renews in \(days) day(s)"

        case .unusualExpense:
            guard event.type == .transactionAdded,
                  event.payload["transactionType"] == "expense" else { return nil }
            let amount = Double(event.payload["amount"] ?? "0") ?? 0
            let avg = Double(event.payload["categoryAverage"] ?? "0") ?? 0
            if let mult = rule.condition.multiplier, avg > 0, amount > avg * mult {
                return String(format: "Unusual expense: $%.2f is %.0fx your average", amount, amount / avg)
            }
            return nil
        }
    }

    func clearAlerts() {
        triggeredAlerts.removeAll()
    }

    // MARK: - Periodic Checks

    func runDailyCheck(context: ModelContext) {
        let today = Date()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: today)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!

        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= dayStart && $0.date < dayEnd }
        )
        let txns = (try? context.fetch(descriptor)) ?? []
        let dailySpent = txns.filter { BalanceService.isSpendingExpense($0) }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let dailyDouble = NSDecimalNumber(decimal: dailySpent).doubleValue

        post(AIEvent(type: .dailyCheck, payload: [
            "dailySpent": String(format: "%.2f", dailyDouble),
            "transactionCount": "\(txns.count)"
        ]))

        // Check budget thresholds
        let year = cal.component(.year, from: today)
        let month = cal.component(.month, from: today)
        let budgetDescriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        if let budget = try? context.fetch(budgetDescriptor).first?.amount, budget > 0 {
            let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: today))!
            let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
            let monthDescriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { !$0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
            )
            let monthTxns = (try? context.fetch(monthDescriptor)) ?? []
            let spent = monthTxns.filter { BalanceService.isSpendingExpense($0) }
                .reduce(Decimal.zero) { $0 + $1.amount }
            let ratio = NSDecimalNumber(decimal: spent).doubleValue / NSDecimalNumber(decimal: budget).doubleValue
            postBudgetThreshold(ratio: ratio, spent: spent, budget: budget)
        }
    }

    func runWeeklyCheck(context: ModelContext) {
        let now = Date()
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) else { return }

        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= weekAgo && $0.date <= now }
        )
        let txns = (try? context.fetch(descriptor)) ?? []
        let weeklySpent = txns.filter { BalanceService.isSpendingExpense($0) }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let weeklyDouble = NSDecimalNumber(decimal: weeklySpent).doubleValue

        post(AIEvent(type: .weeklyCheck, payload: [
            "weeklySpent": String(format: "%.2f", weeklyDouble),
            "transactionCount": "\(txns.count)"
        ]))
    }

    // MARK: - Persistence

    private func loadRules() {
        if let data = UserDefaults.standard.data(forKey: rulesKey),
           let saved = try? JSONDecoder().decode([AIWatchRule].self, from: data) {
            watchRules = saved
        }
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(watchRules) {
            UserDefaults.standard.set(data, forKey: rulesKey)
        }
    }

    // MARK: - Helpers

    private func fmtDecimal(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }
}
