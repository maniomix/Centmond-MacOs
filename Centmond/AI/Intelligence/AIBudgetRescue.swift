import Foundation
import SwiftData

// ============================================================
// MARK: - AI Budget Rescue Mode
// ============================================================
//
// Activates when the user has used >80% of their monthly budget.
// Provides:
//   • Daily spending limit suggestion
//   • Top spending category alerts
//   • Category-specific reduction targets
//   • Quick actions (reduce category budget, skip non-essentials)
//
// Pure heuristic — no LLM call needed.
//
// macOS Centmond: @Observable instead of ObservableObject,
// ModelContext instead of Store, Decimal instead of cents.
//
// ============================================================

/// Rescue analysis result.
struct BudgetRescuePlan: Equatable {
    let isActive: Bool
    let budgetUsedPercent: Int
    let remainingBudget: Decimal
    let daysRemaining: Int
    let dailyLimit: Decimal
    let topCategory: String
    let topCategoryAmount: Decimal
    let reductionTargets: [ReductionTarget]
    let tips: [String]

    struct ReductionTarget: Equatable, Identifiable {
        let id = UUID()
        let category: String
        let currentSpend: Decimal
        let suggestedLimit: Decimal
        let savingsIfReduced: Decimal
    }
}

@MainActor @Observable
final class AIBudgetRescue {
    static let shared = AIBudgetRescue()

    private(set) var plan: BudgetRescuePlan?

    private let threshold = 0.80

    private init() {}

    func evaluate(context: ModelContext) {
        let month = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: month)
        let monthNum = cal.component(.month, from: month)

        let budgetDescriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == monthNum }
        )
        guard let budgetAmount = try? context.fetch(budgetDescriptor).first?.amount,
              budgetAmount > 0 else {
            plan = nil
            return
        }

        let spent = monthSpending(context: context, month: month)
        let budgetDouble = NSDecimalNumber(decimal: budgetAmount).doubleValue
        let spentDouble = NSDecimalNumber(decimal: spent).doubleValue
        let ratio = spentDouble / budgetDouble

        guard ratio >= threshold else {
            plan = nil
            return
        }

        let remaining = max(0, budgetAmount - spent)
        let dayOfMonth = cal.component(.day, from: month)
        let daysInMonth = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let daysRemaining = max(1, daysInMonth - dayOfMonth)
        let dailyLimit = remaining / Decimal(daysRemaining)

        // Category analysis
        let catTotals = categorySpendingByName(context: context, month: month)
        let sortedCats = catTotals.sorted { $0.value > $1.value }
        let topCategory = sortedCats.first?.key ?? "Unknown"
        let topCategoryAmount = sortedCats.first?.value ?? 0

        // Reduction targets: suggest 20% reduction for top 3 non-essential categories
        let essentialCategories = ["rent", "bills", "health"]
        let reductionTargets = sortedCats
            .filter { !essentialCategories.contains($0.key.lowercased()) }
            .prefix(3)
            .map { cat -> BudgetRescuePlan.ReductionTarget in
                let suggested = cat.value * Decimal(0.8)
                let savings = cat.value - suggested
                return BudgetRescuePlan.ReductionTarget(
                    category: cat.key,
                    currentSpend: cat.value,
                    suggestedLimit: suggested,
                    savingsIfReduced: savings
                )
            }

        // Tips based on situation
        var tips: [String] = []

        if ratio >= 1.0 {
            tips.append("You've exceeded your budget. Focus on essential spending only.")
        } else if ratio >= 0.95 {
            tips.append("Almost at budget limit. Try to limit spending to \(fmtDecimal(dailyLimit))/day.")
        } else {
            tips.append("Budget is \(Int(ratio * 100))% used. You can spend up to \(fmtDecimal(dailyLimit))/day.")
        }

        if let topNonEssential = sortedCats.first(where: { !essentialCategories.contains($0.key.lowercased()) }) {
            tips.append("Your biggest discretionary spend is \(topNonEssential.key) at \(fmtDecimal(topNonEssential.value)).")
        }

        let totalSavings = reductionTargets.reduce(Decimal.zero) { $0 + $1.savingsIfReduced }
        if totalSavings > 0 {
            tips.append("Reducing top categories by 20% could save \(fmtDecimal(totalSavings)).")
        }

        plan = BudgetRescuePlan(
            isActive: true,
            budgetUsedPercent: Int(ratio * 100),
            remainingBudget: remaining,
            daysRemaining: daysRemaining,
            dailyLimit: dailyLimit,
            topCategory: topCategory,
            topCategoryAmount: topCategoryAmount,
            reductionTargets: reductionTargets,
            tips: tips
        )
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

    private func fmtDecimal(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }
}
