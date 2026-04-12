import Foundation
import SwiftData

// ============================================================
// MARK: - AI Optimization Layer
// ============================================================
//
// Financial optimization engine that turns raw data into
// practical, explainable recommendations and plans.
//
// Builds on existing engines:
//   - AISafeToSpend -- daily/weekly allowances, affordability
//   - AIBudgetRescue -- 80% threshold activation
//   - Subscription queries -- recurring detection
//   - Goal queries -- savings pace, deadlines
//
// macOS Centmond: @Observable, ModelContext, Decimal amounts.
// Replaces Store/GoalManager/SubscriptionEngine with FetchDescriptor.
//
// ============================================================

// MARK: - Optimization Model

enum OptimizationType: String, Codable, CaseIterable {
    case safeToSpend           = "safe_to_spend"
    case budgetRescue          = "budget_rescue"
    case budgetReallocation    = "budget_reallocation"
    case goalCatchUp           = "goal_catch_up"
    case subscriptionCleanup   = "subscription_cleanup"
    case leanMonthPlan         = "lean_month_plan"
    case paycheckAllocation    = "paycheck_allocation"
    case spendingFreeze        = "spending_freeze"
    case tradeoffComparison    = "tradeoff_comparison"

    var title: String {
        switch self {
        case .safeToSpend:        return "Safe to Spend"
        case .budgetRescue:       return "Budget Rescue"
        case .budgetReallocation: return "Budget Reallocation"
        case .goalCatchUp:        return "Goal Catch-Up"
        case .subscriptionCleanup:return "Subscription Cleanup"
        case .leanMonthPlan:      return "Lean Month Plan"
        case .paycheckAllocation: return "Paycheck Allocation"
        case .spendingFreeze:     return "Spending Freeze"
        case .tradeoffComparison: return "Compare Options"
        }
    }

    var icon: String {
        switch self {
        case .safeToSpend:        return "shield.checkered"
        case .budgetRescue:       return "lifepreserver.fill"
        case .budgetReallocation: return "arrow.left.arrow.right"
        case .goalCatchUp:        return "target"
        case .subscriptionCleanup:return "repeat"
        case .leanMonthPlan:      return "leaf.fill"
        case .paycheckAllocation: return "banknote.fill"
        case .spendingFreeze:     return "snowflake"
        case .tradeoffComparison: return "scale.3d"
        }
    }
}

struct OptimizationRecommendation: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    var amount: Decimal?
    var categoryRef: String?
    var goalRef: String?
    var subscriptionRef: String?
    var priority: Int
    var impact: Impact

    enum Impact: String {
        case high   = "high"
        case medium = "medium"
        case low    = "low"

        var icon: String {
            switch self {
            case .high:   return "exclamationmark.triangle.fill"
            case .medium: return "minus.circle.fill"
            case .low:    return "arrow.down.circle.fill"
            }
        }
    }
}

struct OptimizationScenario: Identifiable {
    let id = UUID()
    let label: String
    let description: String
    var projectedSavings: Decimal
    var timelineWeeks: Int?
    var riskLevel: String
    var impactedCategories: [String]
    var impactedGoals: [String]
    var pros: [String]
    var cons: [String]
}

struct OptimizationResult: Identifiable {
    let id = UUID()
    let type: OptimizationType
    let title: String
    var summary: String
    var recommendations: [OptimizationRecommendation]
    var projectedSavings: Decimal?
    var projectedImpact: String?
    var confidence: Double
    var assumptions: [String]
    let createdAt: Date
    var scenarios: [OptimizationScenario]
    var relatedCategories: [String]
    var relatedGoals: [String]
    var relatedSubscriptions: [String]
}

// MARK: - Optimization Engine

@MainActor @Observable
final class AIOptimizer {
    static let shared = AIOptimizer()

    var latestResult: OptimizationResult?
    private(set) var resultHistory: [OptimizationResult] = []

    private init() {}

    private let maxHistory = 10

