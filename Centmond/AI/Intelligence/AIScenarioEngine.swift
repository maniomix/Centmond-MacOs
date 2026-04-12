import Foundation
import SwiftData

// ============================================================
// MARK: - AI Scenario Engine
// ============================================================
//
// "What if" simulation engine. Takes hypothetical changes
// and projects their impact on budget, goals, and savings.
//
// Pure math — no LLM needed.
//
// macOS Centmond: @Observable instead of ObservableObject,
// ModelContext instead of Store, Decimal instead of cents.
//
// ============================================================

/// A scenario simulation result.
struct ScenarioResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let description: String
    let impacts: [Impact]
    let recommendation: String

    struct Impact: Identifiable, Equatable {
        let id = UUID()
        let area: String
        let currentValue: String
        let projectedValue: String
        let isPositive: Bool
    }
}

@MainActor @Observable
final class AIScenarioEngine {
    static let shared = AIScenarioEngine()

    private(set) var lastResult: ScenarioResult?

    private init() {}

    // MARK: - Scenarios

    /// "What if I save X more per month?"
    func simulateSaveMore(amount: Decimal, context: ModelContext) -> ScenarioResult {
        let month = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: month)
        let monthNum = cal.component(.month, from: month)

        let budgetDescriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == monthNum }
        )
        let budgetAmount = (try? context.fetch(budgetDescriptor).first)?.amount ?? 0
        let spent = monthSpending(context: context, month: month)
        let remaining = max(Decimal.zero, budgetAmount - spent)

        var impacts: [ScenarioResult.Impact] = []

        if budgetAmount > 0 {
            let newRemaining = remaining - amount
            impacts.append(ScenarioResult.Impact(
                area: "Monthly Budget",
                currentValue: "\(fmt(remaining)) remaining",
                projectedValue: "\(fmt(newRemaining)) remaining",
                isPositive: newRemaining >= 0
            ))
        }

        // Goal impact
        let activeStatus = GoalStatus.active
        let goalDescriptor = FetchDescriptor<Goal>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        if let goals = try? context.fetch(goalDescriptor) {
            for goal in goals {
                let leftToSave = goal.targetAmount - goal.currentAmount
                guard leftToSave > 0 else { continue }

                let currentMonthly = (goal.monthlyContribution ?? 0) > 0 ? goal.monthlyContribution! : leftToSave
                let newMonthly = currentMonthly + amount

                let currentMonths = currentMonthly > 0
                    ? NSDecimalNumber(decimal: leftToSave / currentMonthly).intValue : 999
                let newMonths = newMonthly > 0
                    ? NSDecimalNumber(decimal: leftToSave / newMonthly).intValue : 999

                if newMonths < currentMonths {
                    impacts.append(ScenarioResult.Impact(
                        area: "Goal: \(goal.name)",
                        currentValue: "\(currentMonths) months to complete",
                        projectedValue: "\(newMonths) months to complete",
                        isPositive: true
                    ))
                }
            }
        }

        // Yearly savings
        let yearlySavings = amount * 12
        impacts.append(ScenarioResult.Impact(
            area: "Annual Savings",
            currentValue: "Current pace",
            projectedValue: "+\(fmt(yearlySavings))/year extra",
            isPositive: true
        ))

        let recommendation: String
        if budgetAmount > 0 && remaining - amount < 0 {
            recommendation = "This would exceed your current budget. Consider increasing your budget or finding areas to cut."
        } else {
            recommendation = "Saving \(fmt(amount)) more monthly adds up to \(fmt(yearlySavings)) per year."
        }

        let result = ScenarioResult(
            title: "Save \(fmt(amount)) More",
            description: "Impact of saving an additional \(fmt(amount)) per month",
            impacts: impacts,
            recommendation: recommendation
        )
        lastResult = result
        return result
    }

    /// "What if I cut spending on X category by Y%?"
    func simulateCutCategory(category: String, percentCut: Int, context: ModelContext) -> ScenarioResult {
        let catSpending = categorySpendingByName(context: context, month: Date())
        let currentSpend = catSpending.first { $0.key.lowercased() == category.lowercased() }?.value ?? 0
        let savings = currentSpend * Decimal(percentCut) / 100
        let newSpend = currentSpend - savings

        var impacts: [ScenarioResult.Impact] = []

        impacts.append(ScenarioResult.Impact(
            area: "\(category) Spending",
            currentValue: fmt(currentSpend),
            projectedValue: fmt(newSpend),
            isPositive: true
        ))

        // Budget impact
        let month = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: month)
        let monthNum = cal.component(.month, from: month)
        let budgetDescriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == monthNum }
        )
        if let budgetAmount = try? context.fetch(budgetDescriptor).first?.amount, budgetAmount > 0 {
            let spent = monthSpending(context: context, month: month)
            let newSpent = spent - savings
            let budgetDouble = NSDecimalNumber(decimal: budgetAmount).doubleValue
            let spentPct = Int(NSDecimalNumber(decimal: spent).doubleValue / budgetDouble * 100)
            let newPct = Int(NSDecimalNumber(decimal: newSpent).doubleValue / budgetDouble * 100)
            impacts.append(ScenarioResult.Impact(
                area: "Total Budget Used",
                currentValue: "\(spentPct)%",
                projectedValue: "\(newPct)%",
                isPositive: true
            ))
        }

        // Yearly projection
        impacts.append(ScenarioResult.Impact(
            area: "Annual Savings",
            currentValue: "Current pace",
            projectedValue: "+\(fmt(savings * 12))/year",
            isPositive: true
        ))

        let result = ScenarioResult(
            title: "Cut \(category) by \(percentCut)%",
            description: "Impact of reducing \(category) spending by \(percentCut)%",
            impacts: impacts,
            recommendation: "Cutting \(category) by \(percentCut)% saves \(fmt(savings))/month. That's \(fmt(savings * 12)) per year."
        )
        lastResult = result
        return result
    }

    /// "What if I increase my budget to X?"
    func simulateBudgetChange(newBudget: Decimal, context: ModelContext) -> ScenarioResult {
        let month = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: month)
        let monthNum = cal.component(.month, from: month)

        let budgetDescriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == monthNum }
        )
        let currentBudget = (try? context.fetch(budgetDescriptor).first)?.amount ?? 0
        let spent = monthSpending(context: context, month: month)

        var impacts: [ScenarioResult.Impact] = []

        impacts.append(ScenarioResult.Impact(
            area: "Monthly Budget",
            currentValue: fmt(currentBudget),
            projectedValue: fmt(newBudget),
            isPositive: newBudget > currentBudget
        ))

        let currentRemaining = max(Decimal.zero, currentBudget - spent)
        let newRemaining = max(Decimal.zero, newBudget - spent)
        impacts.append(ScenarioResult.Impact(
            area: "Remaining This Month",
            currentValue: fmt(currentRemaining),
            projectedValue: fmt(newRemaining),
            isPositive: newRemaining > currentRemaining
        ))

        let diff = newBudget - currentBudget
        let recommendation: String
        if diff > 0 {
            recommendation = "Increasing budget by \(fmt(diff)) gives more breathing room but reduces potential savings."
        } else if diff < 0 {
            let absDiff = Decimal.zero - diff
            recommendation = "Reducing budget by \(fmt(absDiff)) is ambitious. Make sure it's realistic based on your spending patterns."
        } else {
            recommendation = "No change from current budget."
        }

        let result = ScenarioResult(
            title: "Budget to \(fmt(newBudget))",
            description: "Impact of changing your monthly budget",
            impacts: impacts,
            recommendation: recommendation
        )
        lastResult = result
        return result
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

    private func categorySpendingByName(context: ModelContext, month: Date) -> [String: Decimal] {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
        )
        guard let txns = try? context.fetch(descriptor) else { return [:] }

        var result: [String: Decimal] = [:]
        for t in txns where BalanceService.isSpendingExpense(t) {
            let name = t.category?.name ?? "Other"
            result[name, default: 0] += t.amount
        }
        return result
    }

    private func fmt(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }
}
