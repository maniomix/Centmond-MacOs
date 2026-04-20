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
    @State private var appeared = false

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
        "3B82F6", "8B5CF6", "EC4899", "F97316", "22C55E", "06B6D4", "EAB308", "EF4444"
    ]

    private let incomeColors = [
        "22C55E", "10B981", "06B6D4", "3B82F6", "14B8A6", "84CC16", "A3E635", "34D399"
    ]

    private var activeIcons: [String] { isExpenseCategory ? expenseIcons : incomeIcons }
    private var activeColors: [String] { isExpenseCategory ? expenseColors : incomeColors }
    private var accentColor: Color { Color(hex: colorHex) }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Decimal(string: budgetAmount) ?? 0) > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New Category") { dismiss() }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(spacing: CentmondTheme.Spacing.md) {

                    // Type chips
                    HStack(spacing: 8) {
                        typeChip("Expense", color: CentmondTheme.Colors.negative, selected: isExpenseCategory) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                isExpenseCategory = true
                                resetDefaults()
                            }
                        }
                        typeChip("Income", color: CentmondTheme.Colors.positive, selected: !isExpenseCategory) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                isExpenseCategory = false
                                resetDefaults()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .offset(y: appeared ? 0 : 8)
                    .opacity(appeared ? 1 : 0)
                    .animation(CentmondTheme.Motion.default.delay(0.05), value: appeared)

                    // Name + Icon + Color in one card
                    VStack(spacing: 1) {

                        // Name
                        fieldRow {
                            Image(systemName: icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(accentColor)
                                .frame(width: 16)
                            TextField(isExpenseCategory ? "Category name (e.g. Groceries)" : "Category name (e.g. Salary)", text: $name)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        }

                        Divider()
                            .background(CentmondTheme.Colors.strokeSubtle)
                            .padding(.leading, 44)

                        // Budget amount
                        fieldRow {
                            Image(systemName: "dollarsign")
                                .font(.system(size: 11))
                                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                .frame(width: 16)
                            TextField(isExpenseCategory ? "Monthly limit (e.g. 500)" : "Expected amount (e.g. 3000)", text: $budgetAmount)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }

                        Divider()
                            .background(CentmondTheme.Colors.strokeSubtle)
                            .padding(.leading, 44)

                        // Helper text
                        Text(isExpenseCategory
                             ? "Default spending limit for this category. Adjustable per month in Budget Plan."
                             : "Expected income for this category. Adjustable per month in Budget Plan.")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            .padding(.horizontal, CentmondTheme.Spacing.md)
                            .padding(.vertical, CentmondTheme.Spacing.sm)
                            .animation(CentmondTheme.Motion.micro, value: isExpenseCategory)
                    }
                    .background(CentmondTheme.Colors.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                            .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
                    )
                    .offset(y: appeared ? 0 : 8)
                    .opacity(appeared ? 1 : 0)
                    .animation(CentmondTheme.Motion.default.delay(0.1), value: appeared)

                    // Icon picker
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                        Text("Icon")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .padding(.leading, CentmondTheme.Spacing.xs)

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: CentmondTheme.Spacing.sm), count: 8),
                            spacing: CentmondTheme.Spacing.sm
                        ) {
                            ForEach(activeIcons, id: \.self) { opt in
                                Button {
                                    withAnimation(CentmondTheme.Motion.micro) { icon = opt }
                                } label: {
                                    Image(systemName: opt)
                                        .font(.system(size: 14))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 38)
                                        .foregroundStyle(icon == opt ? accentColor : CentmondTheme.Colors.textTertiary)
                                        .background(icon == opt ? accentColor.opacity(0.15) : CentmondTheme.Colors.bgSecondary)
                                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                                                .stroke(icon == opt ? accentColor.opacity(0.6) : CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
                                        )
                                        .scaleEffect(icon == opt ? 1.05 : 1.0)
                                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: icon)
                                }
                                .buttonStyle(.plainHover)
                            }
                        }
                        .animation(CentmondTheme.Motion.layout, value: isExpenseCategory)
                        .padding(CentmondTheme.Spacing.md)
                        .background(CentmondTheme.Colors.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
                        )
                    }
                    .offset(y: appeared ? 0 : 8)
                    .opacity(appeared ? 1 : 0)
                    .animation(CentmondTheme.Motion.default.delay(0.15), value: appeared)

                    // Color picker
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                        Text("Color")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .padding(.leading, CentmondTheme.Spacing.xs)

                        HStack(spacing: CentmondTheme.Spacing.md) {
                            ForEach(activeColors, id: \.self) { hex in
                                Button {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { colorHex = hex }
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: hex))
                                            .frame(width: colorHex == hex ? 32 : 26, height: colorHex == hex ? 32 : 26)

                                        if colorHex == hex {
                                            Circle()
                                                .stroke(Color(hex: hex).opacity(0.4), lineWidth: 3)
                                                .frame(width: 40, height: 40)
                                        }
                                    }
                                    .frame(width: 40, height: 40)
                                    .animation(.spring(response: 0.25, dampingFraction: 0.65), value: colorHex)
                                }
                                .buttonStyle(.plainHover)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, CentmondTheme.Spacing.md)
                        .padding(.vertical, CentmondTheme.Spacing.sm)
                        .background(CentmondTheme.Colors.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
                        )
                        .animation(CentmondTheme.Motion.layout, value: isExpenseCategory)
                    }
                    .offset(y: appeared ? 0 : 8)
                    .opacity(appeared ? 1 : 0)
                    .animation(CentmondTheme.Motion.default.delay(0.2), value: appeared)
                }
                .padding(CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Footer
            HStack(spacing: CentmondTheme.Spacing.sm) {
                // Live preview
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 28, height: 28)
                        .background(accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: icon)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: colorHex)

                    if !name.isEmpty {
                        Text(name)
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .lineLimit(1)
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: name.isEmpty)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())

                Button("Create") {
                    hasAttemptedSave = true
                    if isValid { saveCategory() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!isValid)
                .animation(CentmondTheme.Motion.micro, value: isValid)
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.vertical, CentmondTheme.Spacing.md)
        }
        .frame(height: 560)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { appeared = true }
        }
    }

    // MARK: - Components

    private func typeChip(_ title: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(selected ? .white : CentmondTheme.Colors.textQuaternary)
                .padding(.horizontal, CentmondTheme.Spacing.xl)
                .frame(height: 30)
                .background(selected ? color : CentmondTheme.Colors.bgTertiary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plainHover)
    }

    private func fieldRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            content()
        }
        .frame(height: 42)
        .padding(.horizontal, CentmondTheme.Spacing.md)
    }

    // MARK: - Logic

    private func resetDefaults() {
        let icons = isExpenseCategory ? expenseIcons : incomeIcons
        let colors = isExpenseCategory ? expenseColors : incomeColors
        if !icons.contains(icon) { icon = icons.first ?? icon }
        if !colors.contains(colorHex) { colorHex = colors.first ?? colorHex }
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
