import Foundation
import SwiftData

// ============================================================
// MARK: - AI Action Executor
// ============================================================
//
// Takes confirmed AIActions and applies them to SwiftData.
// Returns a user-facing summary of what was done.
//
// macOS Centmond rewrite: Store → ModelContext, cents → Decimal.
//
// ============================================================

enum AIActionExecutor {

    struct ExecutionResult {
        let action: AIAction
        let success: Bool
        let summary: String
    }

    /// Execute a single confirmed action.
    static func execute(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        switch action.type {

        // ── Transactions ──
        case .addTransaction:
            return addTransaction(action, context: context)
        case .editTransaction:
            return editTransaction(action, context: context)
        case .deleteTransaction:
            return deleteTransaction(action, context: context)
        case .splitTransaction:
            return splitTransaction(action, context: context)

        // ── Transfers ──
        case .transfer:
            return transfer(action, context: context)

        // ── Recurring ──
        case .addRecurring:
            return addRecurring(action, context: context)
        case .editRecurring:
            return editRecurring(action, context: context)
        case .cancelRecurring:
            return cancelRecurring(action, context: context)

        // ── Budget ──
        case .setBudget, .adjustBudget:
            return setBudget(action, context: context)
        case .setCategoryBudget:
            return setCategoryBudget(action, context: context)

        // ── Goals ──
        case .createGoal:
            return createGoal(action, context: context)
        case .addContribution:
            return addContribution(action, context: context)
        case .updateGoal:
            return updateGoal(action, context: context)

        // ── Subscriptions ──
        case .addSubscription:
            return addSubscription(action, context: context)
        case .cancelSubscription:
            return cancelSubscription(action, context: context)

        // ── Accounts ──
        case .updateBalance:
            return updateBalance(action, context: context)

        // ── Household ──
        case .assignMember:
            return assignMember(action, context: context)

        // ── Analysis (no mutation) ──
        case .analyze, .compare, .forecast, .advice:
            return ExecutionResult(action: action, success: true, summary: "")
        }
    }

    /// Execute all confirmed actions in order.
    static func executeAll(_ actions: [AIAction], context: ModelContext) -> [ExecutionResult] {
        var results: [ExecutionResult] = []
        for action in actions where action.status == .confirmed {
            results.append(execute(action, context: context))
        }
        // Save once after all actions
        try? context.save()
        return results
    }

    // MARK: - Transaction Handlers

    private static func addTransaction(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let amount = p.amount else {
            return ExecutionResult(action: action, success: false, summary: "Missing amount")
        }

        let category = resolveCategory(p.category, context: context)
        let date = resolveDate(p.date)
        let isIncome = p.transactionType == "income"

        let txn = Transaction(
            date: date,
            payee: p.note ?? "",
            amount: Decimal(amount),
            notes: p.note,
            isIncome: isIncome,
            status: .cleared,
            isReviewed: false,
            account: defaultAccount(context: context),
            category: category
        )

        // Assign household member if specified
        if let memberName = p.memberName {
            txn.householdMember = findMember(memberName, context: context)
        }

        context.insert(txn)

        let label = isIncome ? "income" : "expense"
        let catName = category?.name ?? "uncategorized"
        return ExecutionResult(
            action: action, success: true,
            summary: "Added \(label): \(formatDollars(amount)) [\(catName)]"
        )
    }

    private static func editTransaction(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let idStr = p.transactionId, let uuid = UUID(uuidString: idStr) else {
            return ExecutionResult(action: action, success: false, summary: "Missing transaction ID")
        }

        guard let txn = fetchTransaction(id: uuid, context: context) else {
            return ExecutionResult(action: action, success: false, summary: "Transaction not found")
        }

        if let amount = p.amount { txn.amount = Decimal(amount) }
        if let cat = p.category { txn.category = resolveCategory(cat, context: context) }
        if let note = p.note { txn.notes = note; txn.payee = note }
        if let date = p.date { txn.date = resolveDate(date) }
        if let t = p.transactionType { txn.isIncome = (t == "income") }
        txn.updatedAt = Date()

        return ExecutionResult(action: action, success: true, summary: "Updated transaction")
    }

