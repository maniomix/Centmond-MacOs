import Foundation

// Pure compute. Callers pass already-fetched arrays via ReportEngine.Inputs;
// the engine filters, buckets, and rolls up. No SwiftData, no SwiftUI —
// so the same routine serves the on-screen preview and every exporter.

enum ReportEngine {

    struct Inputs {
        var transactions: [Transaction]
        var accounts: [Account]
        var categories: [BudgetCategory]
        var netWorthSnapshots: [NetWorthSnapshot]
        var subscriptions: [Subscription]
        var recurring: [RecurringTransaction]
        var goals: [Goal]
        var goalContributions: [GoalContribution]
        var monthlyBudgets: [MonthlyBudget]
        var monthlyTotalBudgets: [MonthlyTotalBudget]
        var currencyCode: String
        var now: Date
        var calendar: Calendar

        init(
            transactions: [Transaction],
            accounts: [Account] = [],
            categories: [BudgetCategory] = [],
            netWorthSnapshots: [NetWorthSnapshot] = [],
            subscriptions: [Subscription] = [],
            recurring: [RecurringTransaction] = [],
            goals: [Goal] = [],
            goalContributions: [GoalContribution] = [],
            monthlyBudgets: [MonthlyBudget] = [],
            monthlyTotalBudgets: [MonthlyTotalBudget] = [],
            currencyCode: String = "USD",
            now: Date = .now,
            calendar: Calendar = .current
        ) {
            self.transactions = transactions
            self.accounts = accounts
            self.categories = categories
            self.netWorthSnapshots = netWorthSnapshots
            self.subscriptions = subscriptions
            self.recurring = recurring
            self.goals = goals
            self.goalContributions = goalContributions
            self.monthlyBudgets = monthlyBudgets
            self.monthlyTotalBudgets = monthlyTotalBudgets
            self.currencyCode = currencyCode
            self.now = now
            self.calendar = calendar
        }
    }

    static func run(_ def: ReportDefinition, inputs: Inputs) -> ReportResult {
        let (start, end) = def.range.resolve(now: inputs.now, calendar: inputs.calendar)
        let filtered = filter(inputs.transactions, range: start...end, filter: def.filter)

        let body = compute(
            kind: def.kind,
            transactions: filtered,
            def: def,
            inputs: inputs,
            rangeStart: start,
            rangeEnd: end
        )

        let baselined = applyComparison(body: body, def: def, inputs: inputs, rangeStart: start, rangeEnd: end)

        let summary = buildSummary(
            def: def,
            body: baselined,
            transactionCount: filtered.count,
            rangeStart: start,
            rangeEnd: end,
            currencyCode: inputs.currencyCode
        )

        return ReportResult(
            definition: def,
            summary: summary,
            body: baselined,
            generatedAt: inputs.now
        )
    }

    // MARK: - Comparison baseline

    private static func applyComparison(
        body: ReportBody,
        def: ReportDefinition,
        inputs: Inputs,
        rangeStart: Date,
        rangeEnd: Date
    ) -> ReportBody {
        guard def.comparison != .none,
              let baselineRange = baselineRange(for: (rangeStart, rangeEnd), mode: def.comparison, calendar: inputs.calendar)
        else { return body }

        let baselineTxns = filter(inputs.transactions, range: baselineRange.start...baselineRange.end, filter: def.filter)

        switch body {
        case .periodSeries(var series):
            let baseSeries = buildPeriodSeries(baselineTxns, groupBy: def.groupBy, start: baselineRange.start, end: baselineRange.end, calendar: inputs.calendar)
            series.baselineBuckets = baseSeries.buckets
            return .periodSeries(series)

        case .categoryBreakdown(var breakdown):
            let baseline = buildCategoryBreakdown(baselineTxns)
            let baseByID = Dictionary(uniqueKeysWithValues: baseline.slices.map { ($0.id, $0.amount) })
            breakdown.slices = breakdown.slices.map { slice in
                var s = slice
                s.deltaVsBaseline = slice.amount - (baseByID[slice.id] ?? 0)
                return s
            }
            return .categoryBreakdown(breakdown)

        default:
            return body
        }
    }