    private func record(_ result: OptimizationResult) {
        let emphasized = applyModeEmphasis(result)
        latestResult = emphasized
        resultHistory.insert(emphasized, at: 0)
        if resultHistory.count > maxHistory { resultHistory.removeLast() }
    }

    private func applyModeEmphasis(_ result: OptimizationResult) -> OptimizationResult {
        let emphasis = AIAssistantModeManager.shared.optimizationEmphasis
        guard emphasis != .moderate else { return result }

        var modified = result
        let prefix = emphasis.prefix
        if !prefix.isEmpty {
            modified.summary = "\(prefix) \(result.summary)"
        }

        if emphasis == .optional && modified.confidence > 0.7 {
            modified.confidence = modified.confidence * 0.85
        }
        if emphasis == .strong && modified.confidence < 0.9 {
            modified.confidence = min(1.0, modified.confidence * 1.1)
        }

        return modified
    }

    // MARK: - Safe to Spend

    func safeToSpend(context: ModelContext) -> OptimizationResult {
        let sts = AISafeToSpend.shared.calculate(context: context)
        let budget = currentBudget(context: context)
        let spent = currentMonthSpending(context: context)

        var recs: [OptimizationRecommendation] = []
        var assumptions: [String] = [
            "Monthly budget: \(fmtDecimal(budget))",
            "Spending so far: \(fmtDecimal(spent))",
            "Days remaining: \(sts.daysLeftInMonth)"
        ]

        recs.append(OptimizationRecommendation(
            title: "Daily allowance: \(fmtDecimal(sts.trueAllowance))",
            detail: "Conservative estimate after reserving for goals.",
            amount: sts.trueAllowance,
            priority: 0, impact: .high
        ))

        recs.append(OptimizationRecommendation(
            title: "Weekly budget: \(fmtDecimal(sts.weeklyAllowance))",
            detail: "\(fmtDecimal(sts.weeklyAllowance)) for the next \(min(7, sts.daysLeftInMonth)) days.",
            amount: sts.weeklyAllowance,
            priority: 1, impact: .medium
        ))

        if sts.goalReserve > 0 {
            recs.append(OptimizationRecommendation(
                title: "\(fmtDecimal(sts.goalReserve)) reserved for goals",
                detail: "Monthly savings needed to keep active goals on track.",
                amount: sts.goalReserve,
                priority: 3, impact: .medium
            ))
            assumptions.append("Goal reserve: \(fmtDecimal(sts.goalReserve))/month")
        }

        if !sts.isOnTrack {
            let overBy = sts.projectedMonthEnd - budget
            recs.append(OptimizationRecommendation(
                title: "Projected overspend: \(fmtDecimal(overBy))",
                detail: "At current pace, you'll exceed budget.",
                amount: overBy,
                priority: 0, impact: .high
            ))
        }

        if sts.survivalDays < sts.daysLeftInMonth && sts.survivalDays > 0 {
            recs.append(OptimizationRecommendation(
                title: "Budget runs out in \(sts.survivalDays) days",
                detail: "At current spending rate, budget exhausts before month end.",
                priority: 0, impact: .high
            ))
        }

        let summary = sts.isOnTrack
            ? "You can safely spend \(fmtDecimal(sts.trueAllowance))/day (\(fmtDecimal(sts.weeklyAllowance))/week). You're on track."
            : "Spending is ahead of pace. Safe daily limit: \(fmtDecimal(sts.trueAllowance)). Consider reducing discretionary spending."

        let result = OptimizationResult(
            type: .safeToSpend, title: "Safe to Spend",
            summary: summary,
            recommendations: recs.sorted { $0.priority < $1.priority },
            projectedSavings: nil,
            projectedImpact: sts.isOnTrack ? "On track to finish within budget" : "Risk of exceeding budget",
            confidence: budget > 0 ? 0.8 : 0.5,
            assumptions: assumptions, createdAt: Date(),
            scenarios: [], relatedCategories: [], relatedGoals: [], relatedSubscriptions: []
        )
        record(result)
        return result
    }

    // MARK: - Budget Rescue

