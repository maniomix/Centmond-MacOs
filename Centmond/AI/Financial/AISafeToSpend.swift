import Foundation
import SwiftData

// ============================================================
// MARK: - AI Safe-to-Spend Engine
// ============================================================
//
// Calculates how much the user can safely spend today/this week
// without exceeding their budget or jeopardizing their goals.
//
// Pure math -- no LLM needed. Used by:
//   - System prompt context (gives AI accurate safe-to-spend data)
//   - Dashboard widgets
//   - Proactive alerts
//
// macOS Centmond: @Observable, ModelContext, Decimal amounts.
//
// ============================================================

struct SafeToSpendResult {
    let dailyAllowance: Decimal
    let weeklyAllowance: Decimal
    let remainingBudget: Decimal
    let daysLeftInMonth: Int
    let burnRate: Double
    let projectedMonthEnd: Decimal
    let isOnTrack: Bool
    let survivalDays: Int
    let goalReserve: Decimal
    let trueAllowance: Decimal

    func summary(currency: String = "$") -> String {
        var lines: [String] = []
        lines.append("Safe to spend today: \(fmt(trueAllowance, currency))")
        lines.append("This week: \(fmt(weeklyAllowance, currency))")
        lines.append("Budget remaining: \(fmt(remainingBudget, currency)) (\(daysLeftInMonth) days left)")
        lines.append("Daily burn rate: \(fmt(Decimal(burnRate), currency))/day")

        if !isOnTrack {
            lines.append("At current pace, you may overspend before month end")
        }
        if survivalDays < daysLeftInMonth {
            lines.append("Budget runs out in ~\(survivalDays) days")
        }
        if goalReserve > 0 {
            lines.append("Goal savings reserved: \(fmt(goalReserve, currency))/month")
        }
        return lines.joined(separator: "\n")
    }

    private func fmt(_ value: Decimal, _ currency: String) -> String {
        let d = NSDecimalNumber(decimal: max(0, value)).doubleValue
        return String(format: "\(currency)%.2f", d)
    }
}

@MainActor @Observable
final class AISafeToSpend {
    static let shared = AISafeToSpend()

    private init() {}

    func calculate(context: ModelContext) -> SafeToSpendResult {
        let now = Date()
        let cal = Calendar.current

        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let daysElapsed = max(1, cal.dateComponents([.day], from: monthStart, to: now).day ?? 1)
        let totalDaysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let daysLeft = max(1, totalDaysInMonth - daysElapsed)

        let budget = currentBudget(context: context)
        let spent = currentMonthSpending(context: context)
        let remaining = max(0, budget - spent)

        let burnRate = NSDecimalNumber(decimal: spent).doubleValue / Double(daysElapsed)
        let projectedTotal = Decimal(burnRate * Double(totalDaysInMonth))
        let isOnTrack = budget > 0 ? projectedTotal <= budget : true

        let survivalDays: Int
        if burnRate > 0 {
            survivalDays = Int(NSDecimalNumber(decimal: remaining).doubleValue / burnRate)
        } else {
            survivalDays = daysLeft
        }

        let goalReserve = calculateGoalReserve(context: context)
        let dailyAllowance = daysLeft > 0 ? remaining / Decimal(daysLeft) : remaining
        let weeklyAllowance = min(remaining, dailyAllowance * Decimal(min(7, daysLeft)))
        let dailyGoalReserve = goalReserve / Decimal(max(1, totalDaysInMonth))
        let trueAllowance = max(0, dailyAllowance - dailyGoalReserve)

        return SafeToSpendResult(
            dailyAllowance: dailyAllowance,
            weeklyAllowance: weeklyAllowance,
            remainingBudget: remaining,
            daysLeftInMonth: daysLeft,
            burnRate: burnRate,
            projectedMonthEnd: projectedTotal,
            isOnTrack: isOnTrack,
            survivalDays: survivalDays,
            goalReserve: goalReserve,
            trueAllowance: trueAllowance
        )
    }

    func canAfford(amount: Decimal, context: ModelContext) -> AffordabilityResult {
        let sts = calculate(context: context)
        let remaining = sts.remainingBudget

        if amount <= sts.trueAllowance {
            return AffordabilityResult(
                canAfford: true,
                impact: .minimal,
                message: "Yes, that's within your daily allowance.",
                remainingAfter: remaining - amount
            )
        } else if amount <= remaining {
            let daysOfBudget = sts.burnRate > 0 ? Int(NSDecimalNumber(decimal: amount).doubleValue / sts.burnRate) : 0
            return AffordabilityResult(
                canAfford: true,
                impact: .moderate,
                message: "You can afford it, but it uses ~\(daysOfBudget) days of budget.",
                remainingAfter: remaining - amount
            )
        } else {
            let shortfall = amount - remaining
            return AffordabilityResult(
                canAfford: false,
                impact: .severe,
                message: "That would put you \(fmtDecimal(shortfall)) over budget.",
                remainingAfter: remaining - amount
            )
        }
    }

    // MARK: - Helpers

    private func calculateGoalReserve(context: ModelContext) -> Decimal {
        let activeStatus = GoalStatus.active
        let descriptor = FetchDescriptor<Goal>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        guard let goals = try? context.fetch(descriptor) else { return 0 }
        return goals.compactMap(\.monthlyContribution).reduce(Decimal.zero, +)
    }

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

    private func fmtDecimal(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", abs(d))
    }
}

struct AffordabilityResult {
    let canAfford: Bool
    let impact: Impact
    let message: String
    let remainingAfter: Decimal

    enum Impact {
        case minimal
        case moderate
        case severe
    }
}
