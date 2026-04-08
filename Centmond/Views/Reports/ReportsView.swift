import SwiftUI
import SwiftData
import Charts

struct ReportsView: View {
    @Environment(AppRouter.self) private var router
    @Query private var transactions: [Transaction]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var reportType: ReportType = .incomeVsExpense
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -6, to: .now)!
    @State private var endDate = Date.now
    @State private var groupBy: GroupBy = .month

    enum ReportType: String, CaseIterable, Identifiable {
        case incomeVsExpense = "Income vs Expense"
        case spendingByCategory = "Spending by Category"
        case monthlyTrend = "Monthly Trend"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .incomeVsExpense: "arrow.left.arrow.right"
            case .spendingByCategory: "chart.pie.fill"
            case .monthlyTrend: "chart.line.uptrend.xyaxis"
            }
        }
    }

    enum GroupBy: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case quarter = "Quarter"
    }

    private var filteredTransactions: [Transaction] {
        transactions.filter { $0.date >= startDate && $0.date <= endDate }
    }

    private var totalIncome: Decimal {
        filteredTransactions.filter(BalanceService.isSpendingIncome).reduce(Decimal.zero) { $0 + $1.amount }
    }
    private var totalExpenses: Decimal {
        filteredTransactions.filter(BalanceService.isSpendingExpense).reduce(Decimal.zero) { $0 + $1.amount }
    }

    var body: some View {
        HStack(spacing: 0) {
            reportBuilder
                .frame(width: 280)
                .background(CentmondTheme.Colors.bgSecondary)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(width: 1)
                }

            reportPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Report Builder

    private var reportBuilder: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
                    // Report type
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                        sectionLabel("Report Type")

                        ForEach(ReportType.allCases) { type in
                            Button {
                                withAnimation(CentmondTheme.Motion.micro) { reportType = type }
                            } label: {
                                HStack(spacing: CentmondTheme.Spacing.sm) {
                                    Image(systemName: type.icon)
                                        .font(.system(size: 14))
                                        .frame(width: 24)
                                    Text(type.rawValue)
                                        .font(CentmondTheme.Typography.bodyMedium)
                                    Spacer()
                                    if reportType == type {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(CentmondTheme.Colors.accent)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .padding(.horizontal, CentmondTheme.Spacing.md)
                                .padding(.vertical, CentmondTheme.Spacing.sm)
                                .background(reportType == type ? CentmondTheme.Colors.accentMuted : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
                                .animation(CentmondTheme.Motion.micro, value: reportType)
                            }
                            .buttonStyle(.plainHover)
                            .foregroundStyle(reportType == type ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textSecondary)
                        }
                    }

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    // Quick date presets
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                        sectionLabel("Date Range")

                        HStack(spacing: CentmondTheme.Spacing.xs) {
                            datePresetButton("1M") {
                                startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
                                endDate = .now
                            }
                            datePresetButton("3M") {
                                startDate = Calendar.current.date(byAdding: .month, value: -3, to: .now)!
                                endDate = .now
                            }
                            datePresetButton("6M") {
                                startDate = Calendar.current.date(byAdding: .month, value: -6, to: .now)!
                                endDate = .now
                            }
                            datePresetButton("1Y") {
                                startDate = Calendar.current.date(byAdding: .year, value: -1, to: .now)!
                                endDate = .now
                            }
                            datePresetButton("YTD") {
                                startDate = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: .now))!
                                endDate = .now
                            }
                        }

                        DatePicker("From", selection: $startDate, displayedComponents: .date)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)

                        DatePicker("To", selection: $endDate, displayedComponents: .date)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    }

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    // Group by (not relevant for category pie)
                    if reportType != .spendingByCategory {
                        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                            sectionLabel("Group By")

                            Picker("Group", selection: $groupBy) {
                                ForEach(GroupBy.allCases, id: \.self) { g in
                                    Text(g.rawValue).tag(g)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Divider().background(CentmondTheme.Colors.strokeSubtle)
                    }

                    // Summary stats
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                        sectionLabel("Summary")

                        statRow(label: "Transactions", value: "\(filteredTransactions.count)")
                        statRow(label: "Total Income", value: CurrencyFormat.compact(totalIncome), color: CentmondTheme.Colors.positive)
                        statRow(label: "Total Expenses", value: CurrencyFormat.compact(totalExpenses), color: CentmondTheme.Colors.negative)

                        Divider().background(CentmondTheme.Colors.strokeSubtle)

                        statRow(
                            label: "Net",
                            value: CurrencyFormat.compact(totalIncome - totalExpenses),
                            color: totalIncome >= totalExpenses ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative
                        )

                        if totalIncome > 0 {
                            let savingsRate = Double(truncating: ((totalIncome - totalExpenses) / totalIncome * 100) as NSDecimalNumber)
                            statRow(
                                label: "Savings Rate",
                                value: "\(Int(savingsRate))%",
                                color: savingsRate >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative
                            )
                        }
                    }
                }
                .padding(CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Export button
            VStack(spacing: CentmondTheme.Spacing.sm) {
                Button {
                    exportCSV()
                } label: {
                    Label("Copy as CSV", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(CentmondTheme.Spacing.lg)
        }
    }

    private func datePresetButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
        }
        .buttonStyle(MutedChipButtonStyle())
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(CentmondTheme.Typography.captionMedium)
            .foregroundStyle(CentmondTheme.Colors.textTertiary)
            .tracking(0.5)
    }

    private func statRow(label: String, value: String, color: Color = CentmondTheme.Colors.textPrimary) -> some View {
        HStack {
            Text(label)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(CentmondTheme.Motion.numeric, value: value)
        }
    }

    // MARK: - Report Preview

    private var reportPreview: some View {
        Group {
            if filteredTransactions.isEmpty {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    heading: "No data for this period",
                    description: "Try adjusting the date range or add transactions."
                )
                .transition(.opacity)
            } else {
                ScrollView {
                    VStack(spacing: CentmondTheme.Spacing.xxl) {
                        // Title
                        VStack(spacing: CentmondTheme.Spacing.xs) {
                            Text(reportType.rawValue)
                                .font(CentmondTheme.Typography.heading1)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)

                            Text("\(startDate.formatted(.dateTime.month().day().year())) — \(endDate.formatted(.dateTime.month().day().year()))")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }

                        // Chart
                        reportChart

                        // Data table
                        reportTable
                    }
                    .padding(CentmondTheme.Spacing.xxl)
                }
            }
        }
    }

    @ViewBuilder
    private var reportChart: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                switch reportType {
                case .incomeVsExpense:
                    incomeVsExpenseChart
                        .transition(.opacity)
                case .spendingByCategory:
                    spendingByCategoryChart
                        .transition(.opacity)
                case .monthlyTrend:
                    monthlyTrendChart
                        .transition(.opacity)
                }
            }
            .animation(CentmondTheme.Motion.layout, value: reportType)
        }
    }

    private var incomeVsExpenseChart: some View {
        let grouped = groupTransactionsByPeriod()
        return Chart(grouped, id: \.period) { item in
            BarMark(
                x: .value("Period", item.period),
                y: .value("Amount", item.income)
            )
            .foregroundStyle(CentmondTheme.Colors.positive.gradient)
            .cornerRadius(3)
            .position(by: .value("Type", "Income"))

            BarMark(
                x: .value("Period", item.period),
                y: .value("Amount", item.expenses)
            )
            .foregroundStyle(CentmondTheme.Colors.negative.gradient)
            .cornerRadius(3)
            .position(by: .value("Type", "Expense"))
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let val = value.as(Double.self) {
                        Text(CurrencyFormat.abbreviated(val))
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.4))
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
        }
        .chartForegroundStyleScale(["Income": CentmondTheme.Colors.positive, "Expense": CentmondTheme.Colors.negative])
        .frame(height: 300)
    }

    private var spendingByCategoryChart: some View {
        let categoryData = getCategoryBreakdown()
        return VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
            Chart(categoryData, id: \.name) { item in
                SectorMark(
                    angle: .value("Amount", item.amount),
                    innerRadius: .ratio(0.6),
                    angularInset: 1
                )
                .foregroundStyle(item.color)
                .cornerRadius(3)
            }
            .frame(height: 300)

            // Legend
            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                ForEach(categoryData, id: \.name) { item in
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 8, height: 8)

                        Text(item.name)
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .lineLimit(1)

                        Spacer()

                        let pct = totalExpenses > 0
                            ? Int(Double(truncating: (Decimal(item.amount) / totalExpenses * 100) as NSDecimalNumber))
                            : 0
                        Text("\(pct)%")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var monthlyTrendChart: some View {
        let grouped = groupTransactionsByPeriod()
        return Chart {
            ForEach(grouped, id: \.period) { item in
                LineMark(
                    x: .value("Period", item.period),
                    y: .value("Net", item.income - item.expenses)
                )
                .foregroundStyle(CentmondTheme.Colors.accent)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                AreaMark(
                    x: .value("Period", item.period),
                    y: .value("Net", item.income - item.expenses)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [CentmondTheme.Colors.accent.opacity(0.2), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
            }

            // Zero line — outside ForEach so it renders once
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(CentmondTheme.Colors.strokeDefault)
                .lineStyle(StrokeStyle(lineWidth: 0.5))
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let val = value.as(Double.self) {
                        Text(CurrencyFormat.abbreviated(val))
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.4))
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
        }
        .frame(height: 300)
    }

    // MARK: - Report Table

    @ViewBuilder
    private var reportTable: some View {
        switch reportType {
        case .incomeVsExpense, .monthlyTrend:
            periodTable
        case .spendingByCategory:
            categoryTable
        }
    }

    private var periodTable: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Breakdown by \(groupBy.rawValue)")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                let grouped = groupTransactionsByPeriod()
                VStack(spacing: 0) {
                    HStack {
                        Text("Period")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Income")
                            .frame(width: 100, alignment: .trailing)
                        Text("Expenses")
                            .frame(width: 100, alignment: .trailing)
                        Text("Net")
                            .frame(width: 100, alignment: .trailing)
                    }
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .padding(.vertical, CentmondTheme.Spacing.sm)

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    ForEach(grouped, id: \.period) { item in
                        HStack {
                            Text(item.period)
                                .font(CentmondTheme.Typography.bodyMedium)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(CurrencyFormat.compact(Decimal(item.income)))
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.positive)
                                .monospacedDigit()
                                .frame(width: 100, alignment: .trailing)

                            Text(CurrencyFormat.compact(Decimal(item.expenses)))
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.negative)
                                .monospacedDigit()
                                .frame(width: 100, alignment: .trailing)

                            let net = item.income - item.expenses
                            Text(CurrencyFormat.compact(Decimal(net)))
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                                .monospacedDigit()
                                .frame(width: 100, alignment: .trailing)
                        }
                        .padding(.vertical, CentmondTheme.Spacing.sm)

                        Divider().background(CentmondTheme.Colors.strokeSubtle)
                    }

                    // Totals row
                    HStack {
                        Text("Total")
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(CurrencyFormat.compact(totalIncome))
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.positive)
                            .monospacedDigit()
                            .frame(width: 100, alignment: .trailing)

                        Text(CurrencyFormat.compact(totalExpenses))
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.negative)
                            .monospacedDigit()
                            .frame(width: 100, alignment: .trailing)

                        Text(CurrencyFormat.compact(totalIncome - totalExpenses))
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(totalIncome >= totalExpenses ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                            .monospacedDigit()
                            .frame(width: 100, alignment: .trailing)
                    }
                    .padding(.vertical, CentmondTheme.Spacing.sm)
                    .background(CentmondTheme.Colors.bgTertiary.opacity(0.5))
                }
            }
        }
    }

    private var categoryTable: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Spending by Category")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                let categoryData = getCategoryBreakdown()
                VStack(spacing: 0) {
                    HStack {
                        Text("Category")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Transactions")
                            .frame(width: 100, alignment: .trailing)
                        Text("Amount")
                            .frame(width: 120, alignment: .trailing)
                        Text("% of Total")
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .padding(.vertical, CentmondTheme.Spacing.sm)

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    ForEach(categoryData, id: \.name) { item in
                        HStack {
                            HStack(spacing: CentmondTheme.Spacing.sm) {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 8, height: 8)
                                Text(item.name)
                                    .font(CentmondTheme.Typography.bodyMedium)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text("\(item.count)")
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                                .monospacedDigit()
                                .frame(width: 100, alignment: .trailing)

                            Text(CurrencyFormat.compact(Decimal(item.amount)))
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.negative)
                                .monospacedDigit()
                                .frame(width: 120, alignment: .trailing)

                            let pct = totalExpenses > 0
                                ? Int(Double(truncating: (Decimal(item.amount) / totalExpenses * 100) as NSDecimalNumber))
                                : 0
                            Text("\(pct)%")
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .monospacedDigit()
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.vertical, CentmondTheme.Spacing.sm)

                        // Proportion bar
                        GeometryReader { geo in
                            let maxAmount = categoryData.first?.amount ?? 1
                            RoundedRectangle(cornerRadius: 2)
                                .fill(item.color.opacity(0.2))
                                .frame(width: geo.size.width * (item.amount / maxAmount))
                                .animation(CentmondTheme.Motion.default, value: item.amount)
                        }
                        .frame(height: 3)

                        Divider().background(CentmondTheme.Colors.strokeSubtle)
                    }
                }
            }
        }
    }

    // MARK: - Export

    private func exportCSV() {
        var csv = ""
        switch reportType {
        case .incomeVsExpense, .monthlyTrend:
            csv = "Period,Income,Expenses,Net\n"
            for item in groupTransactionsByPeriod() {
                csv += "\(item.period),\(item.income),\(item.expenses),\(item.income - item.expenses)\n"
            }
        case .spendingByCategory:
            csv = "Category,Amount,Transactions\n"
            for item in getCategoryBreakdown() {
                csv += "\(item.name),\(item.amount),\(item.count)\n"
            }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
    }

    // MARK: - Data Processing

    private struct PeriodData {
        let period: String
        let sortKey: String
        let income: Double
        let expenses: Double
    }

    private func groupTransactionsByPeriod() -> [PeriodData] {
        let formatter = DateFormatter()
        let sortFormatter = DateFormatter()

        switch groupBy {
        case .week:
            formatter.dateFormat = "'W'w yy"
            sortFormatter.dateFormat = "yyww"
        case .month:
            formatter.dateFormat = "MMM yy"
            sortFormatter.dateFormat = "yyMM"
        case .quarter:
            formatter.dateFormat = "'Q'Q yy"
            sortFormatter.dateFormat = "yyQ"
        }

        var grouped: [String: (income: Double, expenses: Double, sortKey: String)] = [:]

        for tx in filteredTransactions where !tx.isTransfer {
            let key = formatter.string(from: tx.date)
            let sortKey = sortFormatter.string(from: tx.date)
            let amount = NSDecimalNumber(decimal: tx.amount).doubleValue
            var entry = grouped[key] ?? (income: 0, expenses: 0, sortKey: sortKey)
            if entry.sortKey.isEmpty { entry.sortKey = sortKey }
            if tx.isIncome {
                entry.income += amount
            } else {
                entry.expenses += amount
            }
            grouped[key] = entry
        }

        return grouped.map { PeriodData(period: $0.key, sortKey: $0.value.sortKey, income: $0.value.income, expenses: $0.value.expenses) }
            .sorted { $0.sortKey < $1.sortKey }
    }

    private struct CategoryData {
        let name: String
        let amount: Double
        let count: Int
        let color: Color
    }

    private func getCategoryBreakdown() -> [CategoryData] {
        let expenses = filteredTransactions.filter(BalanceService.isSpendingExpense)
        var byCategory: [String: (amount: Double, count: Int)] = [:]

        for tx in expenses {
            let catName = tx.category?.name ?? "Uncategorized"
            var entry = byCategory[catName] ?? (amount: 0, count: 0)
            entry.amount += NSDecimalNumber(decimal: tx.amount).doubleValue
            entry.count += 1
            byCategory[catName] = entry
        }

        let palette = CentmondTheme.Colors.chartPalette
        return byCategory.enumerated().map { index, item in
            CategoryData(
                name: item.key,
                amount: item.value.amount,
                count: item.value.count,
                color: palette[index % palette.count]
            )
        }
        .sorted { $0.amount > $1.amount }
    }


}
