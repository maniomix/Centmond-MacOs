import SwiftUI
import SwiftData

struct BudgetPlannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query private var monthlyBudgets: [MonthlyBudget]
    @Query private var totalBudgets: [MonthlyTotalBudget]

    @State private var amounts: [UUID: String] = [:]
    @State private var totalBudgetText: String = ""
    @State private var showNewCategory = false

    private var selectedYear: Int  { Calendar.current.component(.year,  from: router.selectedMonth) }
    private var selectedMonthNum: Int { Calendar.current.component(.month, from: router.selectedMonth) }

    private var expenseCategories: [BudgetCategory] { categories.filter { $0.isExpenseCategory } }

    private var totalBudgetAmount: Decimal {
        Decimal(string: totalBudgetText) ?? 0
    }

    private var totalAllocated: Decimal {
        expenseCategories.reduce(Decimal.zero) {
            $0 + (Decimal(string: amounts[$1.id] ?? "") ?? 0)
        }
    }

    private var unallocated: Decimal {
        totalBudgetAmount - totalAllocated
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Budget Plan")
                        .font(CentmondTheme.Typography.heading2)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text(router.selectedMonth.formatted(.dateTime.month(.wide).year()))
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(CentmondTheme.Colors.bgQuaternary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plainHover)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.top, CentmondTheme.Spacing.xl)
            .padding(.bottom, CentmondTheme.Spacing.lg)

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(spacing: 0) {
                    // MARK: - Total Monthly Budget
                    VStack(spacing: CentmondTheme.Spacing.md) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MONTHLY BUDGET")
                                    .font(CentmondTheme.Typography.overline)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .tracking(0.5)
                                Text("Total spending limit for this month")
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            }

                            Spacer()

                            HStack(spacing: 4) {
                                Text("$")
                                    .font(CentmondTheme.Typography.heading3)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                TextField("0.00", text: $totalBudgetText)
                                    .textFieldStyle(.plain)
                                    .font(CentmondTheme.Typography.heading2)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                    .monospacedDigit()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 140)
                            }
                            .padding(.horizontal, CentmondTheme.Spacing.md)
                            .frame(height: 44)
                            .background(CentmondTheme.Colors.bgInput)
                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                                    .stroke(CentmondTheme.Colors.accent.opacity(0.5), lineWidth: 1.5)
                            )
                        }

                        // Allocation summary
                        if totalBudgetAmount > 0 && !expenseCategories.isEmpty {
                            HStack(spacing: CentmondTheme.Spacing.lg) {
                                allocationSummaryItem(
                                    label: "Allocated",
                                    value: CurrencyFormat.standard(totalAllocated),
                                    color: CentmondTheme.Colors.textPrimary
                                )
                                allocationSummaryItem(
                                    label: "Unallocated",
                                    value: CurrencyFormat.standard(unallocated < 0 ? 0 : unallocated),
                                    color: unallocated < 0 ? CentmondTheme.Colors.warning : CentmondTheme.Colors.positive
                                )

                                Spacer()

                                if unallocated < 0 {
                                    HStack(spacing: CentmondTheme.Spacing.xs) {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(CentmondTheme.Colors.warning)
                                        Text("Over-allocated by \(CurrencyFormat.standard(-unallocated))")
                                            .font(CentmondTheme.Typography.caption)
                                            .foregroundStyle(CentmondTheme.Colors.warning)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, CentmondTheme.Spacing.xxl)
                    .padding(.vertical, CentmondTheme.Spacing.lg)
                    .background(CentmondTheme.Colors.bgQuaternary.opacity(0.5))

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    if expenseCategories.isEmpty {
                        VStack(spacing: CentmondTheme.Spacing.lg) {
                            Image(systemName: "chart.pie")
                                .font(.system(size: 40))
                                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            Text("No categories yet")
                                .font(CentmondTheme.Typography.heading3)
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            Text("Add expense categories to allocate your budget.")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .multilineTextAlignment(.center)
                            Button("Add First Category") { showNewCategory = true }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(CentmondTheme.Spacing.xxl)
                    } else {
                        // MARK: - Category Allocations
                        VStack(spacing: 0) {
                            HStack(spacing: CentmondTheme.Spacing.sm) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(CentmondTheme.Colors.info)
                                Text("Set how much of your monthly budget each category gets. Leaving a field empty uses the default amount.")
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            }
                            .padding(.horizontal, CentmondTheme.Spacing.xxl)
                            .padding(.vertical, CentmondTheme.Spacing.md)

                            Divider().background(CentmondTheme.Colors.strokeSubtle)

                            ForEach(expenseCategories) { category in
                                categoryRow(category)
                            }

                            // Total row
                            HStack {
                                Text("Total Allocated")
                                    .font(CentmondTheme.Typography.bodyMedium)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                Spacer()

                                if totalBudgetAmount > 0 {
                                    let pct = totalBudgetAmount > 0
                                        ? Int(Double(truncating: (totalAllocated / totalBudgetAmount * 100) as NSDecimalNumber))
                                        : 0
                                    Text("\(pct)%")
                                        .font(CentmondTheme.Typography.captionMedium)
                                        .foregroundStyle(totalAllocated > totalBudgetAmount ? CentmondTheme.Colors.warning : CentmondTheme.Colors.textTertiary)
                                        .monospacedDigit()
                                        .padding(.trailing, CentmondTheme.Spacing.md)
                                }

                                Text(CurrencyFormat.standard(totalAllocated))
                                    .font(CentmondTheme.Typography.monoLarge)
                                    .foregroundStyle(CentmondTheme.Colors.accent)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, CentmondTheme.Spacing.xxl)
                            .padding(.vertical, CentmondTheme.Spacing.lg)
                            .background(CentmondTheme.Colors.bgQuaternary)
                            .overlay(alignment: .top) {
                                Rectangle().fill(CentmondTheme.Colors.strokeDefault).frame(height: 1)
                            }
                        }
                    }
                }
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Footer
            HStack {
                Button {
                    showNewCategory = true
                } label: {
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Add Category")
                            .font(CentmondTheme.Typography.captionMedium)
                    }
                    .foregroundStyle(CentmondTheme.Colors.accent)
                }
                .buttonStyle(.plainHover)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())

                Button("Save Plan") { savePlan() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 540)
        .onAppear { loadAmounts() }
        .onChange(of: categories) { loadAmounts() }
        .onChange(of: router.selectedMonth) { loadAmounts(reset: true) }
        .sheet(isPresented: $showNewCategory) {
            NewBudgetCategorySheet()
                .frame(width: CentmondTheme.Sizing.sheetWidth)
                .background(CentmondTheme.Colors.bgTertiary)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: - Category Row

    private func categoryRow(_ category: BudgetCategory) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            Image(systemName: category.icon)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: category.colorHex))
                .frame(width: 30, height: 30)
                .background(Color(hex: category.colorHex).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Text("Default: \(CurrencyFormat.standard(category.budgetAmount))")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                    if totalBudgetAmount > 0, let amtStr = amounts[category.id], let amt = Decimal(string: amtStr), amt > 0 {
                        let share = Int(Double(truncating: (amt / totalBudgetAmount * 100) as NSDecimalNumber))
                        Text("· \(share)%")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Text("$")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                TextField("default", text: amountBinding(for: category))
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 88)
            }
            .padding(.horizontal, CentmondTheme.Spacing.sm)
            .frame(height: CentmondTheme.Sizing.inputHeight)
            .background(CentmondTheme.Colors.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                    .stroke(hasOverride(category) ? CentmondTheme.Colors.accent.opacity(0.5) : CentmondTheme.Colors.strokeDefault, lineWidth: 1)
            )
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    private func allocationSummaryItem(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(value)
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    // MARK: - Helpers

    private func amountBinding(for category: BudgetCategory) -> Binding<String> {
        Binding(
            get: { amounts[category.id] ?? "" },
            set: { amounts[category.id] = $0 }
        )
    }

    private func hasOverride(_ category: BudgetCategory) -> Bool {
        monthlyBudgets.contains {
            $0.categoryID == category.id && $0.year == selectedYear && $0.month == selectedMonthNum
        }
    }

    private func loadAmounts(reset: Bool = false) {
        // Load total budget
        if reset || totalBudgetText.isEmpty {
            if let existing = totalBudgets.first(where: { $0.year == selectedYear && $0.month == selectedMonthNum }) {
                totalBudgetText = "\(existing.amount)"
            } else {
                totalBudgetText = ""
            }
        }

        // Load category amounts
        for category in expenseCategories {
            if !reset, amounts[category.id] != nil { continue }
            let override = monthlyBudgets.first {
                $0.categoryID == category.id && $0.year == selectedYear && $0.month == selectedMonthNum
            }
            if let amt = override?.amount, amt > 0 {
                amounts[category.id] = "\(amt)"
            } else if category.budgetAmount > 0 {
                amounts[category.id] = "\(category.budgetAmount)"
            } else {
                amounts[category.id] = ""
            }
        }
    }

    private func savePlan() {
        // Save total monthly budget
        let totalAmt = Decimal(string: totalBudgetText) ?? 0
        if let existing = totalBudgets.first(where: { $0.year == selectedYear && $0.month == selectedMonthNum }) {
            existing.amount = totalAmt
        } else if totalAmt > 0 {
            modelContext.insert(MonthlyTotalBudget(year: selectedYear, month: selectedMonthNum, amount: totalAmt))
        }

        // Save category budgets
        for category in expenseCategories {
            let amt = Decimal(string: amounts[category.id] ?? "") ?? 0
            if let existing = monthlyBudgets.first(where: {
                $0.categoryID == category.id && $0.year == selectedYear && $0.month == selectedMonthNum
            }) {
                existing.amount = amt
            } else if amt > 0 {
                modelContext.insert(MonthlyBudget(
                    categoryID: category.id,
                    year: selectedYear,
                    month: selectedMonthNum,
                    amount: amt
                ))
            }
        }
        dismiss()
    }
}