    func budgetRescue(context: ModelContext) -> OptimizationResult {
        let cal = Calendar.current
        let now = Date()
        let budget = currentBudget(context: context)
        let spent = currentMonthSpending(context: context)
        let remaining = budget - spent
        let dayOfMonth = cal.component(.day, from: now)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let daysLeft = max(1, daysInMonth - dayOfMonth)

        let catSpending = categorySpending(context: context)
        let essentialKeys = Set(["rent", "bills", "health", "transport", "groceries"])
        let discretionary = catSpending.filter { !essentialKeys.contains($0.key.lowercased()) }
            .sorted { NSDecimalNumber(decimal: $0.value).doubleValue > NSDecimalNumber(decimal: $1.value).doubleValue }

        var recs: [OptimizationRecommendation] = []
        var totalPotentialSavings: Decimal = 0
        let spentPct = budget > 0 ? Int(NSDecimalNumber(decimal: spent * 100 / budget).doubleValue) : 0
        var assumptions: [String] = [
            "Budget: \(fmtDecimal(budget))",
            "Spent: \(fmtDecimal(spent)) (\(spentPct)%)",
            "Days left: \(daysLeft)"
        ]

        let dailyLimit = remaining > 0 ? remaining / Decimal(daysLeft) : Decimal(0)
        recs.append(OptimizationRecommendation(
            title: "Strict daily limit: \(fmtDecimal(dailyLimit))",
            detail: "Maximum daily spending to stay within remaining budget.",
            amount: dailyLimit, priority: 0, impact: .high
        ))

        for (idx, (catName, catAmount)) in discretionary.prefix(4).enumerated() {
            let reduction = catAmount * Decimal(30) / Decimal(100)
            if reduction > 5 {
                totalPotentialSavings += reduction
                recs.append(OptimizationRecommendation(
                    title: "Reduce \(catName) by \(fmtDecimal(reduction))",
                    detail: "Currently \(fmtDecimal(catAmount)) this month. Cut ~30% for the rest of the month.",
                    amount: reduction, categoryRef: catName,
                    priority: idx + 1, impact: reduction > 20 ? .high : .medium
                ))
            }
        }

        let goalReserve = goalMonthlyReserve(context: context)
        if goalReserve > 0 && remaining < 0 {
            recs.append(OptimizationRecommendation(
                title: "Pause goal contributions: frees \(fmtDecimal(goalReserve))/mo",
                detail: "Temporarily pause savings goals to recover budget.",
                amount: goalReserve, priority: 8, impact: goalReserve > 50 ? .high : .medium
            ))
            totalPotentialSavings += goalReserve
        }

        let overBy = max(Decimal(0), spent - budget)
        let severity = budget > 0 ? (spent > budget ? "over budget" : "\(spentPct)% used") : "no budget set"
        let summary = remaining >= 0
            ? "Budget is tight (\(severity)). Cut \(fmtDecimal(totalPotentialSavings)) by adjusting categories."
            : "Over budget by \(fmtDecimal(overBy)). Strict mode: \(fmtDecimal(dailyLimit))/day."

        let result = OptimizationResult(
            type: .budgetRescue, title: "Budget Rescue Plan",
            summary: summary,
            recommendations: recs.sorted { $0.priority < $1.priority },
            projectedSavings: totalPotentialSavings,
            projectedImpact: totalPotentialSavings > 0 ? "Could recover \(fmtDecimal(totalPotentialSavings)) this month" : nil,
            confidence: budget > 0 ? 0.75 : 0.4,
            assumptions: assumptions, createdAt: Date(),
            scenarios: [], relatedCategories: discretionary.prefix(4).map(\.key),
            relatedGoals: [], relatedSubscriptions: []
        )
        record(result)
        return result
    }

    // MARK: - Goal Catch-Up

