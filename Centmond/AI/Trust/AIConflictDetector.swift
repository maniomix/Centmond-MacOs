import Foundation
import SwiftData

// ============================================================
// MARK: - AI Conflict Detector
// ============================================================
//
// Detects potential conflicts, duplicates, and safety issues
// BEFORE actions are executed.
//
// Runs after parsing, before trust classification.
// Returns warnings (proceed with caution) or blocks (don't execute).
//
// macOS Centmond: ModelContext instead of Store,
// SwiftData queries instead of manager singletons,
// amounts in dollars (Double) instead of cents (Int).
//
// ============================================================

/// Result of conflict detection.
struct ConflictResult {
    let warnings: [ConflictWarning]
    let blocks: [ConflictBlock]

    var hasIssues: Bool { !warnings.isEmpty || !blocks.isEmpty }
    var isBlocked: Bool { !blocks.isEmpty }

    var summaryText: String {
        var lines: [String] = []
        for block in blocks { lines.append("BLOCKED: \(block.message)") }
        for warning in warnings { lines.append("WARNING: \(warning.message)") }
        return lines.joined(separator: "\n")
    }
}

struct ConflictWarning {
    let type: WarningType
    let message: String
    let actionIndex: Int?

    enum WarningType {
        case duplicateTransaction
        case budgetExceeded
        case largeAmount
        case recentSimilar
        case goalOvercontribution
        case futureDate
        case oldDate
    }
}

struct ConflictBlock {
    let type: BlockType
    let message: String
    let actionIndex: Int?

    enum BlockType {
        case missingTransactionId
        case transactionNotFound
        case goalNotFound
        case subscriptionNotFound
        case accountNotFound
        case zeroAmount
        case incompleteContext
    }
}

@MainActor
enum AIConflictDetector {

    // MARK: - Detect

