import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var allGoals: [Goal]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query private var subscriptions: [Subscription]
    @Query private var monthlyBudgets: [MonthlyBudget]
    @Query private var totalBudgets: [MonthlyTotalBudget]

    // MARK: - State

    @State private var chartStyle: ChartStyle = .bar
    @State private var hoveredDay: Int?
    @State private var hoverLocation: CGPoint = .zero
    @State private var hoveredDonutAngle: Double?
    @State private var hoveredTxID: UUID?
    @State private var hoveredAccountID: UUID?
    @State private var hoveredGoalID: UUID?

    enum ChartStyle: String, CaseIterable {
        case bar, line
        var icon: String { self == .bar ? "chart.bar.fill" : "chart.xyaxis.line" }
    }

    // MARK: - Computed Data

    private var goals: [Goal] {
        allGoals.filter { $0.status == .active }
    }

    private var totalBalance: Decimal {
        accounts.reduce(0) { $0 + $1.currentBalance }
    }

    /// Safe accessor that filters out detached/deleted objects
    private var safeTransactions: [Transaction] {
        transactions.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var monthlyExpenses: [Transaction] {
        safeTransactions.filter { !$0.isIncome && $0.date >= router.selectedMonthStart && $0.date < router.selectedMonthEnd }
    }

    private var monthlySpending: Decimal {
        monthlyExpenses.reduce(0) { $0 + $1.amount }
    }

    private var monthlyIncomeTransactions: [Transaction] {
        safeTransactions.filter { $0.isIncome && $0.date >= router.selectedMonthStart && $0.date < router.selectedMonthEnd }
    }

    private var monthlyIncome: Decimal {
        monthlyIncomeTransactions.reduce(0) { $0 + $1.amount }
    }

    private var safeToSpend: Decimal {
        monthlyIncome - monthlySpending
    }

    private var recentTransactions: [Transaction] {
        Array(safeTransactions.filter {
            $0.date >= router.selectedMonthStart && $0.date < router.selectedMonthEnd
        }.prefix(6))
    }

    private var subscriptionsDueInSelectedMonth: [Subscription] {
        subscriptions.filter { sub in
            sub.status == .active && sub.billingCycle.occursInMonth(
                anchorDate: sub.nextPaymentDate,
                monthStart: router.selectedMonthStart,
                monthEnd: router.selectedMonthEnd
            )
        }
    }

    private var subscriptionsCostForMonth: Decimal {
        subscriptionsDueInSelectedMonth.reduce(.zero) { $0 + $1.amount }
    }

    private var selectedYear: Int { Calendar.current.component(.year, from: router.selectedMonth) }
    private var selectedMonthNum: Int { Calendar.current.component(.month, from: router.selectedMonth) }

    private var totalBudgetAmount: Decimal {
        totalBudgets.first(where: { $0.year == selectedYear && $0.month == selectedMonthNum })?.amount ?? 0
    }

    private var totalBudgeted: Decimal {
        if totalBudgetAmount > 0 { return totalBudgetAmount }
        return categories.reduce(0) { $0 + effectiveBudget(for: $1) }
    }

    private func effectiveBudget(for category: BudgetCategory) -> Decimal {
        monthlyBudgets.first(where: {
            $0.categoryID == category.id && $0.year == selectedYear && $0.month == selectedMonthNum
        })?.amount ?? category.budgetAmount
    }

    private var activeSubscriptionsCost: Decimal {
        subscriptions
            .filter { $0.status == .active }
            .reduce(0) { $0 + $1.monthlyCost }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: CentmondTheme.Spacing.lg) {
                metricsRow
                mainChartsRow
                bottomRow
            }
            .padding(CentmondTheme.Spacing.lg)
        }
        .background(CentmondTheme.Colors.bgPrimary)
    }

    // MARK: - Row 1: Metrics

    private var metricsRow: some View {
        HStack(spacing: CentmondTheme.Spacing.lg) {
            MetricCard(
                title: "Net Worth",
                value: CurrencyFormat.standard(totalBalance),
                icon: "chart.line.uptrend.xyaxis",
                iconColor: CentmondTheme.Colors.accent,
                subtitle: accounts.isEmpty ? nil : monthString
            )

            MetricCard(
                title: "Income",
                value: CurrencyFormat.standard(monthlyIncome),
                icon: "arrow.down.left",
                iconColor: CentmondTheme.Colors.positive,
                subtitle: monthString
            )

            MetricCard(
                title: "Spending",
                value: CurrencyFormat.standard(monthlySpending),
                icon: "arrow.up.right",
                iconColor: CentmondTheme.Colors.negative,
                subtitle: monthString
            )

            MetricCard(
                title: "Safe to Spend",
                value: CurrencyFormat.standard(safeToSpend),
                icon: "shield.checkered",
                iconColor: safeToSpend >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative,
                valueColor: safeToSpend < 0 ? CentmondTheme.Colors.negative : nil,
                subtitle: router.isCurrentMonth ? "\(daysLeftInMonth) days left" : monthString
            )
        }
    }

    // MARK: - Row 2: Charts

    private var mainChartsRow: some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.lg) {
            cashFlowCard
                .frame(maxWidth: .infinity)

            VStack(spacing: CentmondTheme.Spacing.lg) {
                spendingBreakdownCard
                subscriptionsSummaryCard
            }
            .frame(width: 300)
        }
    }

    // MARK: - Row 3: Bottom

    private var bottomRow: some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.lg) {
            recentTransactionsCard
                .frame(maxWidth: .infinity)

            budgetHealthCard
                .frame(maxWidth: .infinity)

            VStack(spacing: CentmondTheme.Spacing.lg) {
                goalsCard
                accountsCard
            }
            .frame(width: 300)
        }
    }

    // MARK: - Cash Flow Card

    private var cashFlowCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cash Flow")
                            .font(CentmondTheme.Typography.heading3)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)

                        Text(monthString)
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }

                    Spacer()

                    // Chart style toggle
                    HStack(spacing: 0) {
                        ForEach(ChartStyle.allCases, id: \.self) { style in
                            Button {
                                withAnimation(CentmondTheme.Motion.layout) {
                                    chartStyle = style
                                }
                            } label: {
                                Image(systemName: style.icon)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(chartStyle == style ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                                    .frame(width: 28, height: 22)
                                    .background(chartStyle == style ? CentmondTheme.Colors.accentSubtle : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

                    HStack(spacing: CentmondTheme.Spacing.md) {
                        HStack(spacing: CentmondTheme.Spacing.xs) {
                            Circle().fill(CentmondTheme.Colors.positive).frame(width: 6, height: 6)
                            Text("Income")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                        HStack(spacing: CentmondTheme.Spacing.xs) {
                            Circle().fill(CentmondTheme.Colors.accent).frame(width: 6, height: 6)
                            Text("Expenses")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }
                }

                if safeTransactions.isEmpty {
                    emptyChartPlaceholder("Add transactions to see cash flow")
                        .frame(minHeight: 200)
                } else {
                    cashFlowChart
                        .frame(minHeight: 200)
                        .animation(CentmondTheme.Motion.layout, value: chartStyle)
                        .overlay {
                            GeometryReader { geo in
                                if let day = hoveredDay,
                                   let data = computeDailyData().first(where: { $0.id == day }) {
                                    let tooltipW: CGFloat = 160
                                    let clampedX = min(max(hoverLocation.x, tooltipW / 2 + 8), geo.size.width - tooltipW / 2 - 8)

                                    chartTooltip(data: data)
                                        .frame(width: tooltipW)
                                        .position(x: clampedX, y: max(hoverLocation.y - 46, 24))
                                        .allowsHitTesting(false)
                                        .transition(.opacity)
                                }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Spending Breakdown Card

    private var spendingBreakdownCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Spending by Category")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                if monthlyExpenses.isEmpty {
                    emptyChartPlaceholder("No expenses this month")
                } else {
                    VStack(spacing: CentmondTheme.Spacing.md) {
                        // Donut chart centered
                        ZStack {
                            spendingDonut
                                .frame(width: 110, height: 110)
                            donutCenterLabel
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 110)

                        // Legend — full width rows, no horizontal squeeze
                        VStack(spacing: 0) {
                            ForEach(Array(computeCategorySpending().prefix(5).enumerated()), id: \.element.name) { index, item in
                                HStack(spacing: CentmondTheme.Spacing.sm) {
                                    Circle()
                                        .fill(item.color)
                                        .frame(width: 7, height: 7)

                                    Text(item.name)
                                        .font(CentmondTheme.Typography.caption)
                                        .foregroundStyle(
                                            selectedDonutCategory == item.name
                                                ? CentmondTheme.Colors.textPrimary
                                                : CentmondTheme.Colors.textSecondary
                                        )
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(CurrencyFormat.abbreviated(item.amount))
                                        .font(CentmondTheme.Typography.captionMedium)
                                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                }
                                .padding(.vertical, CentmondTheme.Spacing.xs)

                                if index < computeCategorySpending().prefix(5).count - 1 {
                                    Divider()
                                        .background(CentmondTheme.Colors.strokeSubtle)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Donut center label
    private var donutCenterLabel: some View {
        VStack(spacing: 1) {
            if let name = selectedDonutCategory,
               let item = computeCategorySpending().first(where: { $0.name == name }) {
                Text(name)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .lineLimit(1)
                Text(CurrencyFormat.standard(Decimal(item.amount)))
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
            } else {
                Text("Total")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Text(CurrencyFormat.standard(monthlySpending))
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
            }
        }
        .animation(CentmondTheme.Motion.micro, value: selectedDonutCategory)
    }

    private var selectedDonutCategory: String? {
        guard let angle = hoveredDonutAngle else { return nil }
        let items = computeCategorySpending()
        guard !items.isEmpty else { return nil }
        // chartAngleSelection returns cumulative data value, not a fraction
        var cumulative = 0.0
        for item in items {
            cumulative += item.amount
            if angle <= cumulative { return item.name }
        }
        return items.last?.name
    }

    // MARK: - Subscriptions Summary

    private var subscriptionsSummaryCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text("Subscriptions")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    Button {
                        router.navigate(to: .subscriptions)
                    } label: {
                        Text("View All")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    metricItem(
                        value: CurrencyFormat.compact(subscriptionsCostForMonth),
                        label: router.selectedMonth.formatted(.dateTime.month(.abbreviated).year())
                    )
                    Spacer()
                    metricItem(
                        value: CurrencyFormat.compact(activeSubscriptionsCost * 12),
                        label: "Annual"
                    )
                    Spacer()
                    metricItem(
                        value: "\(subscriptionsDueInSelectedMonth.count)",
                        label: "Due"
                    )
                }
            }
        }
    }

    private func metricItem(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(CentmondTheme.Typography.heading2)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(CentmondTheme.Motion.default, value: value)
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
    }

    // MARK: - Recent Transactions Card

    private var recentTransactionsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text(router.isCurrentMonth ? "Recent Transactions" : "Transactions · \(monthString)")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    Button {
                        router.navigate(to: .transactions)
                    } label: {
                        Text("View All")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }

                if recentTransactions.isEmpty {
                    VStack(spacing: CentmondTheme.Spacing.md) {
                        Image(systemName: "tray")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                        Text("No transactions yet")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)

                        Button("Add Transaction") {
                            router.showSheet(.newTransaction)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(recentTransactions) { transaction in
                                transactionRow(transaction)

                                if transaction.id != recentTransactions.last?.id {
                                    Divider()
                                        .background(CentmondTheme.Colors.strokeSubtle)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .frame(height: 280)
    }

    private func transactionRow(_ transaction: Transaction) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            Image(systemName: transaction.category?.icon ?? "questionmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    transaction.category != nil
                        ? Color(hex: transaction.category!.colorHex)
                        : CentmondTheme.Colors.textTertiary
                )
                .frame(width: 32, height: 32)
                .background(
                    (transaction.category != nil
                        ? Color(hex: transaction.category!.colorHex)
                        : CentmondTheme.Colors.textTertiary
                    ).opacity(0.12)
                )
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(transaction.payee)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)

                Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Spacer()

            Text(formatSignedAmount(transaction.amount, isIncome: transaction.isIncome))
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(
                    transaction.isIncome
                        ? CentmondTheme.Colors.positive
                        : CentmondTheme.Colors.negative.opacity(0.85)
                )
                .monospacedDigit()
        }
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .padding(.horizontal, CentmondTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                .fill(hoveredTxID == transaction.id ? CentmondTheme.Colors.bgQuaternary : .clear)
        )
        .onHover { h in
            withAnimation(CentmondTheme.Motion.micro) {
                hoveredTxID = h ? transaction.id : nil
            }
        }
    }

    // MARK: - Budget Health Card

    private var budgetHealthCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text("Budget Health")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    Button {
                        router.navigate(to: .budget)
                    } label: {
                        Text("Details")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }


                if categories.isEmpty && totalBudgetAmount == 0 {
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "chart.pie")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                        Text("No budget configured")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)

                        Button {
                            router.showSheet(.budgetPlanner)
                        } label: {
                            Text("Set Up Budget")
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CentmondTheme.Spacing.xl)
                } else {
                    let budgetProgress = totalBudgeted > 0
                        ? Double(truncating: (monthlySpending / totalBudgeted) as NSDecimalNumber)
                        : 0.0
                    let isOver = monthlySpending > totalBudgeted && totalBudgeted > 0

                    HStack(spacing: CentmondTheme.Spacing.lg) {
                        ProgressRing(
                            progress: min(budgetProgress, 1.0),
                            size: 56,
                            lineWidth: 5,
                            fillColor: isOver ? CentmondTheme.Colors.negative : CentmondTheme.Colors.accent
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(CurrencyFormat.standard(monthlySpending))
                                .font(CentmondTheme.Typography.monoLarge)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(CentmondTheme.Motion.default, value: monthlySpending)

                            Text("of \(CurrencyFormat.standard(totalBudgeted)) budgeted")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    ScrollView {
                        VStack(spacing: CentmondTheme.Spacing.sm) {
                            ForEach(topBudgetCategories.prefix(6)) { category in
                                budgetCategoryRow(category)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .frame(height: 280)
    }

    private var topBudgetCategories: [BudgetCategory] {
        categories
            .filter { effectiveBudget(for: $0) > 0 }
            .sorted { spentInCategory($0) > spentInCategory($1) }
    }

    private func spentInCategory(_ category: BudgetCategory) -> Decimal {
        safeTransactions
            .filter { !$0.isIncome && $0.category?.id == category.id && $0.date >= router.selectedMonthStart && $0.date < router.selectedMonthEnd }
            .reduce(0) { $0 + $1.amount }
    }

    private func budgetCategoryRow(_ category: BudgetCategory) -> some View {
        let spent = spentInCategory(category)
        let budget = effectiveBudget(for: category)
        let progress = budget > 0 ? Double(truncating: (spent / budget) as NSDecimalNumber) : 0
        let isOver = spent > budget

        return VStack(spacing: CentmondTheme.Spacing.xs) {
            HStack {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Circle()
                        .fill(isOver ? CentmondTheme.Colors.negative : Color(hex: category.colorHex))
                        .frame(width: 8, height: 8)

                    Text(category.name)
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(isOver ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: CentmondTheme.Spacing.xs) {
                    if isOver {
                        Text("Over")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.negative)
                            .padding(.horizontal, CentmondTheme.Spacing.xs)
                            .padding(.vertical, 1)
                            .background(CentmondTheme.Colors.negativeMuted)
                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
                    }

                    Text("\(CurrencyFormat.standard(spent)) / \(CurrencyFormat.standard(budget))")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(
                            isOver ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textTertiary
                        )
                        .monospacedDigit()
                }
            }

            ProgressBarView(
                progress: min(progress, 1.0),
                color: isOver ? CentmondTheme.Colors.negative : Color(hex: category.colorHex),
                height: 5,
                cornerRadius: 2.5
            )
        }
        .padding(.vertical, CentmondTheme.Spacing.xs)
        .padding(.horizontal, CentmondTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                .fill(isOver ? CentmondTheme.Colors.negativeMuted.opacity(0.3) : .clear)
        )
    }

    // MARK: - Goals Card

    private var goalsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text("Goals")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    if !goals.isEmpty {
                        Button {
                            router.navigate(to: .goals)
                        } label: {
                            Text("View All")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if goals.isEmpty {
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "target")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                        Text("No active goals")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)

                        Button {
                            router.showSheet(.newGoal)
                        } label: {
                            Text("Create Goal")
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, CentmondTheme.Spacing.md)
                } else {
                    VStack(spacing: CentmondTheme.Spacing.md) {
                        ForEach(goals.prefix(3)) { goal in
                            goalRow(goal)
                        }
                    }
                }
            }
        }
    }

    private func goalRow(_ goal: Goal) -> some View {
        VStack(spacing: CentmondTheme.Spacing.xs) {
            HStack {
                Text(goal.name)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(goal.progressPercentage * 100))%")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .monospacedDigit()
            }

            ProgressBarView(
                progress: min(goal.progressPercentage, 1.0),
                color: CentmondTheme.Colors.accent,
                height: 5,
                cornerRadius: 2.5
            )

            HStack {
                Text(CurrencyFormat.standard(goal.currentAmount))
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .monospacedDigit()

                Spacer()

                Text(CurrencyFormat.standard(goal.targetAmount))
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, CentmondTheme.Spacing.xs)
        .padding(.horizontal, CentmondTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                .fill(hoveredGoalID == goal.id ? CentmondTheme.Colors.bgQuaternary : .clear)
        )
        .onHover { h in
            withAnimation(CentmondTheme.Motion.micro) {
                hoveredGoalID = h ? goal.id : nil
            }
        }
    }

    // MARK: - Accounts Card

    private var accountsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text("Accounts")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    Button {
                        router.navigate(to: .accounts)
                    } label: {
                        Text("View All")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }

                if accounts.isEmpty {
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "building.columns")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                        Text("No accounts added")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)

                        Button {
                            router.showSheet(.newAccount)
                        } label: {
                            Text("Add Account")
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, CentmondTheme.Spacing.md)
                } else {
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        ForEach(accounts.prefix(4)) { account in
                            HStack(spacing: CentmondTheme.Spacing.md) {
                                Image(systemName: account.type.iconName)
                                    .font(.system(size: 13))
                                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                                    .frame(width: 24, height: 24)
                                    .background(CentmondTheme.Colors.bgQuaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))

                                VStack(alignment: .leading, spacing: 0) {
                                    Text(account.name)
                                        .font(CentmondTheme.Typography.body)
                                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                        .lineLimit(1)
                                    if let digits = account.lastFourDigits, !digits.isEmpty {
                                        Text("•••• \(digits)")
                                            .font(CentmondTheme.Typography.caption)
                                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                    }
                                }

                                Spacer()

                                Text(CurrencyFormat.standard(account.currentBalance))
                                    .font(CentmondTheme.Typography.mono)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, CentmondTheme.Spacing.xs)
                            .padding(.horizontal, CentmondTheme.Spacing.xs)
                            .background(
                                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                                    .fill(hoveredAccountID == account.id ? CentmondTheme.Colors.bgQuaternary : .clear)
                            )
                            .onHover { h in
                                withAnimation(CentmondTheme.Motion.micro) {
                                    hoveredAccountID = h ? account.id : nil
                                }
                            }
                        }
                    }

                    if accounts.count > 1 {
                        Divider().background(CentmondTheme.Colors.strokeSubtle)

                        HStack {
                            Text("Total")
                                .font(CentmondTheme.Typography.bodyMedium)
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            Spacer()
                            Text(CurrencyFormat.standard(totalBalance))
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Charts

    @ViewBuilder
    private var cashFlowChart: some View {
        if chartStyle == .bar {
            modernBarChart
        } else {
            modernLineChart
        }
    }

    // MARK: Modern Bar Chart — gradient bars with glow

    @ViewBuilder
    private var modernBarChart: some View {
        let dailyData = computeDailyData()
        let dayCount = dailyData.count
        Chart {
            ForEach(dailyData) { dp in
                BarMark(
                    x: .value("Day", dp.id),
                    y: .value("Expenses", dp.expenses)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [CentmondTheme.Colors.accent, CentmondTheme.Colors.accent.opacity(0.5)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .opacity(hoveredDay == nil || hoveredDay == dp.id ? 1.0 : 0.35)
                .position(by: .value("Type", "Expenses"))

                BarMark(
                    x: .value("Day", dp.id),
                    y: .value("Income", dp.income)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [CentmondTheme.Colors.positive, CentmondTheme.Colors.positive.opacity(0.4)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .opacity(hoveredDay == nil || hoveredDay == dp.id ? 1.0 : 0.35)
                .position(by: .value("Type", "Income"))
            }
        }
        .chartXScale(domain: 1 ... (dailyData.count > 0 ? dailyData.count : 30))
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.5))
                AxisValueLabel {
                    if let val = value.as(Double.self) {
                        Text(CurrencyFormat.abbreviated(val))
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: [1, 5, 10, 15, 20, 25, 30]) { value in
                AxisValueLabel {
                    if let day = value.as(Int.self) {
                        Text("\(day)")
                            .font(.system(size: 9))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverLocation = location
                            var closestDay: Int?
                            var closestDist = CGFloat.greatestFiniteMagnitude
                            for dp in dailyData {
                                if let xPos = proxy.position(forX: dp.id) {
                                    let dist = abs(location.x - xPos)
                                    if dist < closestDist {
                                        closestDist = dist
                                        closestDay = dp.id
                                    }
                                }
                            }
                            if let day = closestDay {
                                withAnimation(CentmondTheme.Motion.micro) { hoveredDay = day }
                            }
                        case .ended:
                            withAnimation(CentmondTheme.Motion.micro) { hoveredDay = nil }
                        }
                    }
            }
        }
    }

    // MARK: Modern Line Chart — smooth gradient area with glow line

    @ViewBuilder
    private var modernLineChart: some View {
        let dailyData = computeDailyData()

        Chart {
            // Expenses — gradient area + line
            ForEach(dailyData) { dp in
                AreaMark(
                    x: .value("Day", dp.id),
                    yStart: .value("Start", 0),
                    yEnd: .value("Amount", dp.expenses)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            CentmondTheme.Colors.accent.opacity(0.25),
                            CentmondTheme.Colors.accent.opacity(0.05),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Day", dp.id),
                    y: .value("Amount", dp.expenses)
                )
                .foregroundStyle(CentmondTheme.Colors.accent)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            // Income — gradient area + line
            ForEach(dailyData) { dp in
                AreaMark(
                    x: .value("Day", dp.id),
                    yStart: .value("Start", 0),
                    yEnd: .value("Amount", dp.income)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            CentmondTheme.Colors.positive.opacity(0.18),
                            CentmondTheme.Colors.positive.opacity(0.03),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Day", dp.id),
                    y: .value("Amount", dp.income)
                )
                .foregroundStyle(CentmondTheme.Colors.positive)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }

            // Hover indicators
            if let day = hoveredDay,
               let dp = dailyData.first(where: { $0.id == day }) {
                RuleMark(x: .value("Day", day))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 4]))

                PointMark(x: .value("Day", day), y: .value("Exp", dp.expenses))
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .symbolSize(30)

                if dp.income > 0 {
                    PointMark(x: .value("Day", day), y: .value("Inc", dp.income))
                        .foregroundStyle(CentmondTheme.Colors.positive)
                        .symbolSize(30)
                }
            }
        }
        .chartXScale(domain: 1 ... (dailyData.count > 0 ? dailyData.count : 30))
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.5))
                AxisValueLabel {
                    if let val = value.as(Double.self) {
                        Text(CurrencyFormat.abbreviated(val))
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: [1, 5, 10, 15, 20, 25, 30]) { value in
                AxisValueLabel {
                    if let day = value.as(Int.self) {
                        Text("\(day)")
                            .font(.system(size: 9))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverLocation = location
                            var closestDay: Int?
                            var closestDist = CGFloat.greatestFiniteMagnitude
                            for dp in dailyData {
                                if let xPos = proxy.position(forX: dp.id) {
                                    let dist = abs(location.x - xPos)
                                    if dist < closestDist {
                                        closestDist = dist
                                        closestDay = dp.id
                                    }
                                }
                            }
                            if let day = closestDay {
                                withAnimation(CentmondTheme.Motion.micro) { hoveredDay = day }
                            }
                        case .ended:
                            withAnimation(CentmondTheme.Motion.micro) { hoveredDay = nil }
                        }
                    }
            }
        }
    }

    private func chartTooltip(data: DailyDataPoint) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text(data.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            HStack(spacing: CentmondTheme.Spacing.md) {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Circle().fill(CentmondTheme.Colors.positive).frame(width: 5, height: 5)
                    Text(CurrencyFormat.standard(Decimal(data.income)))
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.positive)
                        .monospacedDigit()
                }
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Circle().fill(CentmondTheme.Colors.accent).frame(width: 5, height: 5)
                    Text(CurrencyFormat.standard(Decimal(data.expenses)))
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    @ViewBuilder
    private var spendingDonut: some View {
        let categorySpending = computeCategorySpending()

        if categorySpending.isEmpty {
            Circle()
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 16)
        } else {
            Chart(categorySpending, id: \.name) { item in
                SectorMark(
                    angle: .value("Spending", item.amount),
                    innerRadius: .ratio(0.85),
                    angularInset: 1
                )
                .foregroundStyle(item.color)
                .cornerRadius(2)
                .opacity(selectedDonutCategory == nil || selectedDonutCategory == item.name ? 1.0 : 0.3)
            }
            .chartLegend(.hidden)
            .chartAngleSelection(value: $hoveredDonutAngle)
        }
    }

    // MARK: - Helpers

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: CentmondTheme.Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
    }

    private func emptyChartPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(CentmondTheme.Typography.body)
            .foregroundStyle(CentmondTheme.Colors.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    // MARK: - Data Computation

    private struct DailyDataPoint: Identifiable {
        let id: Int // day of month (1-31)
        let label: String // "1", "2", ... "31"
        let date: Date
        let income: Double
        let expenses: Double
    }

    private func computeDailyData() -> [DailyDataPoint] {
        let calendar = Calendar.current
        let start = router.selectedMonthStart
        let end = router.selectedMonthEnd
        let daysInMonth = calendar.dateComponents([.day], from: start, to: end).day ?? 30

        // Group transactions by day-of-month for O(n) lookup
        var incomeByDay: [Int: Double] = [:]
        var expenseByDay: [Int: Double] = [:]
        for tx in safeTransactions where tx.date >= start && tx.date < end {
            let day = calendar.component(.day, from: tx.date)
            if tx.isIncome {
                incomeByDay[day, default: 0] += doubleValue(tx.amount)
            } else {
                expenseByDay[day, default: 0] += doubleValue(tx.amount)
            }
        }

        var result: [DailyDataPoint] = []
        for dayIndex in 0..<daysInMonth {
            let dayDate = calendar.date(byAdding: .day, value: dayIndex, to: start)!
            let day = calendar.component(.day, from: dayDate)
            result.append(DailyDataPoint(
                id: day,
                label: "\(day)",
                date: dayDate,
                income: incomeByDay[day] ?? 0,
                expenses: expenseByDay[day] ?? 0
            ))
        }
        return result
    }

    private struct CategorySpendingItem {
        let name: String
        let amount: Double
        let color: Color
    }

    private func computeCategorySpending() -> [CategorySpendingItem] {
        var categoryTotals: [String: Double] = [:]

        for transaction in monthlyExpenses {
            let name = transaction.category?.name ?? "Other"
            categoryTotals[name, default: 0] += doubleValue(transaction.amount)
        }

        let sorted = categoryTotals.sorted { $0.value > $1.value }
        let palette = CentmondTheme.Colors.chartPalette

        return sorted.prefix(6).enumerated().map { index, pair in
            CategorySpendingItem(name: pair.key, amount: pair.value, color: palette[index % palette.count])
        }
    }

    private func formatSignedAmount(_ amount: Decimal, isIncome: Bool) -> String {
        CurrencyFormat.signed(amount, isIncome: isIncome)
    }

    private func doubleValue(_ decimal: Decimal) -> Double {
        Double(truncating: decimal as NSDecimalNumber)
    }

    private var monthString: String {
        router.selectedMonth.formatted(.dateTime.month(.wide).year())
    }

    private var daysLeftInMonth: Int {
        let calendar = Calendar.current
        let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, day: -1),
                                       to: router.selectedMonthStart)!
        return max(0, calendar.dateComponents([.day], from: Date.now, to: endOfMonth).day ?? 0)
    }
}

