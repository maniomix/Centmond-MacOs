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
        case .pauseSubscription:
            return setSubscriptionStatus(action, to: .paused, verb: "Paused", context: context)
        case .resumeSubscription:
            return setSubscriptionStatus(action, to: .active, verb: "Resumed", context: context)
        case .detectSubscriptions:
            return detectSubscriptions(action, context: context)

        // ── Accounts ──
        case .updateBalance:
            return updateBalance(action, context: context)

        // ── Household ──
        case .assignMember:
            return assignMember(action, context: context)

        // ── Analysis (no mutation) ──
        case .analyze, .compare, .forecast, .advice:
            return ExecutionResult(action: action, success: true, summary: "")

        // ── Net Worth (analysis-only, P9) ──
        case .simulatePayoff:
            return simulatePayoff(action, context: context)
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

        // Assign household member if specified; otherwise fall back to the
        // payee-learner so AI-entered expenses inherit attribution the same
        // way manual/CSV entries do (P2).
        if let memberName = p.memberName {
            txn.householdMember = findMember(memberName, context: context)
        } else {
            txn.householdMember = HouseholdService.resolveMember(
                forPayee: txn.payee,
                in: context
            )
        }

        context.insert(txn)

        // Link to a matching active Subscription if one exists. Same hook the
        // manual New Transaction sheet uses — keeps AI-added expenses in step
        // with the rest of the ledger.
        SubscriptionReconciliationService.reconcile(transaction: txn, in: context)

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

        TransactionDeletionService.delete(txn, context: context)
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

        // Insert the full-amount transaction attributed to the user (or the
        // household default owner if we can find one); the split is recorded
        // as ExpenseShare rows so the ledger stays in sync with cash-out and
        // "who owes what" is derived from the shares.
        let txn = Transaction(
            date: date,
            payee: p.note ?? "Split with \(memberName)",
            amount: Decimal(amount),
            notes: p.note ?? "Split with \(memberName)",
            isIncome: false,
            status: .cleared,
            isReviewed: false,
            account: defaultAccount(context: context),
            category: category
        )
        // Payer = owner member if we have one, else the first active member —
        // needed so the settle-up ledger has a counterparty for the partner's share.
        let payer = defaultOwner(context: context)
        txn.householdMember = payer
        context.insert(txn)

        guard let partner = findMember(memberName, context: context) else {
            return ExecutionResult(
                action: action, success: true,
                summary: "Added \(formatDollars(amount)) but couldn't find member \(memberName) — not split"
            )
        }

        // Write shares: payer + partner. ratio is the partner's share fraction.
        let clamped = max(0.0, min(1.0, ratio))
        let partnerAmount = Decimal(amount * clamped)
        let payerAmount = Decimal(amount) - partnerAmount
        var amounts: [Decimal] = []
        var members: [HouseholdMember] = []
        if let payer {
            members.append(payer); amounts.append(payerAmount)
        }
        members.append(partner); amounts.append(partnerAmount)
        HouseholdService.applyExactSplit(
            to: txn, members: members, amounts: amounts, in: context
        )

        return ExecutionResult(
            action: action, success: true,
            summary: "Split \(formatDollars(amount)) with \(memberName) — their share: \(formatDollars(amount * clamped))"
        )
    }

    private static func defaultOwner(context: ModelContext) -> HouseholdMember? {
        let descriptor = FetchDescriptor<HouseholdMember>(
            sortBy: [SortDescriptor(\.joinedAt, order: .forward)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first(where: { $0.isOwner && $0.isActive }) ?? all.first(where: { $0.isActive })
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

        GoalContributionService.addContribution(
            to: goal,
            amount: Decimal(amount),
            kind: .manual,
            note: "Added via AI action",
            context: context
        )

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

    private static func setSubscriptionStatus(
        _ action: AIAction,
        to newStatus: SubscriptionStatus,
        verb: String,
        context: ModelContext
    ) -> ExecutionResult {
        let p = action.params
        guard let name = p.subscriptionName else {
            return ExecutionResult(action: action, success: false, summary: "Missing subscription name")
        }
        let descriptor = FetchDescriptor<Subscription>()
        guard let subs = try? context.fetch(descriptor),
              let sub = subs.first(where: { $0.serviceName.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return ExecutionResult(action: action, success: false, summary: "Subscription \"\(name)\" not found")
        }
        sub.status = newStatus
        sub.updatedAt = .now
        return ExecutionResult(action: action, success: true, summary: "\(verb) \(name)")
    }

    /// Read-only enumeration of detection candidates. Returned as a summary
    /// string so the chat surface can show the user what was found without
    /// the model having to format it. Does NOT mutate — confirming each
    /// candidate still requires the user opening the Detected sheet.
    private static func detectSubscriptions(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let candidates = SubscriptionDetector.detect(context: context)
        if candidates.isEmpty {
            return ExecutionResult(action: action, success: true, summary: "No new subscription patterns detected.")
        }
        let top = candidates.prefix(5).map { c in
            let pct = Int((c.confidence * 100).rounded())
            return "\(c.displayName) — \(formatDollars(NSDecimalNumber(decimal: c.amount).doubleValue))/\(c.billingCycle.rawValue) (\(pct)% confident)"
        }
        let suffix = candidates.count > 5 ? "\n…and \(candidates.count - 5) more — open the Detected sheet to confirm." : "\nOpen the Detected sheet to confirm."
        return ExecutionResult(
            action: action,
            success: true,
            summary: "Found \(candidates.count) candidate\(candidates.count == 1 ? "" : "s"):\n  • " + top.joined(separator: "\n  • ") + suffix
        )
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

    // MARK: - Net Worth (P9)

    /// Read-only: runs `PayoffSimulator` across all three strategies
    /// and returns a one-line summary the chat layer can render. The
    /// optional `extraMonthly` parameter (in dollars) flows through
    /// `ActionParams.amount` so the model can say e.g. "what if I add
    /// $200/mo?". Defaults to $0 when not provided.
    private static func simulatePayoff(_ action: AIAction, context: ModelContext) -> ExecutionResult {
        let extra = Decimal(action.params.amount ?? 0)
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isArchived && !$0.isClosed }
        )
        let accounts = (try? context.fetch(descriptor)) ?? []
        let liabilities = accounts.filter { $0.type.isLiability && abs($0.currentBalance) > 0 }

        guard !liabilities.isEmpty else {
            return ExecutionResult(action: action, success: true, summary: "No active liabilities to simulate.")
        }

        let plans = PayoffStrategy.allCases.map {
            PayoffSimulator.simulate(accounts: liabilities, strategy: $0, extraMonthly: extra)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        let lines = plans.map { plan -> String in
            let date = plan.payoffDate.map { formatter.string(from: $0) } ?? "never"
            return "  • \(plan.strategy.label): clear by \(date) (\(plan.months)mo, interest \(formatDollars(NSDecimalNumber(decimal: plan.totalInterest).doubleValue)))"
        }
        let extraNote = extra > 0 ? " with \(formatDollars(NSDecimalNumber(decimal: extra).doubleValue))/mo extra" : ""
        let summary = "Payoff simulation\(extraNote):\n" + lines.joined(separator: "\n")
        return ExecutionResult(action: action, success: true, summary: summary)
    }
}