    static func detect(
        actions: [AIAction],
        context: ModelContext
    ) -> ConflictResult {
        var warnings: [ConflictWarning] = []
        var blocks: [ConflictBlock] = []

        for (index, action) in actions.enumerated() {
            let p = action.params

            switch action.type {

            case .addTransaction, .splitTransaction:
                if let amount = p.amount, amount == 0 {
                    blocks.append(ConflictBlock(
                        type: .zeroAmount,
                        message: "Transaction amount can't be zero.",
                        actionIndex: index
                    ))
                }

                if let amount = p.amount {
                    let date = resolveDate(p.date)
                    let cat = p.category?.lowercased() ?? ""
                    let dayStart = Calendar.current.startOfDay(for: date)
                    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
                    let descriptor = FetchDescriptor<Transaction>(
                        predicate: #Predicate { !$0.isIncome && $0.date >= dayStart && $0.date < dayEnd }
                    )
                    if let txns = try? context.fetch(descriptor) {
                        let isDuplicate = txns.contains {
                            NSDecimalNumber(decimal: $0.amount).doubleValue == amount &&
                            ($0.category?.name.lowercased() ?? "") == cat
                        }
                        if isDuplicate {
                            warnings.append(ConflictWarning(
                                type: .duplicateTransaction,
                                message: "A similar transaction already exists today (\(fmt(amount)) in \(cat)).",
                                actionIndex: index
                            ))
                        }
                    }
                }

                if let amount = p.amount, p.transactionType != "income" {
                    let budgetAmount = currentBudget(context: context)
                    if budgetAmount > 0 {
                        let spent = currentMonthSpending(context: context)
                        if spent + Decimal(amount) > budgetAmount {
                            let over = spent + Decimal(amount) - budgetAmount
                            warnings.append(ConflictWarning(
                                type: .budgetExceeded,
                                message: "This would put you \(fmtDecimal(over)) over budget.",
                                actionIndex: index
                            ))
                        }
                    }
                }

                if let amount = p.amount, amount > 10_000 {
                    warnings.append(ConflictWarning(
                        type: .largeAmount,
                        message: "Large amount: \(fmt(amount)).",
                        actionIndex: index
                    ))
                }

                if let dateStr = p.date {
                    let date = resolveDate(dateStr)
                    if date > Date().addingTimeInterval(86400) {
                        warnings.append(ConflictWarning(
                            type: .futureDate,
                            message: "Transaction date is in the future.",
                            actionIndex: index
                        ))
                    }
                    if date < Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date() {
                        warnings.append(ConflictWarning(
                            type: .oldDate,
                            message: "Transaction date is over a year ago.",
                            actionIndex: index
                        ))
                    }
                }

            case .editTransaction:
                if p.transactionId == nil {
                    blocks.append(ConflictBlock(
                        type: .missingTransactionId,
                        message: "Can't edit: no transaction specified.",
                        actionIndex: index
                    ))
                } else if let idStr = p.transactionId, let uuid = UUID(uuidString: idStr) {
                    let descriptor = FetchDescriptor<Transaction>(
                        predicate: #Predicate { $0.id == uuid }
                    )
                    if (try? context.fetchCount(descriptor)) == 0 {
                        blocks.append(ConflictBlock(
                            type: .transactionNotFound,
                            message: "Transaction not found for editing.",
                            actionIndex: index
                        ))
                    }
                }

            case .deleteTransaction:
                if p.transactionId == nil {
                    blocks.append(ConflictBlock(
                        type: .missingTransactionId,
                        message: "Can't delete: no transaction specified.",
                        actionIndex: index
                    ))
                } else if let idStr = p.transactionId, let uuid = UUID(uuidString: idStr) {
                    let descriptor = FetchDescriptor<Transaction>(
                        predicate: #Predicate { $0.id == uuid }
                    )
                    if (try? context.fetchCount(descriptor)) == 0 {
                        blocks.append(ConflictBlock(
                            type: .transactionNotFound,
                            message: "Transaction not found for deletion.",
                            actionIndex: index
                        ))
                    }
                }

            case .setBudget, .adjustBudget:
                if let amount = p.budgetAmount, amount == 0 {
                    warnings.append(ConflictWarning(
                        type: .largeAmount,
                        message: "Setting budget to $0 will effectively remove it.",
                        actionIndex: index
                    ))
                }

            case .setCategoryBudget:
                if p.budgetCategory == nil {
                    blocks.append(ConflictBlock(
                        type: .incompleteContext,
                        message: "No category specified for category budget.",
                        actionIndex: index
                    ))
                }

            case .addContribution:
                if let goalName = p.goalName {
                    let descriptor = FetchDescriptor<Goal>()
                    let goals = (try? context.fetch(descriptor)) ?? []
                    let goal = goals.first {
                        $0.name.localizedCaseInsensitiveCompare(goalName) == .orderedSame
                    }
                    if goal == nil {
                        blocks.append(ConflictBlock(
                            type: .goalNotFound,
                            message: "Goal \"\(goalName)\" not found.",
                            actionIndex: index
                        ))
                    } else if let goal, let contrib = p.contributionAmount {
                        let remaining = goal.targetAmount - goal.currentAmount
                        if Decimal(contrib) > remaining && remaining > 0 {
                            warnings.append(ConflictWarning(
                                type: .goalOvercontribution,
                                message: "This exceeds the remaining \(fmtDecimal(remaining)) for \"\(goalName)\".",
                                actionIndex: index
                            ))
                        }
                    }
                }

            case .updateGoal:
                if let goalName = p.goalName {
                    let descriptor = FetchDescriptor<Goal>()
                    let goals = (try? context.fetch(descriptor)) ?? []
                    if !goals.contains(where: {
                        $0.name.localizedCaseInsensitiveCompare(goalName) == .orderedSame
                    }) {
                        blocks.append(ConflictBlock(
                            type: .goalNotFound,
                            message: "Goal \"\(goalName)\" not found.",
                            actionIndex: index
                        ))
                    }
                }

            case .cancelSubscription:
                if let name = p.subscriptionName {
                    let descriptor = FetchDescriptor<Subscription>()
                    let subs = (try? context.fetch(descriptor)) ?? []
                    if !subs.contains(where: {
                        $0.serviceName.localizedCaseInsensitiveCompare(name) == .orderedSame
                    }) {
                        blocks.append(ConflictBlock(
                            type: .subscriptionNotFound,
                            message: "Subscription \"\(name)\" not found.",
                            actionIndex: index
                        ))
                    }
                }

            case .updateBalance:
                if let name = p.accountName {
                    let descriptor = FetchDescriptor<Account>()
                    let accounts = (try? context.fetch(descriptor)) ?? []
                    if !accounts.contains(where: {
                        $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                    }) {
                        blocks.append(ConflictBlock(
                            type: .accountNotFound,
                            message: "Account \"\(name)\" not found.",
                            actionIndex: index
                        ))
                    }
                }

            case .transfer:
                if p.fromAccount == nil || p.toAccount == nil {
                    blocks.append(ConflictBlock(
                        type: .incompleteContext,
                        message: "Transfer needs both source and destination accounts.",
                        actionIndex: index
                    ))
                } else {
                    let descriptor = FetchDescriptor<Account>()
                    let accounts = (try? context.fetch(descriptor)) ?? []
                    if let from = p.fromAccount,
                       !accounts.contains(where: {
                           $0.name.localizedCaseInsensitiveCompare(from) == .orderedSame
                       }) {
                        blocks.append(ConflictBlock(
                            type: .accountNotFound,
                            message: "Source account \"\(from)\" not found.",
                            actionIndex: index
                        ))
                    }
                    if let to = p.toAccount,
                       !accounts.contains(where: {
                           $0.name.localizedCaseInsensitiveCompare(to) == .orderedSame
                       }) {
                        blocks.append(ConflictBlock(
                            type: .accountNotFound,
                            message: "Destination account \"\(to)\" not found.",
                            actionIndex: index
                        ))
                    }
                }

            case .cancelRecurring, .analyze, .compare, .forecast, .advice,
                 .createGoal, .addSubscription, .addRecurring, .editRecurring,
                 .assignMember:
                break
            }

            // Cross-action: recent similar check
            let recentRecords = AIActionHistory.shared.records.prefix(5)
            for record in recentRecords {
                if record.action.type == action.type.rawValue,
                   record.action.amount == p.amount,
                   record.action.category == p.category,
                   record.executedAt.timeIntervalSinceNow > -60 {
                    warnings.append(ConflictWarning(
                        type: .recentSimilar,
                        message: "A very similar action was just executed.",
                        actionIndex: index
                    ))
                    break
                }
            }
        }

        return ConflictResult(warnings: warnings, blocks: blocks)
    }