    private static func baselineRange(
        for range: (start: Date, end: Date),
        mode: ReportComparisonMode,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        switch mode {
        case .none:
            return nil
        case .priorPeriod:
            let length = range.end.timeIntervalSince(range.start)
            let end = range.start.addingTimeInterval(-1)
            let start = end.addingTimeInterval(-length)
            return (start, end)
        case .priorYear:
            guard
                let start = calendar.date(byAdding: .year, value: -1, to: range.start),
                let end   = calendar.date(byAdding: .year, value: -1, to: range.end)
            else { return nil }
            return (start, end)
        }
    }

    // MARK: - Filtering

    private static func filter(
        _ txns: [Transaction],
        range: ClosedRange<Date>,
        filter f: ReportFilter
    ) -> [Transaction] {
        txns.filter { tx in
            guard range.contains(tx.date) else { return false }
            if !f.includeTransfers && tx.isTransfer { return false }
            if f.onlyReviewed && !tx.isReviewed { return false }

            switch f.direction {
            case .any:     break
            case .income:  if !tx.isIncome { return false }
            case .expense: if tx.isIncome { return false }
            }

            if !f.accountIDs.isEmpty, let id = tx.account?.id, !f.accountIDs.contains(id) { return false }
            if !f.accountIDs.isEmpty, tx.account == nil { return false }

            if !f.categoryIDs.isEmpty, let id = tx.category?.id, !f.categoryIDs.contains(id) { return false }
            if !f.categoryIDs.isEmpty, tx.category == nil { return false }

            if !f.payees.isEmpty, !f.payees.contains(tx.payee) { return false }

            if !f.tagIDs.isEmpty {
                let ids = Set(tx.tags.map(\.id))
                if ids.isDisjoint(with: f.tagIDs) { return false }
            }

            if !f.householdMemberIDs.isEmpty {
                guard let mid = tx.householdMember?.id, f.householdMemberIDs.contains(mid) else { return false }
            }

            if let minA = f.minAmount, tx.amount < minA { return false }
            if let maxA = f.maxAmount, tx.amount > maxA { return false }

            return true
        }
    }

    // MARK: - Per-kind compute

    private static func compute(
        kind: ReportKind,
        transactions: [Transaction],
        def: ReportDefinition,
        inputs: Inputs,
        rangeStart: Date,
        rangeEnd: Date
    ) -> ReportBody {
        switch kind {
        case .incomeVsExpense, .cashFlow, .custom, .annualSummary:
            if transactions.isEmpty {
                return .empty(reason: inputs.transactions.isEmpty ? .noTransactionsInRange : .allFilteredOut)
            }
            return .periodSeries(buildPeriodSeries(transactions, groupBy: def.groupBy, start: rangeStart, end: rangeEnd, calendar: inputs.calendar))

        case .spendingByCategory, .categoryDeepDive:
            if transactions.isEmpty {
                return .empty(reason: inputs.transactions.isEmpty ? .noTransactionsInRange : .allFilteredOut)
            }
            return .categoryBreakdown(buildCategoryBreakdown(transactions))

        case .merchantLeaderboard:
            if transactions.isEmpty {
                return .empty(reason: inputs.transactions.isEmpty ? .noTransactionsInRange : .allFilteredOut)
            }
            return .merchantLeaderboard(buildMerchantLeaderboard(transactions, topN: def.display.topN, groupBy: def.groupBy, start: rangeStart, end: rangeEnd, calendar: inputs.calendar))

        case .budgetPerformance:
            return .heatmap(buildBudgetHeatmap(transactions: transactions, categories: inputs.categories, monthly: inputs.monthlyBudgets, start: rangeStart, end: rangeEnd, calendar: inputs.calendar))

        case .netWorth:
            return .netWorth(buildNetWorth(snapshots: inputs.netWorthSnapshots, start: rangeStart, end: rangeEnd))

        case .subscriptions:
            return .subscriptionRoster(buildSubscriptionRoster(inputs.subscriptions))

        case .recurringActivity:
            return .recurringRoster(buildRecurringRoster(inputs.recurring))

        case .goalsProgress:
            return .goalsProgress(buildGoalsProgress(goals: inputs.goals, contributions: inputs.goalContributions, start: rangeStart, end: rangeEnd))
        }
    }

    // MARK: - Builders