    func goalCatchUp(context: ModelContext) -> OptimizationResult {
        let activeStatus = GoalStatus.active
        let descriptor = FetchDescriptor<Goal>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        let goals = (try? context.fetch(descriptor)) ?? []
        let behind = goals.filter { g in
            guard let target = g.targetDate else { return false }
            return target < Date() && g.progressPercentage < 1.0
        }

        var recs: [OptimizationRecommendation] = []
        var assumptions: [String] = [
            "Active goals: \(goals.count)",
            "Behind/overdue: \(behind.count)"
        ]

        var totalRequired: Decimal = 0

        for (idx, goal) in behind.prefix(5).enumerated() {
            let remaining = goal.targetAmount - goal.currentAmount
            let monthly = goal.monthlyContribution ?? remaining
            totalRequired += monthly

            let pct = Int(goal.progressPercentage * 100)
            recs.append(OptimizationRecommendation(
                title: "\(goal.name): \(fmtDecimal(monthly))/month needed",
                detail: "Overdue -- \(pct)% done, \(fmtDecimal(remaining)) remaining.",
                amount: monthly, goalRef: goal.name,
                priority: idx, impact: .high
            ))
        }

        if behind.count >= 2 {
            recs.append(OptimizationRecommendation(
                title: "Focus on \"\(behind[0].name)\" first",
                detail: "Concentrate contributions on the most urgent goal.",
                goalRef: behind[0].name,
                priority: behind.count, impact: .medium
            ))
        }

        let budget = currentBudget(context: context)
        let spent = currentMonthSpending(context: context)
        let budgetRemaining = budget - spent
        if totalRequired > 0 && budget > 0 && totalRequired > budgetRemaining {
            recs.append(OptimizationRecommendation(
                title: "Goal funding exceeds remaining budget",
                detail: "Need \(fmtDecimal(totalRequired))/month but only \(fmtDecimal(max(0, budgetRemaining))) remains.",
                amount: totalRequired - max(0, budgetRemaining),
                priority: 0, impact: .high
            ))
        }

        let summary = behind.isEmpty
            ? "All goals are on track. Keep it up!"
            : "\(behind.count) goal(s) need attention. Total catch-up: \(fmtDecimal(totalRequired))/month."

        let result = OptimizationResult(
            type: .goalCatchUp, title: "Goal Catch-Up Plan",
            summary: summary,
            recommendations: recs.sorted { $0.priority < $1.priority },
            projectedSavings: nil,
            projectedImpact: behind.isEmpty ? "All goals on track" : "Close \(behind.count) gap(s)",
            confidence: goals.isEmpty ? 0.3 : 0.7,
            assumptions: assumptions, createdAt: Date(),
            scenarios: [], relatedCategories: [],
            relatedGoals: behind.map(\.name), relatedSubscriptions: []
        )
        record(result)
        return result
    }

    // MARK: - Subscription Cleanup

    func subscriptionCleanup(context: ModelContext) -> OptimizationResult {
        let optResult = AISubscriptionOptimizer.shared.analyze(context: context)

        var recs: [OptimizationRecommendation] = []
        for (idx, rec) in optResult.recommendations.enumerated() {
            recs.append(OptimizationRecommendation(
                title: "\(rec.subscriptionName): \(fmtDecimal(rec.potentialSaving))/mo",
                detail: rec.reason,
                amount: rec.potentialSaving, subscriptionRef: rec.subscriptionName,
                priority: idx, impact: rec.potentialSaving > 15 ? .high : .medium
            ))
        }

        let result = OptimizationResult(
            type: .subscriptionCleanup, title: "Subscription Cleanup",
            summary: optResult.summary(),
            recommendations: recs,
            projectedSavings: optResult.potentialSavings,
            projectedImpact: optResult.potentialSavings > 0 ? "\(fmtDecimal(optResult.potentialSavings))/month" : nil,
            confidence: 0.7,
            assumptions: ["Monthly total: \(fmtDecimal(optResult.totalMonthlyCost))"],
            createdAt: Date(),
            scenarios: [], relatedCategories: [], relatedGoals: [],
            relatedSubscriptions: optResult.recommendations.map(\.subscriptionName)
        )
        record(result)
        return result
    }

    // MARK: - Lean Month Plan

