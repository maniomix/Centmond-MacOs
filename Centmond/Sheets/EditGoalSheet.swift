import SwiftUI
import SwiftData

struct EditGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HouseholdMember.joinedAt) private var members: [HouseholdMember]
    let goal: Goal

    @State private var name: String
    @State private var icon: String
    @State private var targetAmount: String
    @State private var currentAmount: String
    @State private var monthlyContribution: String
    @State private var hasTargetDate: Bool
    @State private var targetDate: Date
    @State private var selectedMember: HouseholdMember?
    @State private var hasAttemptedSave = false
    @State private var appeared = false

    private let iconOptions = [
        "target", "house.fill", "car.fill", "airplane",
        "graduationcap.fill", "heart.fill", "gift.fill", "banknote.fill"
    ]

    init(goal: Goal) {
        self.goal = goal
        _name = State(initialValue: goal.name)
        _icon = State(initialValue: goal.icon)
        _targetAmount = State(initialValue: DecimalInput.editableString(goal.targetAmount))
        _currentAmount = State(initialValue: DecimalInput.editableString(goal.currentAmount))
        _monthlyContribution = State(initialValue: DecimalInput.editableString(goal.monthlyContribution))
        _hasTargetDate = State(initialValue: goal.targetDate != nil)
        _targetDate = State(initialValue: goal.targetDate ?? Calendar.current.date(byAdding: .year, value: 1, to: .now)!)
        _selectedMember = State(initialValue: goal.householdMember)
    }

    private var isValid: Bool {
        !TextNormalization.isBlank(name) &&
        DecimalInput.parsePositive(targetAmount) != nil
    }

    private var nameError: String? {
        guard hasAttemptedSave else { return nil }
        if TextNormalization.isBlank(name) { return "Goal name is required" }
        return nil
    }

    private var amountError: String? {
        guard hasAttemptedSave else { return nil }
        if DecimalInput.parsePositive(targetAmount) == nil { return "Enter a target amount" }
        return nil
    }

    private var progressPercent: Double? {
        guard let target = DecimalInput.parsePositive(targetAmount) else { return nil }
        let current = DecimalInput.parseNonNegative(currentAmount) ?? 0
        return min(Double(truncating: (current / target) as NSDecimalNumber), 1.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(width: 22, height: 22)
                        .background(CentmondTheme.Colors.bgQuaternary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plainHover)
            }
            .padding(.trailing, CentmondTheme.Spacing.lg)
            .padding(.top, CentmondTheme.Spacing.md)

            // Hero: Big icon + icon picker
            VStack(spacing: CentmondTheme.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(CentmondTheme.Colors.accent.opacity(0.15))
                        .frame(width: 64, height: 64)

                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .contentTransition(.symbolEffect(.replace))
                }
                .shadow(color: CentmondTheme.Colors.accent.opacity(0.3), radius: 16, y: 4)

                Text("Edit Goal")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                // Icon picker
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    ForEach(iconOptions, id: \.self) { opt in
                        Button {
                            Haptics.tick()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                icon = opt
                            }
                        } label: {
                            Image(systemName: opt)
                                .font(.system(size: 14))
                                .frame(width: 32, height: 32)
                                .foregroundStyle(icon == opt ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                                .background(icon == opt ? CentmondTheme.Colors.accent.opacity(0.12) : CentmondTheme.Colors.bgQuaternary)
                                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                        }
                        .buttonStyle(.plainHover)
                    }
                }
            }
            .padding(.bottom, CentmondTheme.Spacing.xl)
            .offset(y: appeared ? 0 : 10)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.05), value: appeared)

            // Fields card
            VStack(spacing: 1) {
                fieldRow {
                    fieldIcon("pencil", error: nameError != nil)
                    TextField("Goal name", text: $name)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }

                fieldRow {
                    fieldIcon("flag.fill", error: amountError != nil)
                    Text("$")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    TextField("Target amount", text: $targetAmount)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }

                fieldRow {
                    fieldIcon("banknote")
                    Text("$")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    TextField("Saved so far", text: $currentAmount)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }

                fieldRow {
                    fieldIcon("arrow.up.right")
                    Text("$")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    TextField("Monthly contribution", text: $monthlyContribution)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }
            }
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .offset(y: appeared ? 0 : 8)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.1), value: appeared)

            // Target date card
            VStack(spacing: 1) {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    fieldIcon("calendar")
                    Text("Target date")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    Toggle("", isOn: $hasTargetDate)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .onChange(of: hasTargetDate) { _, _ in
                            Haptics.tap()
                        }
                }
                .frame(height: 38)
                .padding(.horizontal, CentmondTheme.Spacing.md)

                if hasTargetDate {
                    Divider().background(CentmondTheme.Colors.strokeSubtle)
                        .padding(.horizontal, CentmondTheme.Spacing.md)

                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        fieldIcon("calendar.badge.clock")
                        DatePicker("", selection: $targetDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                    .frame(height: 38)
                    .padding(.horizontal, CentmondTheme.Spacing.md)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.top, CentmondTheme.Spacing.sm)
            .offset(y: appeared ? 0 : 6)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.12), value: appeared)

            // Owner (P4 — private vs shared goal; hidden when no members)
            if !members.isEmpty {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Text("Owner")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Spacer()
                    Picker("", selection: $selectedMember) {
                        Text("Shared / household").tag(nil as HouseholdMember?)
                        ForEach(members.filter(\.isActive)) { m in
                            Text(m.name).tag(m as HouseholdMember?)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.top, CentmondTheme.Spacing.md)
            }

            // Progress preview
            if let pct = progressPercent {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.accent)

                    Text("Progress: \(Int(pct * 100))%")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(CentmondTheme.Colors.bgQuaternary)

                            Capsule()
                                .fill(CentmondTheme.Colors.accent)
                                .frame(width: max(geo.size.width * pct, 4))
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.top, CentmondTheme.Spacing.md)
                .transition(.opacity)
            }

            // Errors
            if hasAttemptedSave, let error = nameError ?? amountError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text(error)
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.negative)
                .padding(.top, CentmondTheme.Spacing.sm)
            }

            Spacer(minLength: CentmondTheme.Spacing.lg)

            // Save button
            Button {
                hasAttemptedSave = true
                if isValid { save() }
            } label: {
                Text("Save Changes")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!isValid && hasAttemptedSave)
            .opacity(isValid || !hasAttemptedSave ? 1 : 0.4)
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.bottom, CentmondTheme.Spacing.lg)
            .offset(y: appeared ? 0 : 8)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.15), value: appeared)
        }
        .background(CentmondTheme.Colors.bgPrimary)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                appeared = true
            }
        }
    }

    // MARK: - Components

    private func fieldIcon(_ name: String, error: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 12))
            .foregroundStyle(error ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textQuaternary)
            .frame(width: 18)
    }

    private func fieldRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            content()
        }
        .frame(height: 38)
        .padding(.horizontal, CentmondTheme.Spacing.md)
    }

    // MARK: - Save

    private func save() {
        Haptics.impact()
        guard let target = DecimalInput.parsePositive(targetAmount) else { return }

        goal.name = TextNormalization.trimmed(name)
        goal.icon = icon
        goal.targetAmount = target
        goal.monthlyContribution = DecimalInput.parsePositive(monthlyContribution)
        goal.targetDate = hasTargetDate ? targetDate : nil

        // "Saved so far" is a derived value now. Edits to it are expressed as
        // a signed adjustment contribution so history stays authoritative.
        let desired = DecimalInput.parseNonNegative(currentAmount) ?? 0
        let delta = desired - goal.currentAmount
        if delta != 0 {
            GoalContributionService.addContribution(
                to: goal,
                amount: delta,
                kind: .manual,
                note: delta > 0 ? "Manual adjustment" : "Manual correction",
                context: modelContext
            )
        } else {
            goal.updatedAt = .now
        }

        goal.householdMember = selectedMember

        // Target may have moved even when the saved amount didn't — re-sync status.
        if goal.status == .active, goal.currentAmount >= goal.targetAmount {
            goal.status = .completed
        } else if goal.status == .completed, goal.currentAmount < goal.targetAmount {
            goal.status = .active
        }
        dismiss()
    }
}
