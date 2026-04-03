import SwiftUI
import SwiftData

struct NewBudgetCategorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var icon = "cart.fill"
    @State private var colorHex = "3B82F6"
    @State private var budgetAmount = ""
    @State private var isExpenseCategory = true
    @State private var hasAttemptedSave = false

    private let expenseIcons = [
        "cart.fill", "house.fill", "car.fill", "fork.knife", "film.fill",
        "heart.fill", "bolt.fill", "tshirt.fill", "gift.fill", "books.vertical.fill",
        "airplane", "cross.case.fill", "dumbbell.fill", "graduationcap.fill",
        "paintbrush.fill", "gamecontroller.fill"
    ]

    private let incomeIcons = [
        "banknote.fill", "briefcase.fill", "chart.line.uptrend.xyaxis", "laptopcomputer",
        "building.2.fill", "person.crop.circle.fill", "star.fill", "dollarsign.circle.fill",
        "wallet.bifold.fill", "giftcard.fill", "percent", "arrow.down.to.line",
        "hands.sparkles.fill", "house.lodge.fill", "music.note", "wrench.and.screwdriver.fill"
    ]

    private let expenseColors = [
        "3B82F6", // Blue
        "8B5CF6", // Purple
        "EC4899", // Pink
        "F97316", // Orange
        "22C55E", // Green
        "06B6D4", // Cyan
        "EAB308", // Yellow
        "EF4444", // Red
    ]

    private let incomeColors = [
        "22C55E", // Green
        "10B981", // Emerald
        "06B6D4", // Cyan
        "3B82F6", // Blue
        "14B8A6", // Teal
        "84CC16", // Lime
        "A3E635", // Light green
        "34D399", // Mint
    ]

    private var activeIcons: [String] { isExpenseCategory ? expenseIcons : incomeIcons }
    private var activeColors: [String] { isExpenseCategory ? expenseColors : incomeColors }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Decimal(string: budgetAmount) ?? 0) > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Budget Category")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(CentmondTheme.Colors.bgQuaternary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.top, CentmondTheme.Spacing.xl)
            .padding(.bottom, CentmondTheme.Spacing.lg)

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xl) {
                    // Type toggle — first, so icons/colors update
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                        Text("CATEGORY TYPE")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.3)

                        Picker("", selection: $isExpenseCategory) {
                            Text("Expense").tag(true)
                            Text("Income").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }

                    formField(
                        "CATEGORY NAME",
                        showError: hasAttemptedSave && name.trimmingCharacters(in: .whitespaces).isEmpty
                    ) {
                        TextField(
                            isExpenseCategory ? "e.g., Groceries" : "e.g., Salary",
                            text: $name
                        )
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    // Icon selector
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                        Text("ICON")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.3)

                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: CentmondTheme.Spacing.sm), count: 8), spacing: CentmondTheme.Spacing.sm) {
                            ForEach(activeIcons, id: \.self) { opt in
                                Button {
                                    icon = opt
                                } label: {
                                    Image(systemName: opt)
                                        .font(.system(size: 14))
                                        .frame(width: 36, height: 36)
                                        .foregroundStyle(icon == opt ? Color(hex: colorHex) : CentmondTheme.Colors.textTertiary)
                                        .background(icon == opt ? Color(hex: colorHex).opacity(0.15) : CentmondTheme.Colors.bgQuaternary)
                                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm)
                                                .stroke(icon == opt ? Color(hex: colorHex) : .clear, lineWidth: 1.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .animation(CentmondTheme.Motion.default, value: isExpenseCategory)
                    }

                    // Color selector
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                        Text("COLOR")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.3)

                        HStack(spacing: CentmondTheme.Spacing.sm) {
                            ForEach(activeColors, id: \.self) { hex in
                                Button {
                                    colorHex = hex
                                } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(colorHex == hex ? 0.8 : 0), lineWidth: 2)
                                        )
                                        .overlay(
                                            Circle()
                                                .stroke(CentmondTheme.Colors.bgInput, lineWidth: colorHex == hex ? 3 : 0)
                                                .padding(-2)
                                        )
                                        .overlay(
                                            Circle()
                                                .stroke(Color(hex: hex).opacity(colorHex == hex ? 1 : 0), lineWidth: 2)
                                                .padding(-4)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .animation(CentmondTheme.Motion.default, value: isExpenseCategory)
                    }

                    formField(
                        isExpenseCategory ? "DEFAULT SPENDING LIMIT" : "DEFAULT EXPECTED AMOUNT",
                        showError: hasAttemptedSave && (Decimal(string: budgetAmount) ?? 0) <= 0
                    ) {
                        HStack {
                            Text("$")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            TextField(isExpenseCategory ? "500.00" : "3000.00", text: $budgetAmount)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }

                    Text(isExpenseCategory
                         ? "Default spending limit for this category. Adjustable per month in Budget Plan."
                         : "Expected income for this category. Adjustable per month in Budget Plan.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            HStack {
                // Preview
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: colorHex))
                    if !name.isEmpty {
                        Text(name)
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())

                Button("Create Category") {
                    hasAttemptedSave = true
                    if isValid { saveCategory() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 520)
        .onChange(of: isExpenseCategory) {
            // Reset icon and color to first option of the new type
            let icons = isExpenseCategory ? expenseIcons : incomeIcons
            let colors = isExpenseCategory ? expenseColors : incomeColors
            if !icons.contains(icon) { icon = icons.first ?? icon }
            if !colors.contains(colorHex) { colorHex = colors.first ?? colorHex }
        }
    }

    @ViewBuilder
    private func formField<Content: View>(_ label: String, showError: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text(label)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(showError ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textTertiary)
                .tracking(0.3)

            content()
                .padding(.horizontal, CentmondTheme.Spacing.sm)
                .frame(height: CentmondTheme.Sizing.inputHeight)
                .background(CentmondTheme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                        .stroke(showError ? CentmondTheme.Colors.negative : CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                )
        }
    }

    private func saveCategory() {
        let amount = Decimal(string: budgetAmount) ?? 0
        let category = BudgetCategory(
            name: name.trimmingCharacters(in: .whitespaces),
            icon: icon,
            colorHex: colorHex,
            budgetAmount: amount,
            isExpenseCategory: isExpenseCategory
        )
        modelContext.insert(category)
        dismiss()
    }
}
