import SwiftUI
import SwiftData

struct EditGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goal: Goal

    @State private var name: String
    @State private var icon: String
    @State private var targetAmount: String
    @State private var currentAmount: String
    @State private var monthlyContribution: String
    @State private var hasTargetDate: Bool
    @State private var targetDate: Date

    private let iconOptions = ["target", "house.fill", "car.fill", "airplane", "graduationcap.fill", "heart.fill", "gift.fill", "banknote.fill"]

    init(goal: Goal) {
        self.goal = goal
        _name = State(initialValue: goal.name)
        _icon = State(initialValue: goal.icon)
        _targetAmount = State(initialValue: "\(goal.targetAmount)")
        _currentAmount = State(initialValue: "\(goal.currentAmount)")
        _monthlyContribution = State(initialValue: goal.monthlyContribution != nil ? "\(goal.monthlyContribution!)" : "")
        _hasTargetDate = State(initialValue: goal.targetDate != nil)
        _targetDate = State(initialValue: goal.targetDate ?? Calendar.current.date(byAdding: .year, value: 1, to: .now)!)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Decimal(string: targetAmount) ?? 0) > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Goal")
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
                .buttonStyle(.plainHover)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.top, CentmondTheme.Spacing.xl)
            .padding(.bottom, CentmondTheme.Spacing.lg)

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xl) {
                    goalEditField("GOAL NAME") {
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
                                .buttonStyle(.plainHover)
                            }
                        }
                    }

                    goalEditField("TARGET AMOUNT") {
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

                    goalEditField("SAVED SO FAR") {
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

                    goalEditField("MONTHLY CONTRIBUTION") {
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
                        goalEditField("TARGET DATE") {
                            DatePicker("", selection: $targetDate, displayedComponents: .date)
                                .labelsHidden()
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
                Button("Save Changes") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isValid)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 500)
    }

    @ViewBuilder
    private func goalEditField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text(label)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.3)
            content()
                .padding(.horizontal, CentmondTheme.Spacing.sm)
                .frame(height: CentmondTheme.Sizing.inputHeight)
                .background(CentmondTheme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                        .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                )
        }
    }

    private func save() {
        goal.name = name.trimmingCharacters(in: .whitespaces)
        goal.icon = icon
        if let target = Decimal(string: targetAmount) {
            goal.targetAmount = target
        }
        if let current = Decimal(string: currentAmount) {
            goal.currentAmount = current
        }
        goal.monthlyContribution = Decimal(string: monthlyContribution)
        goal.targetDate = hasTargetDate ? targetDate : nil

        // Auto-complete if current meets target
        if goal.currentAmount >= goal.targetAmount && goal.status == .active {
            goal.status = .completed
        }

        dismiss()
    }
}