    private static func deleteTransaction(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let idStr = p.transactionId, let uuid = UUID(uuidString: idStr) else {
            return ExecutionResult(action: action, success: false, summary: "Missing transaction ID")
        }

        guard let txn = fetchTransaction(id: uuid, context: context) else {
            return ExecutionResult(action: action, success: false, summary: "Transaction not found")
        }

        context.delete(txn)
        return ExecutionResult(action: action, success: true, summary: "Deleted transaction")
    }

    private static func splitTransaction(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let amount = p.amount, let memberName = p.splitWith else {
            return ExecutionResult(action: action, success: false, summary: "Missing amount or split partner")
        }

        let category = resolveCategory(p.category, context: context)
        let date = resolveDate(p.date)
        let ratio = p.splitRatio ?? 0.5
        let myShare = amount * ratio

        let txn = Transaction(
            date: date,
            payee: p.note ?? "Split with \(memberName)",
            amount: Decimal(myShare),
            notes: p.note ?? "Split with \(memberName)",
            isIncome: false,
            status: .cleared,
            isReviewed: false,
            account: defaultAccount(context: context),
            category: category
        )

        if let member = findMember(memberName, context: context) {
            txn.householdMember = member
        }

        context.insert(txn)

        return ExecutionResult(
            action: action, success: true,
            summary: "Split \(formatDollars(amount)) with \(memberName) — your share: \(formatDollars(myShare))"
        )
    }

    // MARK: - Budget Handlers

    private static func setBudget(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let amount = p.budgetAmount else {
            return ExecutionResult(action: action, success: false, summary: "Missing budget amount")
        }

        let (year, month) = resolveYearMonth(p.budgetMonth)

        // Find or create MonthlyTotalBudget
        let descriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.amount = Decimal(amount)
        } else {
            let budget = MonthlyTotalBudget(
                year: year,
                month: month,
                amount: Decimal(amount)
            )
            context.insert(budget)
        }