    func leanMonthPlan(context: ModelContext, availableFunds: Decimal? = nil) -> OptimizationResult {
        let budget = currentBudget(context: context)
        let funds = availableFunds ?? budget
        let catSpending = categorySpending(context: context)

        let tiers: [(name: String, keys: [String], pctOfFunds: Int)] = [
            ("Housing",      ["Rent"],                                30),
            ("Groceries",    ["Groceries"],                           15),
            ("Utilities",    ["Bills"],                               10),
            ("Transport",    ["Transport"],                            8),
            ("Health",       ["Health"],                                5),
            ("Debt minimum", [],                                       5),
            ("Goals",        [],                                      10),
            ("Discretionary",["Dining", "Shopping", "Education"],     17),
        ]

        var recs: [OptimizationRecommendation] = []
        var allocated: Decimal = 0
        var assumptions: [String] = [
            "Available funds: \(fmtDecimal(funds))",
            "Lean allocation mode: essentials first"
        ]

        for (idx, tier) in tiers.enumerated() {
            let tierAmount = funds * Decimal(tier.pctOfFunds) / 100
            allocated += tierAmount

            let currentSpend = tier.keys.reduce(Decimal.zero) { $0 + (catSpending[$1] ?? 0) }
            let vs = currentSpend > 0 ? " (current: \(fmtDecimal(currentSpend)))" : ""

            recs.append(OptimizationRecommendation(
                title: "\(tier.name): \(fmtDecimal(tierAmount))",
                detail: "\(tier.pctOfFunds)% of available funds\(vs).",
                amount: tierAmount, categoryRef: tier.keys.first,
                priority: idx, impact: idx < 4 ? .high : (idx < 6 ? .medium : .low)
            ))
        }

        let buffer = funds - allocated
        if buffer > 0 {
            recs.append(OptimizationRecommendation(
                title: "Emergency buffer: \(fmtDecimal(buffer))",
                detail: "Unallocated reserve for unexpected expenses.",
                amount: buffer, priority: tiers.count, impact: .medium
            ))
        }

        let result = OptimizationResult(
            type: .leanMonthPlan, title: "Lean Month Plan",
            summary: "Essentials-first allocation of \(fmtDecimal(funds)).",
            recommendations: recs,
            projectedSavings: nil,
            projectedImpact: "Covers essentials with \(fmtDecimal(buffer)) buffer",
            confidence: funds > 0 ? 0.7 : 0.3,
            assumptions: assumptions, createdAt: Date(),
            scenarios: [], relatedCategories: tiers.flatMap(\.keys),
            relatedGoals: [], relatedSubscriptions: []
        )
        record(result)
        return result
    }

    // MARK: - Paycheck Allocation

