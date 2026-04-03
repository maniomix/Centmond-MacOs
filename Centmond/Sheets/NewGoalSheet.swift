import SwiftUI
import SwiftData

struct NewGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var targetAmount = ""
    @State private var currentAmount = ""
    @State private var monthlyContribution = ""
    @State private var hasTargetDate = false
    @State private var targetDate = Calendar.current.date(byAdding: .year, value: 1, to: .now)!
    @State private var icon = "target"
    @State private var hasAttemptedSave = false

    private let iconOptions = ["target", "house.fill", "car.fill", "airplane", "graduationcap.fill", "heart.fill", "gift.fill", "banknote.fill"]

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Decimal(string: targetAmount) ?? 0) > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Goal")
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
                    goalFormField("GOAL NAME", showError: hasAttemptedSave && name.trimmingCharacters(in: .whitespaces).isEmpty, errorText: "Goal name is required") {
                        TextField("e.g., Emergency Fund", text: $name)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                        Text("ICON")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.3)

                        HStack(spacing: CentmondTheme.Spacing.sm) {
                            ForEach(iconOptions, id: \.self) { opt in
                                Button {
                                    icon = opt
                                } label: {
                                    Image(systemName: opt)
                                        .font(.system(size: 14))
                                        .frame(width: 32, height: 32)
                                        .foregroundStyle(icon == opt ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                                        .background(icon == opt ? CentmondTheme.Colors.accent.opacity(0.12) : CentmondTheme.Colors.bgQuaternary)
                                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    goalFormField("TARGET AMOUNT", showError: hasAttemptedSave && (Decimal(string: targetAmount) ?? 0) <= 0, errorText: "Enter a target amount greater than zero") {
                        HStack {
                            Text("$")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            TextField("10,000", text: $targetAmount)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }

                    goalFormField("SAVED SO FAR (OPTIONAL)") {
                        HStack {
                            Text("$")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            TextField("0", text: $currentAmount)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }

                    goalFormField("MONTHLY CONTRIBUTION (OPTIONAL)") {
                        HStack {
                            Text("$")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            TextField("500", text: $monthlyContribution)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }

                    Toggle("Set a target date", isOn: $hasTargetDate)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)

                    if hasTargetDate {
                        goalFormField("TARGET DATE") {
                            DatePicker("", selection: $targetDate, displayedComponents: .date)
                                .labelsHidden()
                        }
                    }

                    // Progress preview
                    if let target = Decimal(string: targetAmount), target > 0 {
                        let current = Decimal(string: currentAmount) ?? 0
                        let pct = min(Double(truncating: (current / target) as NSDecimalNumber), 1.0)
                        HStack(spacing: CentmondTheme.Spacing.sm) {
                            Image(systemName: icon)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                            Text("Starting at \(Int(pct * 100))%")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Create Goal") {
                    hasAttemptedSave = true
                    if isValid { saveGoal() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 500)
    }

    @ViewBuilder
    private func goalFormField<Content: View>(_ label: String, showError: Bool = false, errorText: String? = nil, @ViewBuilder content: () -> Content) -> some View {
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

            if showError, let errorText {
                Text(errorText)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }
        }
    }

    private func saveGoal() {
        let target = Decimal(string: targetAmount) ?? 0
        let current = Decimal(string: currentAmount) ?? 0
        let monthly = Decimal(string: monthlyContribution)

        let goal = Goal(
            name: name.trimmingCharacters(in: .whitespaces),
            icon: icon,
            targetAmount: target,
            currentAmount: current,
            targetDate: hasTargetDate ? targetDate : nil,
            monthlyContribution: monthly
        )
        modelContext.insert(goal)
        dismiss()
    }
}