        let monthKey = String(format: "%04d-%02d", year, month)
        return ExecutionResult(
            action: action, success: true,
            summary: "Set budget to \(formatDollars(amount)) for \(monthKey)"
        )
    }

    private static func setCategoryBudget(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let catName = p.budgetCategory, let amount = p.budgetAmount else {
            return ExecutionResult(action: action, success: false, summary: "Missing category or amount")
        }

        let (year, month) = resolveYearMonth(p.budgetMonth)

        // Find the category
        guard let category = resolveCategory(catName, context: context) else {
            return ExecutionResult(action: action, success: false, summary: "Category \"\(catName)\" not found")
        }

        let catID = category.id
        let descriptor = FetchDescriptor<MonthlyBudget>(
            predicate: #Predicate { $0.categoryID == catID && $0.year == year && $0.month == month }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.amount = Decimal(amount)
        } else {
            let override = MonthlyBudget(
                categoryID: category.id,
                year: year,
                month: month,
                amount: Decimal(amount)
            )
            context.insert(override)
        }

        let monthKey = String(format: "%04d-%02d", year, month)
        return ExecutionResult(
            action: action, success: true,
            summary: "Set \(catName) budget to \(formatDollars(amount)) for \(monthKey)"
        )
    }

    // MARK: - Goal Handlers

    private static func createGoal(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let name = p.goalName, let target = p.goalTarget else {
            return ExecutionResult(action: action, success: false, summary: "Missing goal name or target")
        }

        let goal = Goal(
            name: name,
            icon: "star.fill",
            targetAmount: Decimal(target),
            currentAmount: 0,
            targetDate: p.goalDeadline.flatMap { parseISO($0) }
        )
        context.insert(goal)

        return ExecutionResult(
            action: action, success: true,
            summary: "Created goal \"\(name)\" — target \(formatDollars(target))"
        )
    }

    private static func addContribution(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let name = p.goalName, let amount = p.contributionAmount else {
            return ExecutionResult(action: action, success: false, summary: "Missing goal name or amount")
        }

        let descriptor = FetchDescriptor<Goal>()
        guard let goals = try? context.fetch(descriptor),
              let goal = goals.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return ExecutionResult(action: action, success: false, summary: "Goal \"\(name)\" not found")
        }

        goal.currentAmount += Decimal(amount)
        goal.updatedAt = Date()
        if goal.currentAmount >= goal.targetAmount {
            goal.status = .completed
        }

        return ExecutionResult(
            action: action, success: true,
            summary: "Added \(formatDollars(amount)) to \"\(name)\""
        )
    }

    private static func updateGoal(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let name = p.goalName else {
            return ExecutionResult(action: action, success: false, summary: "Missing goal name")
        }

        let descriptor = FetchDescriptor<Goal>()
        guard let goals = try? context.fetch(descriptor),
              let goal = goals.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return ExecutionResult(action: action, success: false, summary: "Goal \"\(name)\" not found")
        }

        if let target = p.goalTarget { goal.targetAmount = Decimal(target) }
        if let deadline = p.goalDeadline { goal.targetDate = parseISO(deadline) }
        goal.updatedAt = Date()

        return ExecutionResult(action: action, success: true, summary: "Updated goal \"\(name)\"")
    }

    // MARK: - Subscription Handlers

    private static func addSubscription(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let name = p.subscriptionName, let amount = p.subscriptionAmount else {
            return ExecutionResult(action: action, success: false, summary: "Missing subscription info")
        }

        let cycle: BillingCycle = p.subscriptionFrequency == "yearly" ? .annual : .monthly

        let sub = Subscription(
            serviceName: name,
            categoryName: "bills",
            amount: Decimal(amount),
            billingCycle: cycle,
            nextPaymentDate: Date()
        )
        context.insert(sub)

        return ExecutionResult(
            action: action, success: true,
            summary: "Added subscription: \(name) \(formatDollars(amount))/\(cycle.rawValue)"
        )
    }

    private static func cancelSubscription(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let name = p.subscriptionName else {
            return ExecutionResult(action: action, success: false, summary: "Missing subscription name")
        }

        let descriptor = FetchDescriptor<Subscription>()
        guard let subs = try? context.fetch(descriptor),
              let sub = subs.first(where: { $0.serviceName.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return ExecutionResult(action: action, success: false, summary: "Subscription \"\(name)\" not found")
        }

        sub.status = .cancelled
        sub.updatedAt = Date()

        return ExecutionResult(action: action, success: true, summary: "Cancelled \(name)")
    }

    // MARK: - Account Handlers

    private static func updateBalance(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let name = p.accountName, let balance = p.accountBalance else {
            return ExecutionResult(action: action, success: false, summary: "Missing account info")
        }

        let descriptor = FetchDescriptor<Account>()
        guard let accounts = try? context.fetch(descriptor),
              let account = accounts.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return ExecutionResult(action: action, success: false, summary: "Account \"\(name)\" not found")
        }

        account.currentBalance = Decimal(balance)
        return ExecutionResult(
            action: action, success: true,
            summary: "Updated \(name) balance to \(formatDollars(balance))"
        )
    }

    // MARK: - Transfer Handler

    private static func transfer(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let from = p.fromAccount, let to = p.toAccount, let amount = p.amount else {
            return ExecutionResult(action: action, success: false, summary: "Missing transfer details")
        }

        let descriptor = FetchDescriptor<Account>()
        guard let accounts = try? context.fetch(descriptor) else {
            return ExecutionResult(action: action, success: false, summary: "Could not load accounts")
        }

        guard let source = accounts.first(where: { $0.name.localizedCaseInsensitiveCompare(from) == .orderedSame }),
              let dest = accounts.first(where: { $0.name.localizedCaseInsensitiveCompare(to) == .orderedSame }) else {
            return ExecutionResult(action: action, success: false, summary: "One or both accounts not found")
        }

        // Use TransferService for proper paired transactions
        if TransferService.createTransfer(
            amount: Decimal(amount), date: Date(),
            from: source, to: dest, notes: "Via AI assistant", in: context
        ) != nil {
            return ExecutionResult(
                action: action, success: true,
                summary: "Transferred \(formatDollars(amount)) from \(from) to \(to)"
            )
        }

        return ExecutionResult(action: action, success: false, summary: "Transfer failed")
    }

    // MARK: - Recurring Handlers

    private static func addRecurring(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        let name = p.recurringName ?? p.note ?? "Recurring"
        guard let amount = p.amount else {
            return ExecutionResult(action: action, success: false, summary: "Missing amount for recurring")
        }

        let category = resolveCategory(p.category, context: context)
        let freq: RecurrenceFrequency
        switch p.recurringFrequency?.lowercased() {
        case "daily", "weekly": freq = .weekly
        case "yearly":          freq = .annual
        default:                freq = .monthly
        }

        let recurring = RecurringTransaction(
            name: name,
            amount: Decimal(amount),
            isIncome: false,
            frequency: freq,
            nextOccurrence: resolveDate(p.date),
            autoCreate: true,
            account: defaultAccount(context: context),
            category: category
        )
        context.insert(recurring)

        return ExecutionResult(
            action: action, success: true,
            summary: "Added recurring: \(name) \(formatDollars(amount))/\(freq.rawValue)"
        )
    }

    private static func editRecurring(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let name = p.recurringName ?? p.subscriptionName else {
            return ExecutionResult(action: action, success: false, summary: "Missing recurring name")
        }

        let descriptor = FetchDescriptor<RecurringTransaction>()
        guard let items = try? context.fetch(descriptor),
              let item = items.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return ExecutionResult(action: action, success: false, summary: "Recurring \"\(name)\" not found")
        }

        if let amount = p.amount { item.amount = Decimal(amount) }
        if let cat = p.category { item.category = resolveCategory(cat, context: context) }

        return ExecutionResult(action: action, success: true, summary: "Updated recurring: \(name)")
    }

    private static func cancelRecurring(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let name = p.recurringName ?? p.subscriptionName else {
            return ExecutionResult(action: action, success: false, summary: "Missing recurring name")
        }

        let descriptor = FetchDescriptor<RecurringTransaction>()
        guard let items = try? context.fetch(descriptor),
              let item = items.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return ExecutionResult(action: action, success: false, summary: "Recurring \"\(name)\" not found")
        }

        item.isActive = false
        return ExecutionResult(action: action, success: true, summary: "Cancelled recurring: \(name)")
    }

    // MARK: - Household Handler

    private static func assignMember(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let p = action.params
        guard let idStr = p.transactionId, let uuid = UUID(uuidString: idStr),
              let memberName = p.memberName else {
            return ExecutionResult(action: action, success: false, summary: "Missing transaction ID or member name")
        }

        guard let txn = fetchTransaction(id: uuid, context: context) else {
            return ExecutionResult(action: action, success: false, summary: "Transaction not found")
        }

        guard let member = findMember(memberName, context: context) else {
            return ExecutionResult(action: action, success: false, summary: "Member \"\(memberName)\" not found")
        }

        txn.householdMember = member
        return ExecutionResult(action: action, success: true, summary: "Assigned to \(memberName)")
    }

    // MARK: - Helpers

    private static func resolveCategory(_ key: String?, context: ModelContext) -> BudgetCategory? {
        guard let key, !key.isEmpty else { return nil }
        let descriptor = FetchDescriptor<BudgetCategory>()
        guard let categories = try? context.fetch(descriptor) else { return nil }

        // Exact match by name (case-insensitive)
        if let match = categories.first(where: { $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }) {
            return match
        }

        // Handle "custom:Name" format
        if key.hasPrefix("custom:") {
            let customName = String(key.dropFirst(7))
            return categories.first(where: { $0.name.localizedCaseInsensitiveCompare(customName) == .orderedSame })
        }

        return nil
    }

    private static func defaultAccount(context: ModelContext) -> Account? {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isArchived && !$0.isClosed },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return try? context.fetch(descriptor).first
    }

    private static func fetchTransaction(id: UUID, context: ModelContext) -> Transaction? {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    private static func findMember(_ name: String, context: ModelContext) -> HouseholdMember? {
        let descriptor = FetchDescriptor<HouseholdMember>()
        guard let members = try? context.fetch(descriptor) else { return nil }
        return members.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
    }

    private static func resolveDate(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        let lower = raw.lowercased()
        if lower == "today" { return Date() }
        if lower == "yesterday" { return Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date() }

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        if let d = f.date(from: raw) { return d }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: raw) ?? Date()
    }

    private static func resolveYearMonth(_ raw: String?) -> (Int, Int) {
        let cal = Calendar.current
        let now = Date()
        guard let raw else {
            return (cal.component(.year, from: now), cal.component(.month, from: now))
        }
        if raw == "this_month" {
            return (cal.component(.year, from: now), cal.component(.month, from: now))
        }
        // Try YYYY-MM format
        let parts = raw.split(separator: "-")
        if parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) {
            return (y, m)
        }
        return (cal.component(.year, from: now), cal.component(.month, from: now))
    }

    private static func parseISO(_ str: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        if let d = f.date(from: str) { return d }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: str)
    }

    private static func formatDollars(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }
}