    // MARK: - Dry Run

    static func dryRun(
        actions: [AIAction],
        context: ModelContext
    ) -> [DryRunPreview] {
        var previews: [DryRunPreview] = []

        for action in actions {
            let p = action.params
            var preview = DryRunPreview(actionType: action.type.rawValue)

            switch action.type {
            case .addTransaction:
                let amount = Decimal(p.amount ?? 0)
                let currentSpent = currentMonthSpending(context: context)
                let budget = currentBudget(context: context)

                preview.beforeState = "Spent: \(fmtDecimal(currentSpent))"
                preview.afterState = "Spent: \(fmtDecimal(currentSpent + amount))"
                if budget > 0 {
                    let remaining = budget - currentSpent
                    let newRemaining = budget - (currentSpent + amount)
                    preview.impact = "Budget remaining: \(fmtDecimal(remaining)) -> \(fmtDecimal(newRemaining))"
                }

            case .setBudget, .adjustBudget:
                let oldBudget = currentBudget(context: context)
                let newBudget = Decimal(p.budgetAmount ?? 0)
                preview.beforeState = "Budget: \(fmtDecimal(oldBudget))"
                preview.afterState = "Budget: \(fmtDecimal(newBudget))"
                let diff = newBudget - oldBudget
                preview.impact = diff >= 0 ? "Increase of \(fmtDecimal(diff))" : "Decrease of \(fmtDecimal(-diff))"

            case .addContribution:
                if let goalName = p.goalName, let contrib = p.contributionAmount {
                    let descriptor = FetchDescriptor<Goal>()
                    if let goals = try? context.fetch(descriptor),
                       let goal = goals.first(where: {
                           $0.name.localizedCaseInsensitiveCompare(goalName) == .orderedSame
                       }) {
                        let pctBefore = Int(goal.progressPercentage * 100)
                        let newAmount = goal.currentAmount + Decimal(contrib)
                        let pctAfter = goal.targetAmount > 0
                            ? min(100, Int(NSDecimalNumber(decimal: newAmount / goal.targetAmount).doubleValue * 100))
                            : 0
                        preview.beforeState = "\(goal.name): \(pctBefore)%"
                        preview.afterState = "\(goal.name): \(pctAfter)%"
                        preview.impact = "\(fmt(contrib)) added"
                    }
                }

            default:
                preview.beforeState = "Current state"
                preview.afterState = "After \(action.type.rawValue)"
            }

            preview.isReversible = isReversible(action.type)
            previews.append(preview)
        }

        return previews
    }

    static func isReversible(_ type: AIAction.ActionType) -> Bool {
        switch type {
        case .addTransaction, .editTransaction, .deleteTransaction,
             .splitTransaction, .setBudget, .adjustBudget, .setCategoryBudget,
             .createGoal, .addContribution, .addSubscription,
             .addRecurring, .editRecurring:
            return true
        case .cancelSubscription, .cancelRecurring, .updateGoal,
             .updateBalance, .transfer, .assignMember:
            return false
        case .analyze, .compare, .forecast, .advice:
            return true
        }
    }

    // MARK: - Helpers

    private static func resolveDate(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        if raw.lowercased() == "today" { return Date() }
        if raw.lowercased() == "yesterday" {
            return Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: raw) ?? Date()
    }

    private static func currentBudget(context: ModelContext) -> Decimal {
        let cal = Calendar.current
        let year = cal.component(.year, from: Date())
        let month = cal.component(.month, from: Date())
        let descriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        return (try? context.fetch(descriptor).first)?.amount ?? 0
    }

    private static func currentMonthSpending(context: ModelContext) -> Decimal {
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

    private static func fmt(_ dollars: Double) -> String {
        String(format: "$%.2f", dollars)
    }

    private static func fmtDecimal(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }
}

struct DryRunPreview {
    let actionType: String
    var beforeState: String = ""
    var afterState: String = ""
    var impact: String = ""
    var isReversible: Bool = true
}