    private static func buildPeriodSeries(
        _ txns: [Transaction],
        groupBy: ReportGroupBy,
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> PeriodSeries {
        var bucketMap: [String: PeriodSeries.Bucket] = [:]

        for tx in txns {
            let key = bucketKey(for: tx.date, groupBy: groupBy, calendar: calendar)
            let range = bucketRange(for: tx.date, groupBy: groupBy, calendar: calendar)

            var b = bucketMap[key] ?? PeriodSeries.Bucket(
                id: key,
                label: bucketLabel(for: range.start, groupBy: groupBy, calendar: calendar),
                start: range.start,
                end: range.end,
                income: 0,
                expense: 0,
                transactionCount: 0
            )

            if tx.isIncome {
                b.income += tx.amount
            } else {
                b.expense += tx.amount
            }
            b.transactionCount += 1
            bucketMap[key] = b
        }

        let buckets = bucketMap.values.sorted { $0.start < $1.start }
        let incomeTotal = buckets.reduce(Decimal.zero) { $0 + $1.income }
        let expenseTotal = buckets.reduce(Decimal.zero) { $0 + $1.expense }
        let avg: Decimal = buckets.isEmpty ? 0 : (incomeTotal - expenseTotal) / Decimal(buckets.count)
        let savingsRate: Double? = incomeTotal > 0
            ? Double(truncating: ((incomeTotal - expenseTotal) / incomeTotal) as NSDecimalNumber)
            : nil

        return PeriodSeries(
            buckets: buckets,
            totals: .init(income: incomeTotal, expense: expenseTotal, averagePerBucket: avg, savingsRate: savingsRate),
            baselineBuckets: nil
        )
    }

    private static func buildCategoryBreakdown(_ txns: [Transaction]) -> CategoryBreakdown {
        // Only expenses contribute to a category breakdown; income is
        // surfaced separately when needed.
        let expenses = txns.filter { !$0.isIncome && !$0.isTransfer }
        var amountByCat: [String: (name: String, colorHex: String?, amount: Decimal, count: Int)] = [:]
        var uncategorized: Decimal = 0

        for tx in expenses {
            if let cat = tx.category {
                let key = cat.id.uuidString
                var entry = amountByCat[key] ?? (cat.name, cat.colorHex, 0, 0)
                entry.amount += tx.amount
                entry.count  += 1
                amountByCat[key] = entry
            } else {
                uncategorized += tx.amount
            }
        }

        let total = amountByCat.values.reduce(Decimal.zero) { $0 + $1.amount } + uncategorized
        let totalDouble = Double(truncating: total as NSDecimalNumber)

        var slices: [CategoryBreakdown.Slice] = amountByCat.map { key, v in
            let pct = totalDouble > 0
                ? Double(truncating: v.amount as NSDecimalNumber) / totalDouble
                : 0
            return .init(
                id: key,
                name: v.name,
                colorHex: v.colorHex,
                amount: v.amount,
                transactionCount: v.count,
                percentOfTotal: pct,
                deltaVsBaseline: nil,
                sparkline: nil
            )
        }
        slices.sort { $0.amount > $1.amount }

        return CategoryBreakdown(
            slices: slices,
            uncategorizedAmount: uncategorized,
            totalAmount: total
        )
    }

    private static func buildMerchantLeaderboard(
        _ txns: [Transaction],
        topN: Int,
        groupBy: ReportGroupBy,
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> MerchantLeaderboard {
        let expenses = txns.filter { !$0.isIncome && !$0.isTransfer }
        var byPayee: [String: (display: String, amount: Decimal, count: Int, first: Date, last: Date, perBucket: [String: Decimal])] = [:]

        for tx in expenses {
            let key = tx.payee.lowercased()
            let bucketKey = bucketKey(for: tx.date, groupBy: groupBy, calendar: calendar)
            var e = byPayee[key] ?? (tx.payee, 0, 0, tx.date, tx.date, [:])
            e.amount += tx.amount
            e.count  += 1
            e.first   = min(e.first, tx.date)
            e.last    = max(e.last, tx.date)
            e.perBucket[bucketKey, default: 0] += tx.amount
            byPayee[key] = e
        }

        let total = byPayee.values.reduce(Decimal.zero) { $0 + $1.amount }
        let totalD = Double(truncating: total as NSDecimalNumber)

        let bucketKeysOrdered = distinctBucketKeys(start: start, end: end, groupBy: groupBy, calendar: calendar)

        var rows: [MerchantLeaderboard.Row] = byPayee.map { key, v in
            let avg: Decimal = v.count == 0 ? 0 : v.amount / Decimal(v.count)
            let pct = totalD > 0 ? Double(truncating: v.amount as NSDecimalNumber) / totalD : 0
            let sparkline = bucketKeysOrdered.map { v.perBucket[$0] ?? 0 }
            return .init(
                id: key,
                displayName: v.display,
                amount: v.amount,
                transactionCount: v.count,
                averageAmount: avg,
                percentOfTotal: pct,
                firstSeen: v.first,
                lastSeen: v.last,
                sparkline: sparkline
            )
        }
        rows.sort { $0.amount > $1.amount }
        if topN > 0 { rows = Array(rows.prefix(topN)) }

        return MerchantLeaderboard(rows: rows, totalAmount: total)
    }

    private static func buildNetWorth(
        snapshots: [NetWorthSnapshot],
        start: Date,
        end: Date
    ) -> NetWorthBody {
        let inRange = snapshots
            .filter { $0.date >= start && $0.date <= end }
            .sorted { $0.date < $1.date }

        let points = inRange.map {
            NetWorthBody.Point(date: $0.date, assets: $0.totalAssets, liabilities: $0.totalLiabilities, netWorth: $0.netWorth)
        }

        return NetWorthBody(
            snapshots: points,
            startingNetWorth: points.first?.netWorth ?? 0,
            endingNetWorth:   points.last?.netWorth ?? 0,
            assetsEnd:        points.last?.assets ?? 0,
            liabilitiesEnd:   points.last?.liabilities ?? 0
        )
    }

    // MARK: - Subscriptions / recurring / goals / budget-perf builders

    private static func buildSubscriptionRoster(_ subs: [Subscription]) -> SubscriptionRoster {
        let rows: [SubscriptionRoster.Row] = subs.map { s in
            .init(
                id: s.id.uuidString,
                serviceName: s.serviceName,
                categoryName: s.categoryName,
                statusLabel: s.status.displayName,
                monthlyCost: s.monthlyCost,
                annualCost: s.annualCost,
                nextPaymentDate: s.nextPaymentDate,
                firstChargeDate: s.firstChargeDate,
                isTrial: s.isTrial
            )
        }
        .sorted { $0.monthlyCost > $1.monthlyCost }

        let active    = subs.filter { $0.status == .active || $0.status == .trial }
        let paused    = subs.filter { $0.status == .paused }
        let cancelled = subs.filter { $0.status == .cancelled }

        let totalMonthly = active.reduce(Decimal.zero) { $0 + $1.monthlyCost }
        let totalAnnual  = active.reduce(Decimal.zero) { $0 + $1.annualCost }

        return SubscriptionRoster(
            rows: rows,
            totalMonthly: totalMonthly,
            totalAnnual: totalAnnual,
            activeCount: active.count,
            pausedCount: paused.count,
            cancelledCount: cancelled.count
        )
    }

    private static func buildRecurringRoster(_ recurring: [RecurringTransaction]) -> RecurringRoster {
        func normalizedMonthly(amount: Decimal, freq: RecurrenceFrequency) -> Decimal {
            switch freq {
            case .weekly:    return amount * Decimal(52) / Decimal(12)
            case .biweekly:  return amount * Decimal(26) / Decimal(12)
            case .monthly:   return amount
            case .quarterly: return amount / Decimal(3)
            case .annual:    return amount / Decimal(12)
            }
        }

        let rows: [RecurringRoster.Row] = recurring.map { r in
            .init(
                id: r.id.uuidString,
                name: r.name,
                amount: r.amount,
                frequencyLabel: r.frequency.rawValue.capitalized,
                normalizedMonthly: normalizedMonthly(amount: r.amount, freq: r.frequency),
                isIncome: r.isIncome,
                nextOccurrence: r.nextOccurrence,
                isActive: r.isActive
            )
        }

        let active = rows.filter { $0.isActive }
        let expenseRows = active.filter { !$0.isIncome }.sorted { $0.normalizedMonthly > $1.normalizedMonthly }
        let incomeRows  = active.filter {  $0.isIncome }.sorted { $0.normalizedMonthly > $1.normalizedMonthly }

        return RecurringRoster(
            expenseRows: expenseRows,
            incomeRows: incomeRows,
            totalMonthlyExpense: expenseRows.reduce(Decimal.zero) { $0 + $1.normalizedMonthly },
            totalMonthlyIncome:  incomeRows.reduce(Decimal.zero)  { $0 + $1.normalizedMonthly }
        )
    }

    private static func buildGoalsProgress(
        goals: [Goal],
        contributions: [GoalContribution],
        start: Date,
        end: Date
    ) -> GoalsProgressBody {
        let contributionsByGoal: [UUID: Decimal] = contributions.reduce(into: [:]) { acc, c in
            guard c.date >= start && c.date <= end, let goalID = c.goal?.id else { return }
            acc[goalID, default: 0] += c.amount
        }

        let rows: [GoalsProgressBody.Row] = goals.map { g in
            let remaining = max(0, g.targetAmount - g.currentAmount)
            let projected: Date? = {
                guard let m = g.monthlyContribution, m > 0 else { return nil }
                let monthsD = remaining / m
                let months = Int(ceil(Double(truncating: monthsD as NSDecimalNumber)))
                return Calendar.current.date(byAdding: .month, value: max(0, months), to: .now)
            }()
            let pct: Double = g.targetAmount > 0
                ? min(1, Double(truncating: (g.currentAmount / g.targetAmount) as NSDecimalNumber))
                : 0
            return .init(
                id: g.id.uuidString,
                name: g.name,
                icon: g.icon,
                currentAmount: g.currentAmount,
                targetAmount: g.targetAmount,
                percentComplete: pct,
                monthlyContribution: g.monthlyContribution,
                projectedCompletion: projected,
                contributionsInRange: contributionsByGoal[g.id] ?? 0
            )
        }
        .sorted { $0.percentComplete > $1.percentComplete }

        let totalTarget = goals.reduce(Decimal.zero) { $0 + $1.targetAmount }
        let totalCurrent = goals.reduce(Decimal.zero) { $0 + $1.currentAmount }
        let inRange = contributionsByGoal.values.reduce(Decimal.zero, +)

        return GoalsProgressBody(
            rows: rows,
            totalTarget: totalTarget,
            totalCurrent: totalCurrent,
            contributionsInRange: inRange
        )
    }

    private static func buildBudgetHeatmap(
        transactions txns: [Transaction],
        categories: [BudgetCategory],
        monthly: [MonthlyBudget],
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> Heatmap {
        // Rows = categories (sorted by default budget desc, zeros last);
        // Columns = calendar months spanning the range; cells = actual
        // expense total vs effective budget for that (cat, month).

        let monthKeys = distinctBucketKeys(start: start, end: end, groupBy: .month, calendar: calendar)
        let monthStarts: [(key: String, date: Date)] = monthKeys.compactMap { key in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2,
                  let d = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
            else { return nil }
            return (key, d)
        }

        let catsSorted = categories.sorted { $0.budgetAmount > $1.budgetAmount }
        let rowLabels = catsSorted.map(\.name)
        let columnLabels: [String] = monthStarts.map {
            let f = DateFormatter(); f.calendar = calendar; f.dateFormat = "MMM yy"
            return f.string(from: $0.date)
        }

        // budgetMap[catID][monthKey] = override; fallback to category.budgetAmount
        var overrideMap: [UUID: [String: Decimal]] = [:]
        for mb in monthly {
            let key = String(format: "%04d-%02d", mb.year, mb.month)
            overrideMap[mb.categoryID, default: [:]][key] = mb.amount
        }

        // spend[catID][monthKey]
        var spend: [UUID: [String: Decimal]] = [:]
        for tx in txns where !tx.isIncome && !tx.isTransfer {
            guard let catID = tx.category?.id else { continue }
            let key = bucketKey(for: tx.date, groupBy: .month, calendar: calendar)
            spend[catID, default: [:]][key, default: 0] += tx.amount
        }

        var cells: [Heatmap.Cell] = []
        for (rIdx, cat) in catsSorted.enumerated() {
            for (cIdx, m) in monthStarts.enumerated() {
                let actual = spend[cat.id]?[m.key] ?? 0
                let budget = overrideMap[cat.id]?[m.key] ?? cat.budgetAmount
                cells.append(.init(
                    row: rIdx,
                    column: cIdx,
                    value: actual,
                    baseline: budget,
                    overBudget: budget > 0 && actual > budget
                ))
            }
        }

        return Heatmap(
            rowLabels: rowLabels,
            columnLabels: columnLabels,
            cells: cells,
            valueFormat: .currency
        )
    }

    // MARK: - Summary

    private static func buildSummary(
        def: ReportDefinition,
        body: ReportBody,
        transactionCount: Int,
        rangeStart: Date,
        rangeEnd: Date,
        currencyCode: String
    ) -> ReportSummary {
        var kpis: [ReportKPI] = []

        switch body {
        case .periodSeries(let s):
            kpis = [
                .init(id: "income",  label: "Income",   value: s.totals.income,  valueFormat: .currency, tone: .positive, deltaVsBaseline: nil),
                .init(id: "expense", label: "Expenses", value: s.totals.expense, valueFormat: .currency, tone: .negative, deltaVsBaseline: nil),
                .init(id: "net",     label: "Net",      value: s.totals.net,     valueFormat: .currency, tone: s.totals.net >= 0 ? .positive : .negative, deltaVsBaseline: nil)
            ]
            if let sr = s.totals.savingsRate {
                kpis.append(.init(id: "savingsRate", label: "Savings rate", value: Decimal(sr * 100), valueFormat: .percent, tone: sr >= 0 ? .positive : .negative, deltaVsBaseline: nil))
            }

        case .categoryBreakdown(let c):
            kpis = [
                .init(id: "total",     label: "Total",         value: c.totalAmount,     valueFormat: .currency, tone: .neutral, deltaVsBaseline: nil),
                .init(id: "topSlice",  label: "Top category",  value: c.slices.first?.amount ?? 0, valueFormat: .currency, tone: .neutral, deltaVsBaseline: nil),
                .init(id: "uncat",     label: "Uncategorized", value: c.uncategorizedAmount, valueFormat: .currency, tone: c.uncategorizedAmount > 0 ? .warning : .neutral, deltaVsBaseline: nil)
            ]

        case .merchantLeaderboard(let m):
            kpis = [
                .init(id: "total",     label: "Total",        value: m.totalAmount, valueFormat: .currency, tone: .neutral, deltaVsBaseline: nil),
                .init(id: "merchants", label: "Merchants",    value: Decimal(m.rows.count), valueFormat: .integer, tone: .neutral, deltaVsBaseline: nil)
            ]

        case .netWorth(let n):
            let delta = n.endingNetWorth - n.startingNetWorth
            kpis = [
                .init(id: "ending",      label: "Ending",      value: n.endingNetWorth, valueFormat: .currency, tone: .neutral,  deltaVsBaseline: delta),
                .init(id: "assets",      label: "Assets",      value: n.assetsEnd,      valueFormat: .currency, tone: .positive, deltaVsBaseline: nil),
                .init(id: "liabilities", label: "Liabilities", value: n.liabilitiesEnd, valueFormat: .currency, tone: .negative, deltaVsBaseline: nil)
            ]

        case .heatmap(let h):
            let overCount = h.cells.filter(\.overBudget).count
            let total = h.cells.reduce(Decimal.zero) { $0 + $1.value }
            let budgetTotal = h.cells.reduce(Decimal.zero) { $0 + ($1.baseline ?? 0) }
            // Tone rules: Actual warns (orange) when it exceeds budget,
            // greens when under. Dropping deltaVsBaseline on Actual — the
            // generic KPI tile renders "up = green" which reads as good,
            // but for Budget Performance "up" is "over budget" = bad.
            // Over-budget count already conveys the warning signal.
            let actualTone: ReportKPI.Tone
            if budgetTotal <= 0      { actualTone = .neutral }
            else if total > budgetTotal { actualTone = .warning }
            else                        { actualTone = .positive }
            kpis = [
                .init(id: "actual",    label: "Actual",     value: total,        valueFormat: .currency, tone: actualTone, deltaVsBaseline: nil),
                .init(id: "budget",    label: "Budget",     value: budgetTotal,  valueFormat: .currency, tone: .neutral, deltaVsBaseline: nil),
                .init(id: "overCells", label: "Over-budget months", value: Decimal(overCount), valueFormat: .integer, tone: overCount > 0 ? .warning : .positive, deltaVsBaseline: nil)
            ]

        case .subscriptionRoster(let r):
            kpis = [
                .init(id: "monthly", label: "Monthly",   value: r.totalMonthly, valueFormat: .currency, tone: .neutral,  deltaVsBaseline: nil),
                .init(id: "annual",  label: "Annualized",value: r.totalAnnual,  valueFormat: .currency, tone: .neutral,  deltaVsBaseline: nil),
                .init(id: "active",  label: "Active",    value: Decimal(r.activeCount), valueFormat: .integer, tone: .positive, deltaVsBaseline: nil),
                .init(id: "paused",  label: "Paused",    value: Decimal(r.pausedCount), valueFormat: .integer, tone: .warning,  deltaVsBaseline: nil)
            ]

        case .recurringRoster(let r):
            kpis = [
                .init(id: "monthlyIncome",  label: "Monthly income",  value: r.totalMonthlyIncome,  valueFormat: .currency, tone: .positive, deltaVsBaseline: nil),
                .init(id: "monthlyExpense", label: "Monthly expense", value: r.totalMonthlyExpense, valueFormat: .currency, tone: .negative, deltaVsBaseline: nil),
                .init(id: "net",            label: "Net",             value: r.totalMonthlyIncome - r.totalMonthlyExpense, valueFormat: .currency, tone: r.totalMonthlyIncome >= r.totalMonthlyExpense ? .positive : .negative, deltaVsBaseline: nil)
            ]

        case .goalsProgress(let g):
            let pct: Double = g.totalTarget > 0
                ? Double(truncating: (g.totalCurrent / g.totalTarget) as NSDecimalNumber)
                : 0
            kpis = [
                .init(id: "current",       label: "Saved so far", value: g.totalCurrent,         valueFormat: .currency, tone: .positive, deltaVsBaseline: nil),
                .init(id: "target",        label: "Target",       value: g.totalTarget,          valueFormat: .currency, tone: .neutral,  deltaVsBaseline: nil),
                .init(id: "progress",      label: "Progress",     value: Decimal(pct * 100),     valueFormat: .percent,  tone: .neutral,  deltaVsBaseline: nil),
                .init(id: "contributions", label: "Contributions", value: g.contributionsInRange, valueFormat: .currency, tone: .positive, deltaVsBaseline: nil)
            ]

        case .empty:
            break
        }

        return ReportSummary(
            title: def.kind.title,
            subtitle: def.kind.tagline,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            kpis: kpis,
            transactionCount: transactionCount,
            currencyCode: currencyCode
        )
    }

    // MARK: - Bucket helpers

    private static func bucketKey(for date: Date, groupBy: ReportGroupBy, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day, .weekOfYear, .quarter], from: date)
        switch groupBy {
        case .day:     return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        case .week:    return String(format: "%04d-W%02d",     comps.year ?? 0, comps.weekOfYear ?? 0)
        case .month:   return String(format: "%04d-%02d",      comps.year ?? 0, comps.month ?? 0)
        case .quarter: return String(format: "%04d-Q%d",       comps.year ?? 0, comps.quarter ?? 0)
        case .year:    return String(format: "%04d",           comps.year ?? 0)
        }
    }

    private static func bucketRange(for date: Date, groupBy: ReportGroupBy, calendar: Calendar) -> (start: Date, end: Date) {
        let component = groupBy.component
        var cal = calendar
        cal.firstWeekday = 2  // Monday-start weeks; matches most of the app
        let interval = cal.dateInterval(of: component, for: date) ?? DateInterval(start: date, end: date)
        return (interval.start, interval.end)
    }

    private static func bucketLabel(for start: Date, groupBy: ReportGroupBy, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        switch groupBy {
        case .day:     f.dateFormat = "MMM d"
        case .week:    f.dateFormat = "'W'w yy"
        case .month:   f.dateFormat = "MMM yy"
        case .quarter:
            let comps = calendar.dateComponents([.year, .quarter], from: start)
            return "Q\(comps.quarter ?? 0) '\(String(format: "%02d", (comps.year ?? 0) % 100))"
        case .year:    f.dateFormat = "yyyy"
        }
        return f.string(from: start)
    }

    private static func distinctBucketKeys(start: Date, end: Date, groupBy: ReportGroupBy, calendar: Calendar) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        var cursor = start
        let component = groupBy.component

        while cursor <= end {
            let key = bucketKey(for: cursor, groupBy: groupBy, calendar: calendar)
            if seen.insert(key).inserted { keys.append(key) }
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }
}
