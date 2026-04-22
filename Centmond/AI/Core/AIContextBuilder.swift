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
        sections.append(netWorthSection(context: context))
        sections.append(subscriptionSection(context: context))
        sections.append(recurringSection(context: context))
        sections.append(forecastSection(context: context))
        sections.append(householdSection(context: context))
        // Review Queue hidden — keep it out of the AI context for now.
        // sections.append(reviewQueueSection(context: context))

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

    static func buildRecurringOnly(context: ModelContext) -> String {
        recurringSection(context: context)
    }

    static func buildSubscriptionsOnly(context: ModelContext) -> String {
        subscriptionSection(context: context)
    }

    static func buildAccountsOnly(context: ModelContext) -> String {
        accountSection(context: context)
    }

    static func buildNetWorthOnly(context: ModelContext) -> String {
        netWorthSection(context: context)
    }

    static func buildForecastOnly(context: ModelContext, horizonDays: Int = 30) -> String {
        forecastSection(context: context, horizonDays: horizonDays)
    }

    static func buildReviewQueueOnly(context: ModelContext) -> String {
        reviewQueueSection(context: context)
    }

    // MARK: - Forecast

    /// Runs `ForecastEngine` for a 30-day horizon and summarises it as a
    /// compact block the model can reason over. Includes starting/ending
    /// balance, projected totals, lowest-point, risk flags, and the top
    /// upcoming obligations. Kept short — this section ships in every
    /// full-context build so a large dump would crowd out other slices.
    private static func forecastSection(context: ModelContext, horizonDays: Int = 30) -> String {
        guard let subs = try? context.fetch(FetchDescriptor<Subscription>()),
              let recurring = try? context.fetch(FetchDescriptor<RecurringTransaction>()),
              let goals = try? context.fetch(FetchDescriptor<Goal>()),
              let accounts = try? context.fetch(FetchDescriptor<Account>())
        else { return "" }

        let start = Calendar.current.date(byAdding: .day, value: -60, to: .now) ?? .now
        let history = fetchTransactions(context: context, from: start, to: .now)

        let startingBalance = accounts
            .filter { !$0.isArchived && !$0.isClosed && $0.includeInNetWorth }
            .reduce(Decimal.zero) { $0 + $1.currentBalance }

        let horizon = ForecastEngine.build(
            ForecastEngine.Inputs(
                startingBalance: startingBalance,
                subscriptions: subs,
                recurring: recurring,
                goals: goals,
                history: history
            ),
            horizonDays: horizonDays
        )

        var lines = ["FORECAST (next \(horizonDays)d)"]
        lines.append("  Starting balance: \(dollars(horizon.summary.startingBalance))")
        lines.append("  Ending balance (expected): \(dollars(horizon.summary.endingExpectedBalance))")
        lines.append("  Projected income: \(dollars(horizon.summary.totalProjectedIncome))")
        lines.append("  Projected bills + subs: \(dollars(horizon.summary.totalProjectedObligations))")
        lines.append("  Projected typical spend: \(dollars(horizon.summary.totalProjectedDiscretionary))")
        lines.append("  Lowest point: \(dollars(horizon.summary.lowestExpectedBalance)) on \(shortDate(horizon.summary.lowestExpectedBalanceDate))")
        if let neg = horizon.summary.firstExpectedNegativeDate {
            lines.append("  OVERDRAFT RISK: expected balance goes negative on \(shortDate(neg))")
        } else if let risk = horizon.summary.firstAtRiskDate {
            lines.append("  Tight window: confidence band dips below zero on \(shortDate(risk))")
        }

        // Top 5 upcoming events by absolute magnitude.
        let topEvents = horizon.days
            .flatMap { $0.events }
            .sorted { abs(($0.delta as NSDecimalNumber).doubleValue) > abs(($1.delta as NSDecimalNumber).doubleValue) }
            .prefix(5)
        if !topEvents.isEmpty {
            lines.append("  Top upcoming events:")
            for ev in topEvents {
                let sign = ev.delta > 0 ? "+" : "−"
                lines.append("    \(shortDate(ev.date)) · \(ev.name): \(sign)\(dollars(abs(ev.delta)))")
            }
        }

        return lines.joined(separator: "\n")
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

        // Rule counts per goal, in one fetch — cheaper than a fetch per goal.
        let ruleDescriptor = FetchDescriptor<GoalAllocationRule>(
            predicate: #Predicate { $0.isActive }
        )
        let activeRules = (try? context.fetch(ruleDescriptor)) ?? []
        let ruleCountByGoal: [UUID: Int] = activeRules.reduce(into: [:]) { acc, rule in
            guard let id = rule.goal?.id else { return }
            acc[id, default: 0] += 1
        }

        var lines = ["ACTIVE GOALS"]
        for g in goals {
            let pct = Int(g.progressPercentage * 100)
            var detail = "  \(g.name): \(dollars(g.currentAmount)) / \(dollars(g.targetAmount)) (\(pct)%)"
            if let deadline = g.targetDate {
                detail += " due \(shortDate(deadline))"
            }
            if let monthly = g.monthlyContribution, monthly > 0 {
                detail += " — target \(dollars(monthly))/mo"
            }

            // Trajectory: this-month vs 3-mo avg + projected completion — the
            // model uses these to suggest whether a goal is on track, needs a
            // redirection, or would benefit from an allocation rule.
            let thisMonth = GoalAnalytics.thisMonthContribution(g)
            let avg = GoalAnalytics.averageMonthlyContribution(g)
            if thisMonth > 0 || avg > 0 {
                detail += " · this month \(dollars(thisMonth)), 3mo avg \(dollars(avg))"
            }
            if let projected = GoalAnalytics.projectedCompletion(g) {
                detail += " · projected \(shortDate(projected))"
            }

            // Funding-source breakdown only when there's material mix.
            let breakdown = GoalAnalytics.breakdownByKind(g)
            let sources: [String] = [
                (GoalContributionKind.fromIncome, "income"),
                (GoalContributionKind.autoRule, "rule"),
                (GoalContributionKind.fromTransfer, "transfer"),
                (GoalContributionKind.manual, "manual"),
            ].compactMap { pair in
                let (k, label) = pair
                let v = breakdown[k] ?? 0
                return v > 0 ? "\(label) \(dollars(v))" : nil
            }
            if !sources.isEmpty {
                detail += " · sources: \(sources.joined(separator: ", "))"
            }

            let ruleCount = ruleCountByGoal[g.id] ?? 0
            if ruleCount > 0 {
                detail += " · \(ruleCount) active rule\(ruleCount == 1 ? "" : "s")"
            }

            lines.append(detail)
        }

        // Unallocated income nudge — lets the model suggest a redirection
        // even when the user hasn't mentioned it.
        let unallocated = GoalAnalytics.unallocatedIncomeThisMonth(context: context)
        if unallocated.count > 0 {
            lines.append("  (Unallocated income this month: \(dollars(unallocated.total)) across \(unallocated.count) tx)")
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

    // MARK: - Net Worth

    /// Snapshot-driven net-worth block. Rolling deltas (30/90/365d),
    /// trend slope, runway months from cash, asset/liability mix as
    /// % shares, and any open milestones derived from history. Only
    /// emitted when there are at least 7 snapshots — otherwise the
    /// numbers would be too volatile to reason over.
    private static func netWorthSection(context: ModelContext) -> String {
        let snaps = (try? context.fetch(FetchDescriptor<NetWorthSnapshot>(
            sortBy: [SortDescriptor(\.date)]
        ))) ?? []
        guard let latest = snaps.last, snaps.count >= 7 else { return "" }

        var lines = ["NET WORTH"]
        lines.append("  Current: \(dollars(latest.netWorth)) (assets \(dollars(latest.totalAssets)) − liabilities \(dollars(latest.totalLiabilities)))")

        // Rolling deltas
        for (label, days) in [("30d", 30), ("90d", 90), ("1y", 365)] {
            if let baseline = closestSnapshot(snaps, daysBack: days, from: latest.date) {
                let delta = latest.netWorth - baseline.netWorth
                let pct: Double = baseline.netWorth != 0
                    ? Double(truncating: (delta / abs(baseline.netWorth)) as NSDecimalNumber) * 100
                    : 0
                let sign = delta >= 0 ? "+" : "−"
                lines.append("  \(label): \(sign)\(dollars(abs(delta))) (\(String(format: "%+.1f%%", pct)))")
            }
        }

        // Trend slope ($/day over last 30d, simple endpoints)
        if let baseline30 = closestSnapshot(snaps, daysBack: 30, from: latest.date),
           latest.date > baseline30.date {
            let days = max(1.0, latest.date.timeIntervalSince(baseline30.date) / 86_400)
            let slope = (latest.netWorth - baseline30.netWorth) / Decimal(days)
            lines.append("  Slope (30d): \(dollars(slope))/day")
        }

        // Asset / liability mix
        let accounts = (try? context.fetch(FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isArchived && !$0.isClosed && $0.includeInNetWorth }
        ))) ?? []
        let assetMix = mixLine(accounts: accounts.filter { !$0.type.isLiability },
                               total: latest.totalAssets,
                               liabilities: false)
        if !assetMix.isEmpty { lines.append("  Asset mix: \(assetMix)") }

        let liabMix = mixLine(accounts: accounts.filter { $0.type.isLiability },
                              total: latest.totalLiabilities,
                              liabilities: true)
        if !liabMix.isEmpty { lines.append("  Liability mix: \(liabMix)") }

        // Cash runway in months (cash-like balance / 30d avg burn × 30)
        if let runway = runwayMonths(context: context, accounts: accounts) {
            lines.append("  Cash runway: \(String(format: "%.1f", runway)) months")
        }

        // Open milestones in the last 30d (compact)
        let recent = NetWorthMilestoneDetector.detect(from: snaps).filter {
            Calendar.current.dateComponents([.day], from: $0.date, to: latest.date).day ?? 0 <= 30
        }
        if !recent.isEmpty {
            let titles = recent.prefix(3).map(\.title).joined(separator: ", ")
            lines.append("  Recent milestones (30d): \(titles)")
        }

        return lines.joined(separator: "\n")
    }

    private static func closestSnapshot(_ snaps: [NetWorthSnapshot], daysBack: Int, from date: Date) -> NetWorthSnapshot? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -daysBack, to: date) ?? .distantPast
        return snaps.last(where: { $0.date <= cutoff })
    }

    private static func mixLine(accounts: [Account], total: Decimal, liabilities: Bool) -> String {
        guard total > 0, !accounts.isEmpty else { return "" }
        var totals: [AccountType: Decimal] = [:]
        for a in accounts {
            let v = liabilities ? abs(a.currentBalance) : a.currentBalance
            guard v > 0 else { continue }
            totals[a.type, default: 0] += v
        }
        let parts = totals
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { type, value -> String in
                let pct = Double(truncating: (value / total) as NSDecimalNumber) * 100
                return "\(type.displayName) \(Int(pct))%"
            }
        return parts.joined(separator: ", ")
    }

    private static func runwayMonths(context: ModelContext, accounts: [Account]) -> Double? {
        let cash = accounts
            .filter { $0.type == .checking || $0.type == .savings || $0.type == .cash }
            .reduce(Decimal.zero) { $0 + $1.currentBalance }
        guard cash > 0 else { return nil }

        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        let txDesc = FetchDescriptor<Transaction>(predicate: #Predicate {
            $0.date >= cutoff && !$0.isIncome && !$0.isTransfer
        })
        guard let txns = try? context.fetch(txDesc), !txns.isEmpty else { return nil }
        let monthly = txns.reduce(Decimal.zero) { $0 + $1.amount }
        guard monthly > 0 else { return nil }
        let ratio = (cash / monthly) as NSDecimalNumber
        return ratio.doubleValue
    }

    // MARK: - Subscriptions

    private static func subscriptionSection(context: ModelContext) -> String {
        let descriptor = FetchDescriptor<Subscription>()
        guard let allSubs = try? context.fetch(descriptor) else { return "" }
        let subs = allSubs.filter { $0.status == .active || $0.status == .trial }
        guard !subs.isEmpty else { return "" }

        let monthlyTotal = subs.reduce(Decimal.zero) { $0 + $1.monthlyCost }
        let next7 = SubscriptionForecast.projected(for: subs, next: 7)
        let next30 = SubscriptionForecast.projected(for: subs, next: 30)

        var lines = ["ACTIVE SUBSCRIPTIONS (total \(dollars(monthlyTotal))/mo; next 7d \(dollars(next7)); next 30d \(dollars(next30)))"]

        // Top 5 by monthly cost — keeps the prompt size bounded for users
        // with 30+ subscriptions while still surfacing the biggest line items
        // the AI should reason about.
        let topByCost = subs.sorted {
            NSDecimalNumber(decimal: $0.monthlyCost).doubleValue
              > NSDecimalNumber(decimal: $1.monthlyCost).doubleValue
        }.prefix(5)

        for s in topByCost {
            let cycleName = s.billingCycle.rawValue
            var detail = "  \(s.serviceName): \(dollars(s.amount))/\(cycleName)"
            let daysUntil = Calendar.current.dateComponents([.day], from: Date(), to: s.nextPaymentDate).day ?? 0
            if daysUntil >= 0 {
                detail += " (renews in \(daysUntil)d)"
            }
            if s.isTrial, let end = s.trialEndsAt {
                let trialDays = Calendar.current.dateComponents([.day], from: Date(), to: end).day ?? 0
                if trialDays >= 0 { detail += " [trial ends in \(trialDays)d]" }
            }
            if s.isPastDue { detail += " [past due]" }
            if s.wasImpulseSignup { detail += " [late-night signup]" }
            lines.append(detail)
        }
        if subs.count > 5 {
            lines.append("  …and \(subs.count - 5) more")
        }

        // Untouched-for-60-days roll-up — gives the model a single line to
        // reason about cancellation candidates without enumerating every sub.
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: .now) ?? .now
        let unused = subs.filter { $0.status == .active && $0.createdAt < cutoff && $0.updatedAt < cutoff }
        if !unused.isEmpty {
            let names = unused.prefix(3).map(\.serviceName).joined(separator: ", ")
            let suffix = unused.count > 3 ? ", +\(unused.count - 3) more" : ""
            lines.append("  POTENTIALLY UNUSED (60+ days untouched): \(names)\(suffix)")
        }

        return lines.joined(separator: "\n")
    }

    /// Daily recurring-baseline series for the Prediction page. Given a date
    /// range, returns projected subscription outflow bucketed by calendar
    /// day. Lets the prediction chart render recurring spend as a distinct
    /// layer underneath discretionary — so forecasts don't double-count
    /// fixed costs as "volatile" spend.
    static func recurringBaseline(
        from: Date,
        to: Date,
        context: ModelContext
    ) -> [Date: Decimal] {
        let descriptor = FetchDescriptor<Subscription>()
        guard let allSubs = try? context.fetch(descriptor) else { return [:] }
        let subs = allSubs.filter { $0.status == .active || $0.status == .trial }
        return SubscriptionForecast.dailyBaseline(for: subs, from: from, to: to)
    }

    // MARK: - Recurring (templates)

    /// Active recurring transactions — salary, rent, utilities, gym,
    /// etc. Distinct from `subscriptionSection` because subscriptions
    /// are purely outflow streams the user might cancel; recurring
    /// templates include income (salary) and obligations (rent) the
    /// model needs to reason about for cash-flow forecasting.
    private static func recurringSection(context: ModelContext) -> String {
        let descriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive }
        )
        guard let templates = try? context.fetch(descriptor), !templates.isEmpty else { return "" }

        let cal = Calendar.current
        guard let horizon = cal.date(byAdding: .day, value: 30, to: .now) else { return "" }

        // Project each template forward, bucket by income/expense.
        var incomeAmount: Decimal = 0
        var expenseAmount: Decimal = 0
        var upcoming: [(date: Date, name: String, amount: Decimal, isIncome: Bool)] = []

        for template in templates {
            var cursor = template.nextOccurrence
            var safety = 0
            while cursor < .now && safety < 60 {
                cursor = template.frequency.nextDate(after: cursor)
                safety += 1
            }
            var iter = 0
            while cursor <= horizon && iter < 60 {
                if template.isIncome { incomeAmount += template.amount }
                else                 { expenseAmount += template.amount }
                upcoming.append((cursor, template.name, template.amount, template.isIncome))
                cursor = template.frequency.nextDate(after: cursor)
                iter += 1
            }
        }

        let net = incomeAmount - expenseAmount
        var lines = [
            "RECURRING (next 30d: in \(dollars(incomeAmount)), out \(dollars(expenseAmount)), net \(dollars(net)))"
        ]

        // Top 5 upcoming events by date so the model can reference
        // "your $2,500 rent on the 1st" without us listing 30 lines.
        let next5 = upcoming.sorted { $0.date < $1.date }.prefix(5)
        for event in next5 {
            let days = cal.dateComponents([.day], from: .now, to: event.date).day ?? 0
            let when = days <= 0 ? "today" : "in \(days)d"
            let arrow = event.isIncome ? "+" : "-"
            lines.append("  \(arrow)\(dollars(event.amount)) \(event.name) (\(when))")
        }
        if upcoming.count > 5 {
            lines.append("  …and \(upcoming.count - 5) more in the next 30d")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Household

    private static func householdSection(context: ModelContext) -> String {
        let descriptor = FetchDescriptor<HouseholdMember>(
            sortBy: [SortDescriptor(\.joinedAt)]
        )
        guard let all = try? context.fetch(descriptor), !all.isEmpty else { return "" }
        let members = all.filter(\.isActive)
        guard !members.isEmpty else { return "" }

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
            let netWorth = HouseholdService.netWorth(for: member, in: context)
            var tail: [String] = []
            if memberSpend > 0 { tail.append("\(dollars(memberSpend)) spent") }
            if netWorth != 0 { tail.append("net worth \(dollars(netWorth))") }
            if !tail.isEmpty {
                lines.append("  \(member.name): \(tail.joined(separator: "; "))")
            }
        }

        // Settle-up ledger (P7): show members with outstanding balances.
        let balances = HouseholdService.balances(in: context)
        let owed = balances.filter { $0.amount > 0 }
        let owes = balances.filter { $0.amount < 0 }
        if !owed.isEmpty || !owes.isEmpty {
            lines.append("SETTLE-UP:")
            for b in owed {
                lines.append("  \(b.member.name) is owed \(dollars(b.amount))")
            }
            for b in owes {
                lines.append("  \(b.member.name) owes \(dollars(-b.amount))")
            }
        }

        // Open splits summary.
        let shareDescriptor = FetchDescriptor<ExpenseShare>()
        let shares = (try? context.fetch(shareDescriptor)) ?? []
        let openShares = shares.filter { $0.status == .owed }
        if !openShares.isEmpty {
            lines.append("OPEN SPLITS: \(openShares.count) share row\(openShares.count == 1 ? "" : "s") awaiting settle-up")
        }

        // Members with no attribution at all — useful hint for AI advice.
        let unattributed = members.filter { $0.transactions.isEmpty }
        if !unattributed.isEmpty {
            lines.append("UNATTRIBUTED MEMBERS: " + unattributed.map(\.name).joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Review Queue

    /// One-paragraph snapshot of what the Review Queue currently holds.
    /// Lets chat answer "what needs my attention?" without pulling raw
    /// detector output. Empty string when there's nothing in the queue
    /// (no section rather than a noisy "0 items" line).
    private static func reviewQueueSection(context: ModelContext) -> String {
        let items = ReviewQueueService.buildQueue(in: context)
        guard !items.isEmpty else { return "" }

        let total = items.count
        let byReason = Dictionary(grouping: items, by: \.reason)
        let blockers = items.filter { $0.severity == .blocker }.count

        var lines = ["REVIEW QUEUE: \(total) \(total == 1 ? "item" : "items") awaiting review"]
        if blockers > 0 {
            lines.append("  \(blockers) blocker\(blockers == 1 ? "" : "s") — resolve before relying on balance math")
        }

        let breakdown = ReviewReasonCode.allCases
            .compactMap { reason -> String? in
                guard let count = byReason[reason]?.count, count > 0 else { return nil }
                return "\(reason.title): \(count)"
            }
            .prefix(6)
        if !breakdown.isEmpty {
            lines.append("  By reason — " + breakdown.joined(separator: ", "))
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