    func paycheckAllocation(context: ModelContext, paycheckAmount: Decimal) -> OptimizationResult {
        let cal = Calendar.current
        let now = Date()
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let dayOfMonth = cal.component(.day, from: now)
        let daysLeft = max(1, daysInMonth - dayOfMonth)

        let goalMonthly = goalMonthlyReserve(context: context)
        let goalProrated = goalMonthly * Decimal(daysLeft) / Decimal(daysInMonth)

        let budget = currentBudget(context: context)
        let spent = currentMonthSpending(context: context)
        let budgetGap = max(Decimal(0), spent - budget)

        var recs: [OptimizationRecommendation] = []
        var remaining = paycheckAmount
        let assumptions = ["Paycheck: \(fmtDecimal(paycheckAmount))", "Days left in month: \(daysLeft)"]

        if budgetGap > 0 && remaining > 0 {
            let recoveryAlloc = min(remaining, budgetGap)
            recs.append(OptimizationRecommendation(
                title: "Budget recovery: \(fmtDecimal(recoveryAlloc))",
                detail: "Cover the \(fmtDecimal(budgetGap)) overspend gap.",
                amount: recoveryAlloc, priority: 0, impact: .high
            ))
            remaining -= recoveryAlloc
        }

        let essentialAlloc = min(remaining, budget * Decimal(50) / 100 * Decimal(daysLeft) / Decimal(daysInMonth))
        if essentialAlloc > 0 {
            recs.append(OptimizationRecommendation(
                title: "Essential spending: \(fmtDecimal(essentialAlloc))",
                detail: "Food, transport, basics for the next \(daysLeft) days.",
                amount: essentialAlloc, priority: 1, impact: .high
            ))
            remaining -= essentialAlloc
        }

        let goalAlloc = min(remaining, goalProrated)
        if goalAlloc > 0 {
            recs.append(OptimizationRecommendation(
                title: "Goal contributions: \(fmtDecimal(goalAlloc))",
                detail: "Prorated savings for active goals.",
                amount: goalAlloc, priority: 2, impact: .medium
            ))
            remaining -= goalAlloc
        }

        if remaining > 0 {
            let dailyFlex = daysLeft > 0 ? remaining / Decimal(daysLeft) : remaining
            recs.append(OptimizationRecommendation(
                title: "Discretionary: \(fmtDecimal(remaining))",
                detail: "Available for flexible spending (\(fmtDecimal(dailyFlex))/day).",
                amount: remaining, priority: 3, impact: .low
            ))
        }

        let result = OptimizationResult(
            type: .paycheckAllocation, title: "Paycheck Allocation",
            summary: "Allocated \(fmtDecimal(paycheckAmount)): essentials \(fmtDecimal(essentialAlloc)), goals \(fmtDecimal(goalAlloc)), flex \(fmtDecimal(remaining)).",
            recommendations: recs,
            projectedSavings: goalAlloc,
            projectedImpact: "Covers \(daysLeft) days with \(fmtDecimal(remaining)) discretionary",
            confidence: 0.7,
            assumptions: assumptions, createdAt: Date(),
            scenarios: [], relatedCategories: [], relatedGoals: [], relatedSubscriptions: []
        )
        record(result)
        return result
    }

    // MARK: - Spending Freeze

    func spendingFreeze(context: ModelContext, durationDays: Int = 7) -> OptimizationResult {
        let cal = Calendar.current
        let now = Date()
        let dayOfMonth = max(1, cal.component(.day, from: now))
        let catSpending = categorySpending(context: context)
        let essentialKeys = Set(["Rent", "Bills", "Health", "Transport", "Groceries"])

        let discretionary = catSpending.filter { !essentialKeys.contains($0.key) }
        let dailyDiscretionary = discretionary.values.reduce(Decimal.zero, +) / Decimal(dayOfMonth)
        let projectedFreezeSavings = dailyDiscretionary * Decimal(durationDays)

        var recs: [OptimizationRecommendation] = []

        recs.append(OptimizationRecommendation(
            title: "Freeze discretionary: save ~\(fmtDecimal(projectedFreezeSavings))",
            detail: "No dining, shopping, entertainment for \(durationDays) days.",
            amount: projectedFreezeSavings, priority: 0, impact: .high
        ))

        let essentialDaily = essentialKeys.reduce(Decimal.zero) { $0 + (catSpending[$1] ?? 0) } / Decimal(dayOfMonth)
        recs.append(OptimizationRecommendation(
            title: "Essential-only: \(fmtDecimal(essentialDaily))/day",
            detail: "Groceries, transport, health only during freeze period.",
            amount: essentialDaily, priority: 1, impact: .medium
        ))

        let result = OptimizationResult(
            type: .spendingFreeze, title: "\(durationDays)-Day Spending Freeze",
            summary: "Freeze discretionary spending for \(durationDays) days. Estimated savings: \(fmtDecimal(projectedFreezeSavings)).",
            recommendations: recs,
            projectedSavings: projectedFreezeSavings,
            projectedImpact: "Save \(fmtDecimal(projectedFreezeSavings)) over \(durationDays) days",
            confidence: 0.6,
            assumptions: ["Based on current month's daily averages", "Duration: \(durationDays) days"],
            createdAt: Date(),
            scenarios: [], relatedCategories: Array(discretionary.keys),
            relatedGoals: [], relatedSubscriptions: []
        )
        record(result)
        return result
    }

