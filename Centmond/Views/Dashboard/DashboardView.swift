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
    // Cash-flow chart hover state lives inside `CashFlowChartSurface` (nested
    // struct) so 60 Hz `onContinuousHover` updates don't invalidate the
    // entire DashboardView — which includes 6+ other expensive cards
    // (spending breakdown, subscriptions, recents, budget, goals, accounts).
    // Matches the same fix we did for the AI prediction trajectory chart.
    // `hoveredDonutAngle` lives inside `SpendingBreakdownCard` (nested below)
    // so donut-hover updates don't invalidate the entire dashboard body.
    // Same fix pattern as the cash-flow chart and the trajectory chart.
    @State private var hoveredTxID: UUID?
    @State private var hoveredAccountID: UUID?
    @State private var hoveredGoalID: UUID?

    // MARK: - Cached Snapshot
    //
    // Dashboard body re-renders on every hover tick (60 Hz) due to
    // hoveredTxID / hoveredAccountID / hoveredGoalID and child state.
    // Without caching, each re-render re-filtered the full transactions
    // array 10+ times (monthlyExpenses, monthlyIncome, recentTransactions,
    // spentInCategory × N categories, computeDailyData, computeCategorySpending).
    // The snapshot is rebuilt only when underlying @Query data or the
    // selected month changes — not on hover or local UI state flips.
    // Pattern matches ReportInspectorView / ReviewQueueService.
    @State private var snapshot = DashboardSnapshot()

    enum ChartStyle: String, CaseIterable {
        case bar          // Grouped bar
        case net          // Net cash flow bars

        var icon: String {
            switch self {
            case .bar:        return "chart.bar.fill"
            case .net:        return "plusminus"
            }
        }

        var label: String {
            switch self {
            case .bar:        return "Bar"
            case .net:        return "Net"
            }
        }
    }

    // MARK: - Computed Data

    private var liveAccounts: [Account] {
        accounts.filter { $0.modelContext != nil && !$0.isDeleted }
    }
    private var liveAllGoals: [Goal] {
        allGoals.filter { $0.modelContext != nil && !$0.isDeleted }
    }

    private var goals: [Goal] {
        liveAllGoals.filter { $0.status == .active }
    }

    private var totalBalance: Decimal {
        liveAccounts.reduce(0) { $0 + $1.currentBalance }
    }

    // Snapshot-backed accessors. All heavy filtering is done once per
    // data change in `rebuildSnapshot()`; body reads stay O(1).
    private var monthlySpending: Decimal { snapshot.monthlySpending }
    private var monthlyIncome: Decimal { snapshot.monthlyIncome }
    /// Discretionary money left after this month's committed obligations
    /// (upcoming subscriptions due in the selected month). Differs from
    /// `Remaining` (= budget − spent) by the amount already earmarked for
    /// recurring bills the user hasn't been charged for yet.
    private var safeToSpend: Decimal {
        max(0, snapshot.totalBudgeted - snapshot.monthlySpending - snapshot.subscriptionsCost)
    }
    private var recentTransactions: [Transaction] { snapshot.recentTransactions }

    /// Tombstone-safe @Query views for body-scope reads (.onChange,
    /// .isEmpty, etc.). Mapping a persisted attribute over a
    /// detached SwiftData @Model faults; cloud-prune deletes leave
    /// such tombstones in the @Query array for one frame.
    private var liveTransactions: [Transaction] {
        transactions.filter { $0.modelContext != nil && !$0.isDeleted }
    }
    private var liveCategoriesQuery: [BudgetCategory] {
        categories.filter { $0.modelContext != nil && !$0.isDeleted }
    }
    private var liveSubscriptionsQuery: [Subscription] {
        subscriptions.filter { $0.modelContext != nil && !$0.isDeleted }
    }
    private var liveMonthlyBudgetsQuery: [MonthlyBudget] {
        monthlyBudgets.filter { $0.modelContext != nil && !$0.isDeleted }
    }
    private var liveTotalBudgetsQuery: [MonthlyTotalBudget] {
        totalBudgets.filter { $0.modelContext != nil && !$0.isDeleted }
    }
    private var subscriptionsDueInSelectedMonth: [Subscription] { snapshot.subscriptionsDue }
    private var subscriptionsCostForMonth: Decimal { snapshot.subscriptionsCost }
    private var totalBudgeted: Decimal { snapshot.totalBudgeted }
    private var activeSubscriptionsCost: Decimal { snapshot.activeSubscriptionsCost }

    // MARK: - Body

    var body: some View {
        ScrollView {
            // LazyVStack — was VStack, which eagerly rendered all 7 dashboard
            // cards on every body re-eval even when cards were offscreen.
            // LazyVStack defers offscreen cards entirely; only the visible
            // ones run their bodies on each invalidation.
            LazyVStack(spacing: CentmondTheme.Spacing.lg) {
                SectionTutorialStrip(screen: .dashboard)
                metricsRow
                // Review Queue is temporarily hidden. Re-enable by
                // uncommenting the strip below (the view is still
                // compiled so it's a one-line revert).
                // DashboardReviewStrip()
                aiQuickAccessBanner
                DashboardHouseholdStrip()
                mainChartsRow
                DashboardInsightStrip()
                bottomRow
            }
            .padding(CentmondTheme.Spacing.lg)
        }
        .background(CentmondTheme.Colors.bgPrimary)
        // `.task` instead of `.onAppear` so the tab-switch animation can
        // complete BEFORE rebuildSnapshot runs. The work is still on the
        // main actor (View is MainActor), but the task body fires after
        // the view first appears — main thread paints the new tab, then
        // does the work. Tab activation feels instant; content fills in.
        .task {
            rebuildSnapshot()
            AIInsightEngine.shared.refresh(context: modelContext)
        }
        // Collapsed from 7 modifiers. The previous form did `liveX.map(\.amount)`
        // for five queries on every body render — each map allocated a fresh
        // [Decimal] of all rows and SwiftUI then ran array equality, so
        // typing/scrolling triggered ~5×O(n) work + allocations. The struct
        // below is Equatable in O(1) (six Ints + five Decimals); the per-query
        // reduce is the same O(n) the old map already paid, minus the array
        // allocation. In-place amount edits still trip the sum, same as before.
        .onChange(of: snapshotChangeKey) { _, _ in rebuildSnapshot() }
    }

    private struct DashboardChangeKey: Equatable {
        var txCount: Int
        var txMaxUpdated: Date
        var subCount: Int
        var subMaxUpdated: Date
        var catCount: Int
        var catMaxUpdated: Date
        var monthlyBudgetCount: Int
        var monthlyBudgetSum: Decimal
        var totalBudgetCount: Int
        var totalBudgetSum: Decimal
        var goalCount: Int
        var monthStart: Date
    }

    /// Cheaper-than-before fingerprint of the data the dashboard depends on.
    /// Was summing all amounts (5× O(n) Decimal addition per body re-eval —
    /// SwiftUI evaluates `.onChange` keys on every render). Date comparison
    /// over `updatedAt` is an order of magnitude faster than Decimal `+`,
    /// catches the same in-place-edit case, and avoids allocations.
    /// MonthlyBudget / MonthlyTotalBudget have no `updatedAt` field, so the
    /// sum-based fallback stays for those (they're tiny arrays anyway).
    private var snapshotChangeKey: DashboardChangeKey {
        let tx = liveTransactions
        let subs = liveSubscriptionsQuery
        let cats = liveCategoriesQuery
        let mb = liveMonthlyBudgetsQuery
        let tb = liveTotalBudgetsQuery
        var txMax: Date = .distantPast
        for t in tx where t.updatedAt > txMax { txMax = t.updatedAt }
        var subMax: Date = .distantPast
        for s in subs where s.updatedAt > subMax { subMax = s.updatedAt }
        var catMax: Date = .distantPast
        for c in cats where c.updatedAt > catMax { catMax = c.updatedAt }
        return DashboardChangeKey(
            txCount: tx.count,
            txMaxUpdated: txMax,
            subCount: subs.count,
            subMaxUpdated: subMax,
            catCount: cats.count,
            catMaxUpdated: catMax,
            monthlyBudgetCount: mb.count,
            monthlyBudgetSum: mb.reduce(Decimal.zero) { $0 + $1.amount },
            totalBudgetCount: tb.count,
            totalBudgetSum: tb.reduce(Decimal.zero) { $0 + $1.amount },
            goalCount: allGoals.count,
            monthStart: router.selectedMonthStart
        )
    }

    // MARK: - AI Quick Access

    private var aiQuickAccessBanner: some View {
        Button {
            router.navigate(to: .aiChat)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(CentmondTheme.Colors.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Assistant")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("Ask about your spending, get budget advice, or optimize your finances")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(CentmondTheme.Spacing.md)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                    .strokeBorder(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plainHover)
    }

    // MARK: - Row 1: Metrics

    private var metricsRow: some View {
        HStack(spacing: CentmondTheme.Spacing.lg) {
            MetricCard(
                title: "Remaining",
                value: CurrencyFormat.standard(totalBudgeted - monthlySpending),
                icon: "minus.forwardslash.plus",
                iconColor: (totalBudgeted - monthlySpending) >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative,
                valueColor: (totalBudgeted - monthlySpending) < 0 ? CentmondTheme.Colors.negative : nil,
                subtitle: monthString
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
                                Haptics.tap()
                                withAnimation(CentmondTheme.Motion.layout) {
                                    chartStyle = style
                                }
                            } label: {
                                Image(systemName: style.icon)
                                    .font(CentmondTheme.Typography.overline)
                                    .foregroundStyle(chartStyle == style ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                                    .frame(width: 26, height: 22)
                                    .background(chartStyle == style ? CentmondTheme.Colors.accentSubtle : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
                                    .animation(CentmondTheme.Motion.micro, value: chartStyle)
                            }
                            .buttonStyle(.plainHover)
                            .help(style.label)
                        }
                    }
                    .padding(2)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

                    // Legend (adapts to chart type)
                    chartLegend
                }

                if snapshot.transactionsIsEmpty {
                    emptyChartPlaceholder("Add transactions to see cash flow")
                        .frame(height: 340)
                        .transition(.opacity)
                } else {
                    // Hover state is OWNED by this sub-view — parent dashboard
                    // is untouched on every hover tick.
                    CashFlowChartSurface(
                        chartStyle: chartStyle,
                        dailyData: snapshot.dailyData
                    )
                    .frame(height: 340)
                    .transition(.opacity)
                    .animation(CentmondTheme.Motion.layout, value: chartStyle)
                }
            }
        }
    }

    // MARK: - Spending Breakdown Card

    private var spendingBreakdownCard: some View {
        SpendingBreakdownCard(
            categorySpending: snapshot.categorySpending,
            monthlySpending: snapshot.monthlySpending,
            isEmpty: snapshot.monthlyExpensesEmpty
        )
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
                    .buttonStyle(.plainHover)
                    .help("View all subscriptions")
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
                .animation(CentmondTheme.Motion.numeric, value: value)
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
                    .buttonStyle(.plainHover)
                    .help("View all transactions")
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
                        .help("Create a new transaction")
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
                .font(CentmondTheme.Typography.bodyLarge.weight(.medium))
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
            if h { Haptics.tick() }
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
                    .buttonStyle(.plainHover)
                    .help("View budget details")
                }


                if liveCategoriesQuery.isEmpty && snapshot.totalBudgeted == 0 {
                    VStack(spacing: CentmondTheme.Spacing.md) {
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
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Set up your monthly budget")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                .animation(CentmondTheme.Motion.numeric, value: monthlySpending)

                            Text("of \(CurrencyFormat.standard(totalBudgeted)) budgeted")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    ScrollView {
                        VStack(spacing: CentmondTheme.Spacing.sm) {
                            ForEach(Array(snapshot.topBudgetRows.prefix(6).enumerated()), id: \.offset) { _, row in
                                budgetCategoryRow(row)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .frame(height: 280)
    }

    private func budgetCategoryRow(_ row: BudgetRow) -> some View {
        let category = row.category
        let spent = row.spent
        let budget = row.budget
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
                cornerRadius: CentmondTheme.Radius.xs
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
                        .buttonStyle(.plainHover)
                        .help("View all goals")
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
                        .buttonStyle(.plainHover)
                        .help("Create a new savings goal")
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
                    .contentTransition(.numericText())
                    .animation(CentmondTheme.Motion.numeric, value: goal.progressPercentage)
            }

            ProgressBarView(
                progress: min(goal.progressPercentage, 1.0),
                color: CentmondTheme.Colors.accent,
                height: 5,
                cornerRadius: CentmondTheme.Radius.xs
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
            if h { Haptics.tick() }
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
                    .buttonStyle(.plainHover)
                    .help("View all accounts")
                }

                if liveAccounts.isEmpty {
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
                        .buttonStyle(.plainHover)
                        .help("Add a new bank account")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, CentmondTheme.Spacing.md)
                } else {
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        ForEach(Array(liveAccounts.prefix(4))) { account in
                            HStack(spacing: CentmondTheme.Spacing.md) {
                                Image(systemName: account.type.iconName)
                                    .font(CentmondTheme.Typography.body)
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
                                    .contentTransition(.numericText())
                                    .animation(CentmondTheme.Motion.numeric, value: account.currentBalance)
                            }
                            .padding(.vertical, CentmondTheme.Spacing.xs)
                            .padding(.horizontal, CentmondTheme.Spacing.xs)
                            .background(
                                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                                    .fill(hoveredAccountID == account.id ? CentmondTheme.Colors.bgQuaternary : .clear)
                            )
                            .onHover { h in
                                if h { Haptics.tick() }
                                withAnimation(CentmondTheme.Motion.micro) {
                                    hoveredAccountID = h ? account.id : nil
                                }
                            }
                        }
                    }

                    if liveAccounts.count > 1 {
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
                                .contentTransition(.numericText())
                                .animation(CentmondTheme.Motion.numeric, value: totalBalance)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Charts

    // `cashFlowChart` / `groupedBarChart` / `netCashFlowChart` / `chartTooltip`
    // / `BarEntry` / `CashFlowHoverModifier` / `CashFlowChartStyle` have all
    // been moved into `CashFlowChartSurface` (nested below). That struct
    // owns the hover state so every hover tick re-renders ONLY the chart
    // surface — not the entire dashboard.

    @ViewBuilder
    private var chartLegend: some View {
        switch chartStyle {
        case .net:
            HStack(spacing: CentmondTheme.Spacing.md) {
                legendDot(color: CentmondTheme.Colors.positive, label: "Surplus")
                legendDot(color: CentmondTheme.Colors.negative, label: "Deficit")
            }
        default:
            HStack(spacing: CentmondTheme.Spacing.md) {
                legendDot(color: CentmondTheme.Colors.positive, label: "Income")
                legendDot(color: CentmondTheme.Colors.accent, label: "Expenses")
            }
        }
    }

    // MARK: - Cash Flow Chart Surface (owns hover state)
    //
    // Extracted from DashboardView to isolate 60 Hz `onContinuousHover`
    // updates: hover state changes re-render only this sub-view, leaving
    // the dashboard's other cards untouched. Mirrors the same fix applied
    // to the AI prediction trajectory chart.
    private struct CashFlowChartSurface: View {
        let chartStyle: ChartStyle
        let dailyData: [DailyDataPoint]

        @Environment(\.modelContext) private var modelContext
        @State private var hoveredDay: Int?
        @State private var hoverLocation: CGPoint = .zero

        private struct BarEntry: Identifiable {
            let id: String
            let day: Int
            let amount: Double
            let type: String // "Income" or "Expenses"
        }

        var body: some View {
            chartView
                .overlay { tooltipOverlay }
        }

        @ViewBuilder
        private var chartView: some View {
            switch chartStyle {
            case .bar: groupedBarChart
            case .net: netCashFlowChart
            }
        }

        @ViewBuilder
        private var tooltipOverlay: some View {
            GeometryReader { geo in
                if let day = hoveredDay,
                   let data = dailyData.first(where: { $0.id == day }) {
                    let tooltipW: CGFloat = 190
                    let clampedX = min(max(hoverLocation.x, tooltipW / 2 + 8), geo.size.width - tooltipW / 2 - 8)

                    chartTooltip(data: data)
                        .frame(width: tooltipW)
                        .position(x: clampedX, y: max(hoverLocation.y - 46, 24))
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }

        // MARK: Grouped Bar Chart

        private var groupedBarChart: some View {
            let dayCount = max(dailyData.count, 1)
            let entries: [BarEntry] = dailyData.flatMap { dp in [
                BarEntry(id: "\(dp.id)-E", day: dp.id, amount: dp.expenses, type: "Expenses"),
                BarEntry(id: "\(dp.id)-I", day: dp.id, amount: dp.income,   type: "Income")
            ]}

            return Chart(entries) { entry in
                BarMark(
                    x: .value("Day", entry.day),
                    y: .value("Amount", entry.amount)
                )
                .foregroundStyle(by: .value("Type", entry.type))
                .position(by: .value("Type", entry.type), axis: .horizontal, span: .ratio(0.8))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
                .opacity(hoveredDay == nil || hoveredDay == entry.day ? 1.0 : 0.35)
            }
            .chartForegroundStyleScale([
                "Income":   CentmondTheme.Colors.positive,
                "Expenses": CentmondTheme.Colors.accent
            ])
            .chartYScale(domain: .automatic(includesZero: true))
            .modifier(CashFlowChartStyle())
            .modifier(CashFlowHoverModifier(dayCount: dayCount, hoveredDay: $hoveredDay, hoverLocation: $hoverLocation))
        }

        // MARK: Net Cash Flow Chart

        private var netCashFlowChart: some View {
            let dayCount = max(dailyData.count, 1)

            return Chart {
                ForEach(dailyData) { dp in
                    let net = dp.income - dp.expenses
                    BarMark(
                        x: .value("Day", dp.id),
                        y: .value("Net", net)
                    )
                    .foregroundStyle(net >= 0 ? CentmondTheme.Colors.positive.gradient : CentmondTheme.Colors.negative.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
                    .opacity(hoveredDay == nil || hoveredDay == dp.id ? 1.0 : 0.35)
                }

                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .modifier(CashFlowChartStyle())
            .modifier(CashFlowHoverModifier(dayCount: dayCount, hoveredDay: $hoveredDay, hoverLocation: $hoverLocation))
        }

        // MARK: Shared Chart Modifiers

        private struct CashFlowChartStyle: ViewModifier {
            func body(content: Content) -> some View {
                content
                    .chartPlotStyle { plot in
                        plot.frame(minHeight: 280).padding(.horizontal, 4).clipped()
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.4))
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
                        AxisMarks(values: .stride(by: 5)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                                .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.15))
                            AxisValueLabel {
                                if let day = value.as(Int.self) {
                                    Text("\(day)")
                                        .font(CentmondTheme.Typography.micro)
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                }
                            }
                        }
                    }
                    .chartLegend(.hidden)
            }
        }

        private struct CashFlowHoverModifier: ViewModifier {
            let dayCount: Int
            @Binding var hoveredDay: Int?
            @Binding var hoverLocation: CGPoint

            func body(content: Content) -> some View {
                content
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        guard let plotFrameKey = proxy.plotFrame else {
                                            if hoveredDay != nil {
                                                withAnimation(CentmondTheme.Motion.micro) { hoveredDay = nil }
                                            }
                                            return
                                        }
                                        let plotFrame = geometry[plotFrameKey]
                                        let xInPlot = location.x - plotFrame.origin.x
                                        guard xInPlot >= 0, xInPlot <= plotFrame.width else {
                                            if hoveredDay != nil {
                                                withAnimation(CentmondTheme.Motion.micro) { hoveredDay = nil }
                                            }
                                            return
                                        }
                                        if let day: Int = proxy.value(atX: xInPlot) {
                                            let clamped = max(1, min(day, dayCount))
                                            // Only update state when day changes — no per-pixel churn.
                                            if hoveredDay != clamped {
                                                Haptics.tick()
                                                hoveredDay = clamped
                                            }
                                            hoverLocation = location
                                        }
                                    case .ended:
                                        if hoveredDay != nil {
                                            withAnimation(CentmondTheme.Motion.micro) { hoveredDay = nil }
                                        }
                                    }
                                }
                        }
                    }
            }
        }

        private func chartTooltip(data: DailyDataPoint) -> some View {
            let net = data.income - data.expenses
            return VStack(alignment: .leading, spacing: 6) {
                Text(data.date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)

                Divider().opacity(0.25)

                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Circle().fill(CentmondTheme.Colors.positive).frame(width: 6, height: 6)
                    Text("Income")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Spacer()
                    Text(CurrencyFormat.standard(Decimal(data.income)))
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.positive)
                        .monospacedDigit()
                }

                // Goal-allocation sub-rows. Only fetched on hover so the
                // chart's main render path stays untouched. When any income
                // on this day funded a goal, show the slice + the remainder
                // available to spend.
                if data.income > 0 {
                    let allocated = GoalContributionService.totalAllocatedFromIncome(on: data.date, context: modelContext)
                    if allocated > 0 {
                        let toSpend = max(Decimal(data.income) - allocated, 0)
                        HStack(spacing: CentmondTheme.Spacing.xs) {
                            Image(systemName: "target")
                                .font(CentmondTheme.Typography.microBold.weight(.semibold))
                                .foregroundStyle(CentmondTheme.Colors.accent)
                                .frame(width: 6)
                            Text("To goals")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            Spacer()
                            Text(CurrencyFormat.standard(allocated))
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                                .monospacedDigit()
                        }
                        .padding(.leading, 12)
                        HStack(spacing: CentmondTheme.Spacing.xs) {
                            Image(systemName: "wallet.pass.fill")
                                .font(CentmondTheme.Typography.microBold.weight(.semibold))
                                .foregroundStyle(CentmondTheme.Colors.positive.opacity(0.7))
                                .frame(width: 6)
                            Text("To spend")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            Spacer()
                            Text(CurrencyFormat.standard(toSpend))
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(CentmondTheme.Colors.positive.opacity(0.85))
                                .monospacedDigit()
                        }
                        .padding(.leading, 12)
                    }
                }

                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Circle().fill(CentmondTheme.Colors.accent).frame(width: 6, height: 6)
                    Text("Expenses")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Spacer()
                    Text(CurrencyFormat.standard(Decimal(data.expenses)))
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .monospacedDigit()
                }

                Divider().opacity(0.25)

                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Text("Net")
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    Spacer()
                    Text(CurrencyFormat.standard(Decimal(net)))
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, CentmondTheme.Spacing.md)
            .padding(.vertical, CentmondTheme.Spacing.sm)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 0.5)
            )
            .centmondShadow(2)
        }
    }

    // `spendingDonut` was moved into the `SpendingBreakdownCard` nested struct
    // (below) so `hoveredDonutAngle` state lives on the donut sub-view — donut
    // hover doesn't invalidate the whole DashboardView body anymore.

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

    fileprivate struct DailyDataPoint: Identifiable {
        let id: Int // day of month (1-31)
        let label: String // "1", "2", ... "31"
        let date: Date
        let income: Double
        let expenses: Double
    }

    fileprivate struct CategorySpendingItem {
        let name: String
        let amount: Double
        let color: Color
    }

    // MARK: - Snapshot

    fileprivate struct BudgetRow {
        let category: BudgetCategory
        let spent: Decimal
        let budget: Decimal
    }

    fileprivate struct DashboardSnapshot {
        var monthlySpending: Decimal = 0
        var monthlyIncome: Decimal = 0
        var monthlyExpensesEmpty: Bool = true
        var transactionsIsEmpty: Bool = true
        var recentTransactions: [Transaction] = []
        var subscriptionsDue: [Subscription] = []
        var subscriptionsCost: Decimal = 0
        var activeSubscriptionsCost: Decimal = 0
        var totalBudgeted: Decimal = 0
        var topBudgetRows: [BudgetRow] = []
        var dailyData: [DailyDataPoint] = []
        var categorySpending: [CategorySpendingItem] = []
    }

    /// Rebuilds all derived dashboard metrics in a single pass. Called only
    /// on @Query data changes or selected-month change — NOT on every body
    /// render. Hover / selection state flipping at 60 Hz no longer re-filters
    /// the transaction array.
    private func rebuildSnapshot() {
        let start = router.selectedMonthStart
        let end = router.selectedMonthEnd
        let calendar = Calendar.current
        let palette = CentmondTheme.Colors.chartPalette

        // Tombstone-safe @Query views. Any persisted attribute read
        // on a deleted SwiftData @Model faults; cloud-prune deletes
        // (when iOS removes a row) leave detached instances in
        // @Query arrays for one frame before SwiftUI re-publishes.
        let live = transactions.filter { !$0.isDeleted && $0.modelContext != nil }
        let liveEmpty = live.isEmpty
        let liveSubs = subscriptions.filter { !$0.isDeleted && $0.modelContext != nil }
        let liveCats = categories.filter { !$0.isDeleted && $0.modelContext != nil }
        let liveMonthlyBudgets = monthlyBudgets.filter { !$0.isDeleted && $0.modelContext != nil }
        let liveTotalBudgets = totalBudgets.filter { !$0.isDeleted && $0.modelContext != nil }

        // Walk the array ONCE, bucketing into all the slices we need.
        var monthExpenses: [Transaction] = []
        var monthIncome: Decimal = 0
        var monthSpending: Decimal = 0
        var spentByCatID: [UUID: Decimal] = [:]
        var categoryTotals: [String: Double] = [:]
        var recents: [Transaction] = []
        var incomeByDay: [Int: Double] = [:]
        var expenseByDay: [Int: Double] = [:]

        for tx in live {
            guard tx.date >= start && tx.date < end else { continue }

            // Recents — first 6 in reverse-date order; @Query already sorts desc.
            if recents.count < 6 { recents.append(tx) }

            if BalanceService.isSpendingExpense(tx) {
                monthExpenses.append(tx)
                monthSpending += tx.amount
                if let catID = tx.category?.id {
                    spentByCatID[catID, default: 0] += tx.amount
                }
                let name = tx.category?.name ?? "Other"
                categoryTotals[name, default: 0] += Double(truncating: tx.amount as NSDecimalNumber)
            } else if BalanceService.isSpendingIncome(tx) {
                monthIncome += tx.amount
            }

            let day = calendar.component(.day, from: tx.date)
            if tx.isIncome {
                incomeByDay[day, default: 0] += Double(truncating: tx.amount as NSDecimalNumber)
            } else {
                expenseByDay[day, default: 0] += Double(truncating: tx.amount as NSDecimalNumber)
            }
        }

        // Subscriptions
        var subsDue: [Subscription] = []
        var subsCost: Decimal = 0
        var activeSubsCost: Decimal = 0
        for sub in liveSubs where sub.status == .active {
            activeSubsCost += sub.monthlyCost
            if sub.billingCycle.occursInMonth(anchorDate: sub.nextPaymentDate, monthStart: start, monthEnd: end) {
                subsDue.append(sub)
                subsCost += sub.amount
            }
        }

        // Budgets
        let year = calendar.component(.year, from: router.selectedMonth)
        let monthNum = calendar.component(.month, from: router.selectedMonth)
        let totalBudgetAmt = liveTotalBudgets.first(where: { $0.year == year && $0.month == monthNum })?.amount ?? 0
        func budget(for cat: BudgetCategory) -> Decimal {
            liveMonthlyBudgets.first(where: {
                $0.categoryID == cat.id && $0.year == year && $0.month == monthNum
            })?.amount ?? cat.budgetAmount
        }
        let totalBudgeted: Decimal = {
            if totalBudgetAmt > 0 { return totalBudgetAmt }
            return liveCats.reduce(0) { $0 + budget(for: $1) }
        }()

        let rows: [BudgetRow] = liveCats
            .map { BudgetRow(category: $0, spent: spentByCatID[$0.id] ?? 0, budget: budget(for: $0)) }
            .filter { $0.budget > 0 }
            .sorted { $0.spent > $1.spent }

        // Daily chart series
        let daysInMonth = calendar.dateComponents([.day], from: start, to: end).day ?? 30
        var daily: [DailyDataPoint] = []
        daily.reserveCapacity(daysInMonth)
        for dayIndex in 0..<daysInMonth {
            let dayDate = calendar.date(byAdding: .day, value: dayIndex, to: start)!
            let day = calendar.component(.day, from: dayDate)
            daily.append(DailyDataPoint(
                id: day,
                label: "\(day)",
                date: dayDate,
                income: incomeByDay[day] ?? 0,
                expenses: expenseByDay[day] ?? 0
            ))
        }

        // Top 6 category-spending items (donut)
        let sortedCatTotals = categoryTotals.sorted { $0.value > $1.value }
        let catSpending: [CategorySpendingItem] = sortedCatTotals.prefix(6).enumerated().map { index, pair in
            CategorySpendingItem(name: pair.key, amount: pair.value, color: palette[index % palette.count])
        }

        var next = DashboardSnapshot()
        next.monthlySpending = monthSpending
        next.monthlyIncome = monthIncome
        next.monthlyExpensesEmpty = monthExpenses.isEmpty
        next.transactionsIsEmpty = liveEmpty
        next.recentTransactions = recents
        next.subscriptionsDue = subsDue
        next.subscriptionsCost = subsCost
        next.activeSubscriptionsCost = activeSubsCost
        next.totalBudgeted = totalBudgeted
        next.topBudgetRows = rows
        next.dailyData = daily
        next.categorySpending = catSpending
        snapshot = next
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
        let raw = calendar.dateComponents([.day], from: Date.now, to: endOfMonth).day ?? 0
        return max(0, raw + 1)
    }

    // MARK: - SpendingBreakdownCard (nested)
    //
    // Donut-chart hover state (`hoveredDonutAngle`) lives here so
    // `chartAngleSelection` updates at 60 Hz only invalidate THIS sub-view —
    // not the entire DashboardView body (which owns 6+ heavy cards and several
    // SwiftData @Query results). Mirrors the CashFlowChartSurface pattern.
    private struct SpendingBreakdownCard: View {
        let categorySpending: [CategorySpendingItem]
        let monthlySpending: Decimal
        let isEmpty: Bool

        @State private var hoveredDonutAngle: Double?

        private var selectedDonutCategory: String? {
            guard let angle = hoveredDonutAngle else { return nil }
            guard !categorySpending.isEmpty else { return nil }
            // chartAngleSelection returns cumulative data value, not a fraction
            var cumulative = 0.0
            for item in categorySpending {
                cumulative += item.amount
                if angle <= cumulative { return item.name }
            }
            return categorySpending.last?.name
        }

        var body: some View {
            CardContainer {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    Text("Spending by Category")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    if isEmpty {
                        Text("No expenses this month")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
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

                            // Legend — full width rows
                            VStack(spacing: 0) {
                                ForEach(Array(categorySpending.prefix(5).enumerated()), id: \.element.name) { index, item in
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

                                    if index < categorySpending.prefix(5).count - 1 {
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

        @ViewBuilder
        private var spendingDonut: some View {
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
                .onChange(of: selectedDonutCategory) { _, _ in Haptics.tick() }
                .animation(CentmondTheme.Motion.default, value: selectedDonutCategory)
            }
        }

        private var donutCenterLabel: some View {
            VStack(spacing: 1) {
                if let name = selectedDonutCategory,
                   let item = categorySpending.first(where: { $0.name == name }) {
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
    }
}

