import Foundation
import SwiftData

// ============================================================
// MARK: - AI Context Builder
// ============================================================
//
// Summarises live SwiftData into a compact text block injected
// into the system prompt. Gives Gemma awareness of the user's
// finances without sending raw model objects.
//
// macOS Centmond rewrite: Store → ModelContext, cents → Decimal.
//
// ============================================================

enum AIContextBuilder {

    /// Build a full financial context string from SwiftData.
    static func build(context: ModelContext) -> String {
        let now = Date()
        var sections: [String] = []

        sections.append(dateSection(now))
        sections.append(budgetSection(context: context, month: now))
        sections.append(transactionSection(context: context, month: now))
        sections.append(categoryBreakdown(context: context, month: now))
        sections.append(goalSection(context: context))
        sections.append(accountSection(context: context))
        sections.append(subscriptionSection(context: context))
        sections.append(householdSection(context: context))

        return sections
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Focused Builders (for Intent Router)

    static func buildBudgetOnly(context: ModelContext) -> String {
        let now = Date()
        return [budgetSection(context: context, month: now),
                categoryBreakdown(context: context, month: now)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func buildTransactionsOnly(context: ModelContext) -> String {
        let now = Date()
        return [transactionSection(context: context, month: now),
                categoryBreakdown(context: context, month: now)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func buildGoalsOnly(context: ModelContext) -> String {
        goalSection(context: context)
    }

    static func buildSubscriptionsOnly(context: ModelContext) -> String {
        subscriptionSection(context: context)
    }

    static func buildAccountsOnly(context: ModelContext) -> String {
        accountSection(context: context)
    }

    // MARK: - Date

    private static func dateSection(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd (EEEE)"
        return "TODAY: \(f.string(from: date))"
    }

    // MARK: - Budget

    private static func budgetSection(context: ModelContext, month: Date) -> String {
        let (year, mon) = yearMonth(month)

        // Total monthly budget
        let totalBudget = fetchTotalBudget(context: context, year: year, month: mon)

        // Transactions this month
        let (startOfMonth, endOfMonth) = monthRange(month)
        let txns = fetchTransactions(context: context, from: startOfMonth, to: endOfMonth)

        let spent = txns
            .filter { !$0.isIncome && BalanceService.isSpendingExpense($0) }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let income = txns
            .filter { $0.isIncome }
            .reduce(Decimal.zero) { $0 + $1.amount }

        guard totalBudget > 0 || spent > 0 || income > 0 else { return "" }

        let monthKey = monthKey(for: month)
        var lines = ["BUDGET (\(monthKey))"]
        if totalBudget > 0 { lines.append("  Monthly budget: \(dollars(totalBudget))") }
        if income > 0 { lines.append("  Income: \(dollars(income))") }
        lines.append("  Spent: \(dollars(spent))")
        if totalBudget > 0 { lines.append("  Remaining: \(dollars(totalBudget - spent))") }

        // Category budgets
        let catBudgets = fetchCategoryBudgets(context: context, year: year, month: mon)
        if !catBudgets.isEmpty {
            lines.append("  Category budgets:")
            for (name, amount) in catBudgets.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(name): \(dollars(amount))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Transactions (recent)

    private static func transactionSection(context: ModelContext, month: Date) -> String {
        let (startOfMonth, endOfMonth) = monthRange(month)
        let txns = fetchTransactions(context: context, from: startOfMonth, to: endOfMonth)
            .sorted { $0.date > $1.date }

        guard !txns.isEmpty else { return "" }

        let recent = txns.prefix(50)
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

        var lines = ["RECENT TRANSACTIONS (showing \(recent.count) of \(txns.count) this month)"]
        for t in recent {
            let typeTag = t.isIncome ? "+" : "-"
            let dateStr = shortDate(t.date)
            let timeStr = timeFmt.string(from: t.date)
            let weekday = Calendar.current.component(.weekday, from: t.date)
            let dayName = dayNames[weekday - 1]
            let cat = t.category?.name ?? "uncategorized"
            let payee = t.payee.isEmpty ? "" : " \(t.payee)"
            let note = (t.notes ?? "").isEmpty ? "" : " — \(t.notes!)"
            let member = t.householdMember.map { " [\($0.name)]" } ?? ""
            lines.append("  \(dayName) \(dateStr) \(timeStr) \(typeTag)\(dollars(t.amount)) [\(cat)]\(payee)\(note)\(member) id:\(t.id.uuidString)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Category Breakdown

    private static func categoryBreakdown(context: ModelContext, month: Date) -> String {
        let (startOfMonth, endOfMonth) = monthRange(month)
        let expenses = fetchTransactions(context: context, from: startOfMonth, to: endOfMonth)
            .filter { !$0.isIncome && BalanceService.isSpendingExpense($0) }

        guard !expenses.isEmpty else { return "" }

        var totals: [String: Decimal] = [:]
        for t in expenses {
            let cat = t.category?.name ?? "uncategorized"
            totals[cat, default: 0] += t.amount
        }

        let sorted = totals.sorted { $0.value > $1.value }
        var lines = ["SPENDING BY CATEGORY"]
        for (cat, amount) in sorted {
            lines.append("  \(cat): \(dollars(amount))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Goals

    private static func goalSection(context: ModelContext) -> String {
        let activeStatus = GoalStatus.active
        var descriptor = FetchDescriptor<Goal>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        descriptor.fetchLimit = 20
        guard let goals = try? context.fetch(descriptor), !goals.isEmpty else { return "" }

        var lines = ["ACTIVE GOALS"]
        for g in goals {
            let pct = Int(g.progressPercentage * 100)
            var detail = "  \(g.name): \(dollars(g.currentAmount)) / \(dollars(g.targetAmount)) (\(pct)%)"
            if let deadline = g.targetDate {
                detail += " due \(shortDate(deadline))"
            }
            if let monthly = g.monthlyContribution, monthly > 0 {
                detail += " — contributing \(dollars(monthly))/mo"
            }
            lines.append(detail)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Accounts

    private static func accountSection(context: ModelContext) -> String {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isArchived && !$0.isClosed }
        )
        guard let accounts = try? context.fetch(descriptor), !accounts.isEmpty else { return "" }

        var lines = ["ACCOUNTS"]
        for a in accounts {
            lines.append("  \(a.name) (\(a.type.rawValue)): \(dollars(a.currentBalance)) \(a.currency)")
        }

        let netWorth = accounts
            .filter { $0.includeInNetWorth }
            .reduce(Decimal.zero) { total, acct in
                acct.type.isLiability
                    ? total - acct.currentBalance
                    : total + acct.currentBalance
            }
        lines.append("  Net worth: \(dollars(netWorth))")

        return lines.joined(separator: "\n")
    }

    // MARK: - Subscriptions

    private static func subscriptionSection(context: ModelContext) -> String {
        let activeSub = SubscriptionStatus.active
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.status == activeSub }
        )
        guard let subs = try? context.fetch(descriptor), !subs.isEmpty else { return "" }

        let monthlyTotal = subs.reduce(Decimal.zero) { $0 + $1.monthlyCost }
        var lines = ["ACTIVE SUBSCRIPTIONS (total \(dollars(monthlyTotal))/mo)"]
        for s in subs {
            let cycleName = s.billingCycle.rawValue
            var detail = "  \(s.serviceName): \(dollars(s.amount))/\(cycleName)"
            let daysUntil = Calendar.current.dateComponents([.day], from: Date(), to: s.nextPaymentDate).day ?? 0
            if daysUntil >= 0 {
                detail += " (renews in \(daysUntil)d)"
            }
            lines.append(detail)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Household

    private static func householdSection(context: ModelContext) -> String {
        let descriptor = FetchDescriptor<HouseholdMember>(
            sortBy: [SortDescriptor(\.joinedAt)]
        )
        guard let members = try? context.fetch(descriptor), !members.isEmpty else { return "" }

        let names = members.map(\.name).joined(separator: ", ")
        var lines = ["HOUSEHOLD MEMBERS: \(names)"]

        // Per-member spending this month
        let (startOfMonth, endOfMonth) = monthRange(Date())
        let txns = fetchTransactions(context: context, from: startOfMonth, to: endOfMonth)
            .filter { !$0.isIncome && BalanceService.isSpendingExpense($0) }

        for member in members {
            let memberSpend = txns
                .filter { $0.householdMember?.id == member.id }
                .reduce(Decimal.zero) { $0 + $1.amount }
            if memberSpend > 0 {
                lines.append("  \(member.name): \(dollars(memberSpend)) this month")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Data Fetching Helpers

    private static func fetchTransactions(context: ModelContext, from start: Date, to end: Date) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchTotalBudget(context: ModelContext, year: Int, month: Int) -> Decimal {
        let descriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        return (try? context.fetch(descriptor))?.first?.amount ?? 0
    }

    /// Returns a dictionary of category name → budget amount for the given month.
    /// Uses MonthlyBudget override if it exists, otherwise falls back to BudgetCategory.budgetAmount.
    private static func fetchCategoryBudgets(context: ModelContext, year: Int, month: Int) -> [String: Decimal] {
        // All categories
        let catDescriptor = FetchDescriptor<BudgetCategory>()
        guard let categories = try? context.fetch(catDescriptor) else { return [:] }

        // Overrides for this month
        let overrideDescriptor = FetchDescriptor<MonthlyBudget>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        let overrides = (try? context.fetch(overrideDescriptor)) ?? []
        let overrideMap = Dictionary(uniqueKeysWithValues: overrides.map { ($0.categoryID, $0.amount) })

        var result: [String: Decimal] = [:]
        for cat in categories where cat.isExpenseCategory {
            let amount = overrideMap[cat.id] ?? cat.budgetAmount
            if amount > 0 {
                result[cat.name] = amount
            }
        }
        return result
    }

    // MARK: - Formatting Helpers

    private static func dollars(_ amount: Decimal) -> String {
        let d = NSDecimalNumber(decimal: amount).doubleValue
        return String(format: "$%.2f", d)
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private static func monthKey(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    private static func yearMonth(_ date: Date) -> (Int, Int) {
        let cal = Calendar.current
        return (cal.component(.year, from: date), cal.component(.month, from: date))
    }

    private static func monthRange(_ date: Date) -> (Date, Date) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        let start = cal.date(from: comps)!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        return (start, end)
    }
}