    // MARK: - Quick Affordability

    func canAfford(amount: Decimal, context: ModelContext) -> OptimizationResult {
        let aff = AISafeToSpend.shared.canAfford(amount: amount, context: context)
        let sts = AISafeToSpend.shared.calculate(context: context)

        var recs: [OptimizationRecommendation] = []

        recs.append(OptimizationRecommendation(
            title: aff.canAfford ? "Yes -- \(impactLabel(aff.impact)) impact" : "Not recommended",
            detail: aff.message,
            amount: amount, priority: 0,
            impact: aff.impact == .minimal ? .low : (aff.impact == .moderate ? .medium : .high)
        ))

        recs.append(OptimizationRecommendation(
            title: "After purchase: \(fmtDecimal(aff.remainingAfter)) remaining",
            detail: aff.remainingAfter < 0 ? "Would put you over budget." : "Still within budget.",
            amount: aff.remainingAfter, priority: 1,
            impact: aff.remainingAfter < 0 ? .high : .low
        ))

        if !aff.canAfford {
            let trueDouble = NSDecimalNumber(decimal: sts.trueAllowance).doubleValue
            let daysNeeded = trueDouble > 0 ? max(1, Int(NSDecimalNumber(decimal: amount).doubleValue / trueDouble)) : 999
            recs.append(OptimizationRecommendation(
                title: "Alternative: wait \(daysNeeded) day(s)",
                detail: "Save \(fmtDecimal(sts.trueAllowance))/day to afford this.",
                amount: sts.trueAllowance, priority: 2, impact: .medium
            ))
        }

        let result = OptimizationResult(
            type: .safeToSpend, title: "Can I Afford \(fmtDecimal(amount))?",
            summary: aff.message,
            recommendations: recs,
            projectedSavings: nil,
            projectedImpact: aff.canAfford ? "Affordable with \(impactLabel(aff.impact)) impact" : "Exceeds safe spending limit",
            confidence: 0.8,
            assumptions: ["Daily allowance: \(fmtDecimal(sts.trueAllowance))", "Remaining budget: \(fmtDecimal(sts.remainingBudget))"],
            createdAt: Date(),
            scenarios: [], relatedCategories: [], relatedGoals: [], relatedSubscriptions: []
        )
        record(result)
        return result
    }

    // MARK: - Helpers

    private func currentBudget(context: ModelContext) -> Decimal {
        let cal = Calendar.current
        let year = cal.component(.year, from: Date())
        let month = cal.component(.month, from: Date())
        let descriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        return (try? context.fetch(descriptor).first)?.amount ?? 0
    }

    private func currentMonthSpending(context: ModelContext) -> Decimal {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
        )
        guard let txns = try? context.fetch(descriptor) else { return 0 }
        return txns.filter { BalanceService.isSpendingExpense($0) }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func categorySpending(context: ModelContext) -> [String: Decimal] {
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
        )
        guard let txns = try? context.fetch(descriptor) else { return [:] }
        var spending: [String: Decimal] = [:]
        for txn in txns where BalanceService.isSpendingExpense(txn) {
            let catName = txn.category?.name ?? "Other"
            spending[catName, default: 0] += txn.amount
        }
        return spending
    }

    private func goalMonthlyReserve(context: ModelContext) -> Decimal {
        let activeStatus = GoalStatus.active
        let descriptor = FetchDescriptor<Goal>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        guard let goals = try? context.fetch(descriptor) else { return 0 }
        return goals.compactMap(\.monthlyContribution).reduce(Decimal.zero, +)
    }

    private func fmtDecimal(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        let isNeg = d < 0
        let str = String(format: "$%.2f", abs(d))
        return isNeg ? "-\(str)" : str
    }

    private func impactLabel(_ impact: AffordabilityResult.Impact) -> String {
        switch impact {
        case .minimal:  return "minimal"
        case .moderate: return "moderate"
        case .severe:   return "severe"
        }
    }
}
