import SwiftUI
import SwiftData

struct BudgetView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query private var transactions: [Transaction]
    @Query private var monthlyBudgets: [MonthlyBudget]
    @Query private var totalBudgets: [MonthlyTotalBudget]

    @State private var showDeleteConfirmation = false
    @State private var categoryToDelete: BudgetCategory?

    private var monthStart: Date { router.selectedMonthStart }
    private var monthEnd: Date { router.selectedMonthEnd }
    private var selectedYear: Int { Calendar.current.component(.year, from: router.selectedMonth) }
    private var selectedMonthNum: Int { Calendar.current.component(.month, from: router.selectedMonth) }

    private var monthlyTransactions: [Transaction] {
        transactions.filter { !$0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
    }

    // MARK: - Main Monthly Budget

    /// The total budget the user has set for this month (nil = not set yet).
    private var monthlyTotalBudget: MonthlyTotalBudget? {
        totalBudgets.first { $0.year == selectedYear && $0.month == selectedMonthNum }
    }

    /// The total budget amount, 0 if not set.
    private var totalBudgetAmount: Decimal {
        monthlyTotalBudget?.amount ?? 0
    }

    // MARK: - Category Budgets

    /// Returns the budget amount for a category in the selected month.
    private func effectiveBudget(for category: BudgetCategory) -> Decimal {
        monthlyBudgets.first(where: {
            $0.categoryID == category.id && $0.year == selectedYear && $0.month == selectedMonthNum
        })?.amount ?? category.budgetAmount
    }

    /// Sum of all category budget allocations.
    private var totalAllocated: Decimal {
        categories.reduce(0) { $0 + effectiveBudget(for: $1) }
    }

    /// How much of the main budget is not yet allocated to categories.
    private var unallocated: Decimal {
        totalBudgetAmount - totalAllocated
    }

    private func spentInCategory(_ category: BudgetCategory) -> Decimal {
        monthlyTransactions
            .filter { $0.category?.id == category.id }
            .reduce(0) { $0 + $1.amount }
    }

    private func transactionCountInCategory(_ category: BudgetCategory) -> Int {
        monthlyTransactions
            .filter { $0.category?.id == category.id }
            .count
    }

    private var totalSpent: Decimal {
        monthlyTransactions.reduce(0) { $0 + $1.amount }
    }

    private var uncategorizedSpent: Decimal {
        monthlyTransactions
            .filter { $0.category == nil }
            .reduce(0) { $0 + $1.amount }
    }

    private var uncategorizedCount: Int {
        monthlyTransactions.filter { $0.category == nil }.count
    }

    private var selectedCategoryID: UUID? {
        if case .budgetCategory(let id) = router.inspectorContext { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            if categories.isEmpty && totalBudgetAmount == 0 {
                EmptyStateView(
                    icon: "chart.pie",
                    heading: "No budget set up",
                    description: "Set a monthly spending limit and create categories to track where your money goes.",
                    primaryAction: "Plan Budget",
                    onPrimaryAction: { router.showSheet(.budgetPlanner) }
                )
            } else {
                ScrollView {
                    VStack(spacing: CentmondTheme.Spacing.xl) {
                        // Main monthly budget card
                        mainBudgetCard

                        // Category allocations
                        if !categories.isEmpty {
                            categorySection
                        }

                        if uncategorizedSpent > 0 {
                            uncategorizedBar
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(CentmondTheme.Spacing.xxl)
                }
            }
        }
        .alert("Delete Category", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { categoryToDelete = nil }
            Button("Delete", role: .destructive) {
                if let category = categoryToDelete {
                    if case .budgetCategory(let id) = router.inspectorContext, id == category.id {
                        router.inspectorContext = .none
                    }
                    for tx in category.transactions {
                        tx.category = nil
                    }
                    modelContext.delete(category)
                }
                categoryToDelete = nil
            }
        } message: {
            if let category = categoryToDelete {
                let txCount = category.transactions.count
                if txCount > 0 {
                    Text("This will delete \"\(category.name)\" and uncategorize \(txCount) transaction\(txCount == 1 ? "" : "s"). This cannot be undone.")
                } else {
                    Text("This will delete \"\(category.name)\". This cannot be undone.")
                }
            } else {
                Text("This will delete this category.")
            }
        }
    }

    // MARK: - Header Bar

    @Namespace private var budgetHeaderNamespace

    private var headerBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(router.selectedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .contentTransition(.numericText())
                    .animation(CentmondTheme.Motion.numeric, value: router.selectedMonth)

                Text("Budget")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Spacer()

            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 0) {
                    Button {
                        router.showSheet(.newBudgetCategory)
                    } label: {
                        HStack(spacing: CentmondTheme.Spacing.xs) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Category")
                                .font(CentmondTheme.Typography.captionMedium)
                        }
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .padding(.horizontal, CentmondTheme.Spacing.md)
                        .frame(height: 30)
                    }
                    .buttonStyle(.plainHover)
                    .help("Add a new budget category")
                    .glassEffect(.regular, in: .rect(cornerRadius: CentmondTheme.Radius.sm))
                    .glassEffectUnion(id: "budgetActions", namespace: budgetHeaderNamespace)

                    Button {
                        router.showSheet(.budgetPlanner)
                    } label: {
                        HStack(spacing: CentmondTheme.Spacing.xs) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Plan Budget")
                                .font(CentmondTheme.Typography.captionMedium)
                        }
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .padding(.horizontal, CentmondTheme.Spacing.md)
                        .frame(height: 30)
                    }
                    .buttonStyle(.plainHover)
                    .help("Plan and allocate your monthly budget")
                    .glassEffect(.regular, in: .rect(cornerRadius: CentmondTheme.Radius.sm))
                    .glassEffectUnion(id: "budgetActions", namespace: budgetHeaderNamespace)
                }
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
    }

    // MARK: - Main Budget Card

    private var mainBudgetCard: some View {
        let remaining = totalBudgetAmount - totalSpent
        let isOverBudget = totalSpent > totalBudgetAmount && totalBudgetAmount > 0
        let spentProgress: Double = totalBudgetAmount > 0
            ? min(Double(truncating: (totalSpent / totalBudgetAmount) as NSDecimalNumber), 1.0) : 0
        let allocatedProgress: Double = totalBudgetAmount > 0
            ? min(Double(truncating: (totalAllocated / totalBudgetAmount) as NSDecimalNumber), 1.0) : 0
        let spentColor: Color = isOverBudget ? CentmondTheme.Colors.negative
            : spentProgress > 0.85 ? CentmondTheme.Colors.warning
            : CentmondTheme.Colors.accent

        return VStack(spacing: CentmondTheme.Spacing.lg) {
            // Title row
            HStack(alignment: .firstTextBaseline) {
                Text("Monthly Budget")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                Spacer()

                if totalBudgetAmount > 0 {
                    Text(CurrencyFormat.standard(totalBudgetAmount))
                        .font(CentmondTheme.Typography.heading2)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                } else {
                    Text("Not set")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }

            if totalBudgetAmount > 0 {
                // Stacked progress bars
                VStack(spacing: CentmondTheme.Spacing.sm) {
                    // Spent progress
                    VStack(spacing: 4) {
                        HStack {
                            Text("SPENT")
                                .font(CentmondTheme.Typography.overline)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .tracking(0.5)
                            Spacer()
                            Text("\(Int(spentProgress * 100))%")
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(spentColor)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(CentmondTheme.Motion.numeric, value: spentProgress)
                        }

                        ProgressBarView(progress: spentProgress, color: spentColor, height: 8, cornerRadius: 4)
                    }

                    // Allocated progress
                    VStack(spacing: 4) {
                        HStack {
                            Text("ALLOCATED TO CATEGORIES")
                                .font(CentmondTheme.Typography.overline)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .tracking(0.5)
                            Spacer()
                            Text("\(Int(allocatedProgress * 100))%")
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(allocatedProgress > 1.0 ? CentmondTheme.Colors.warning : CentmondTheme.Colors.positive)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(CentmondTheme.Motion.numeric, value: allocatedProgress)
                        }

                        ProgressBarView(
                            progress: min(allocatedProgress, 1.0),
                            color: allocatedProgress > 1.0 ? CentmondTheme.Colors.warning : CentmondTheme.Colors.positive,
                            height: 8,
                            cornerRadius: 4
                        )
                    }
                }

                // Detail grid
                HStack(spacing: 0) {
                    detailCell(
                        label: "Spent",
                        value: CurrencyFormat.standard(totalSpent),
                        color: spentColor
                    )

                    dividerLine

                    detailCell(
                        label: "Remaining",
                        value: CurrencyFormat.standard(remaining),
                        color: remaining < 0 ? CentmondTheme.Colors.negative : CentmondTheme.Colors.positive
                    )

                    dividerLine

                    detailCell(
                        label: "Allocated",
                        value: CurrencyFormat.standard(totalAllocated),
                        color: CentmondTheme.Colors.textPrimary
                    )

                    dividerLine

                    detailCell(
                        label: "Unallocated",
                        value: CurrencyFormat.standard(unallocated < 0 ? 0 : unallocated),
                        color: unallocated < 0 ? CentmondTheme.Colors.warning : CentmondTheme.Colors.textTertiary
                    )
                }
                .padding(.top, CentmondTheme.Spacing.xs)

                // Warnings
                if isOverBudget {
                    warningBadge(
                        icon: "exclamationmark.triangle.fill",
                        text: "\(CurrencyFormat.standard(totalSpent - totalBudgetAmount)) over budget",
                        color: CentmondTheme.Colors.negative
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                if unallocated < 0 {
                    warningBadge(
                        icon: "exclamationmark.circle.fill",
                        text: "Categories exceed budget by \(CurrencyFormat.standard(-unallocated))",
                        color: CentmondTheme.Colors.warning
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            } else {
                // No budget set — prompt
                VStack(spacing: CentmondTheme.Spacing.md) {
                    Text("Set a monthly spending limit to track how your money is spent across categories.")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .multilineTextAlignment(.center)

                    Button {
                        router.showSheet(.budgetPlanner)
                    } label: {
                        Text("Set Monthly Budget")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Set up your monthly spending limit")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            // No transactions hint
            if totalBudgetAmount > 0 && monthlyTransactions.isEmpty {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(CentmondTheme.Colors.info)
                    Text("No transactions recorded yet for this month.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }
        }
        .padding(CentmondTheme.Spacing.xl)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    private func detailCell(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(value)
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(CentmondTheme.Motion.numeric, value: value)
        }
        .frame(maxWidth: .infinity)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(CentmondTheme.Colors.strokeSubtle)
            .frame(width: 1, height: 32)
    }

    private func warningBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
            Text(text)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(color)
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
    }

    // MARK: - Category Section

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack {
                Text("Category Budgets")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                if totalBudgetAmount > 0 {
                    Text("· \(CurrencyFormat.standard(totalAllocated)) of \(CurrencyFormat.standard(totalBudgetAmount))")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .monospacedDigit()
                }

                Spacer()
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg),
                    GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg),
                    GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg),
                ],
                spacing: CentmondTheme.Spacing.lg
            ) {
                ForEach(categories) { category in
                    let budget = effectiveBudget(for: category)
                    let share: Double = totalBudgetAmount > 0
                        ? Double(truncating: (budget / totalBudgetAmount) as NSDecimalNumber) : 0

                    BudgetCategoryCardView(
                        category: category,
                        budget: budget,
                        spent: spentInCategory(category),
                        txCount: transactionCountInCategory(category),
                        shareOfTotal: share,
                        totalBudgetSet: totalBudgetAmount > 0,
                        isSelected: selectedCategoryID == category.id,
                        onTap: { router.inspectBudgetCategory(category.id) },
                        onDelete: {
                            categoryToDelete = category
                            showDeleteConfirmation = true
                        }
                    )
                }
            }
        }
    }

    // MARK: - Uncategorized

    private var uncategorizedBar: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(CentmondTheme.Colors.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(CurrencyFormat.standard(uncategorizedSpent)) uncategorized")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)

                Text("\(uncategorizedCount) transaction\(uncategorizedCount == 1 ? "" : "s") this month")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Spacer()

            Button("Review") {
                router.navigate(to: .transactions)
            }
            .font(CentmondTheme.Typography.captionMedium)
            .foregroundStyle(CentmondTheme.Colors.accent)
            .buttonStyle(.plainHover)
            .help("Review uncategorized transactions")
        }
        .padding(CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.warningMuted.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .stroke(CentmondTheme.Colors.warning.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Budget Category Card

private struct BudgetCategoryCardView: View {
    let category: BudgetCategory
    let budget: Decimal
    let spent: Decimal
    let txCount: Int
    var shareOfTotal: Double = 0
    var totalBudgetSet: Bool = false
    var isSelected: Bool = false
    var onTap: () -> Void = {}
    var onDelete: (() -> Void)?

    @State private var isHovered = false
    private var remaining: Decimal { budget - spent }
    private var progress: Double { budget > 0 ? Double(truncating: (spent / budget) as NSDecimalNumber) : 0 }
    private var isOverBudget: Bool { spent > budget && budget > 0 }

    var body: some View {
        let accentColor = isOverBudget ? CentmondTheme.Colors.negative : Color(hex: category.colorHex)
        let pct = budget > 0 ? Int(min(progress, 9.99) * 100) : 0

        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            // Header row
            HStack(alignment: .center, spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 28, height: 28)
                    .background(accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

                Text(category.name)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text("\(pct)%")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(isOverBudget ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textTertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(CentmondTheme.Motion.numeric, value: pct)
            }

            // Amount row
            HStack(alignment: .firstTextBaseline) {
                if txCount == 0 {
                    Text("No spending")
                        .font(CentmondTheme.Typography.monoLarge)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .monospacedDigit()
                } else {
                    Text(CurrencyFormat.standard(spent))
                        .font(CentmondTheme.Typography.monoLarge)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(CentmondTheme.Motion.numeric, value: spent)
                }

                Spacer()

                Text("of \(CurrencyFormat.standard(budget))")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .monospacedDigit()
            }

            // Progress bar — avoid GeometryReader in grid
            ProgressBarView(progress: min(progress, 1.0), color: accentColor, height: 5)

            // Footer row
            HStack {
                Text(isOverBudget
                     ? "\(CurrencyFormat.standard(-remaining)) over"
                     : "\(CurrencyFormat.standard(remaining)) left")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(isOverBudget ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textTertiary)
                    .monospacedDigit()

                Spacer()

                if totalBudgetSet && shareOfTotal > 0 {
                    Text("\(Int(shareOfTotal * 100))% of budget")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                } else if txCount > 0 {
                    Text("\(txCount) txn\(txCount == 1 ? "" : "s")")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
        }
        .padding(CentmondTheme.Spacing.lg)
        .background(isOverBudget ? CentmondTheme.Colors.negative.opacity(0.05) : CentmondTheme.Colors.bgSecondary)
        .overlay(alignment: .top) {
            if isOverBudget {
                Rectangle()
                    .fill(CentmondTheme.Colors.negative)
                    .frame(height: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(
                    isSelected ? CentmondTheme.Colors.accent :
                    isOverBudget ? CentmondTheme.Colors.negative.opacity(0.4) :
                    isHovered ? CentmondTheme.Colors.strokeDefault : CentmondTheme.Colors.strokeSubtle,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .shadow(color: isHovered ? .black.opacity(0.2) : .clear, radius: 6, y: 2)
        .onHover { hovering in
            if hovering { Haptics.tick() }
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
        .onTapGesture { onTap() }
        .contextMenu {
            Button {
                onTap()
            } label: {
                Label("View Details", systemImage: "eye")
            }
            Divider()
            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Category", systemImage: "trash")
                }
            }
        }
    }
}
