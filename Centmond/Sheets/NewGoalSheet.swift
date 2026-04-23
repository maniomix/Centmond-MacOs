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
    @State private var appeared = false

    private let iconOptions = [
        "target", "house.fill", "car.fill", "airplane",
        "graduationcap.fill", "heart.fill", "gift.fill", "banknote.fill"
    ]

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

    // Progress preview
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
                        .font(CentmondTheme.Typography.captionSmallSemibold)
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

                Text("New Goal")
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
                                .font(CentmondTheme.Typography.bodyLarge)
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
                    Spacer()
                    Text("optional")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
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
                    Spacer()
                    Text("optional")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
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

            // Progress preview
            if let pct = progressPercent {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: icon)
                        .font(CentmondTheme.Typography.captionSmall)
                        .foregroundStyle(CentmondTheme.Colors.accent)

                    Text("Starting at \(Int(pct * 100))%")
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
                        .font(CentmondTheme.Typography.overlineRegular)
                    Text(error)
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.negative)
                .padding(.top, CentmondTheme.Spacing.sm)
            }

            Spacer(minLength: CentmondTheme.Spacing.lg)

            // Create button
            Button {
                hasAttemptedSave = true
                if isValid { saveGoal() }
            } label: {
                Text("Create Goal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
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
            applyOnboardingPresetIfAny()
        }
    }

    /// Ephemeral handoff from the onboarding flow. Step 4 writes
    /// `onboarding.goalPreset.name` / `onboarding.goalPreset.icon` into
    /// UserDefaults before routing to this sheet; we consume-and-clear on
    /// appear so the prefill doesn't leak into a later manual "New Goal".
    private func applyOnboardingPresetIfAny() {
        let defaults = UserDefaults.standard
        if let presetName = defaults.string(forKey: "onboarding.goalPreset.name"),
           !presetName.isEmpty {
            name = presetName
        }
        if let presetIcon = defaults.string(forKey: "onboarding.goalPreset.icon"),
           iconOptions.contains(presetIcon) {
            icon = presetIcon
        }
        defaults.removeObject(forKey: "onboarding.goalPreset.name")
        defaults.removeObject(forKey: "onboarding.goalPreset.icon")
    }

    // MARK: - Components

    private func fieldIcon(_ name: String, error: Bool = false) -> some View {
        Image(systemName: name)
            .font(CentmondTheme.Typography.caption)
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

    private func saveGoal() {
        Haptics.impact()
        guard let target = DecimalInput.parsePositive(targetAmount) else { return }
        let current = DecimalInput.parseNonNegative(currentAmount) ?? 0
        let monthly = DecimalInput.parsePositive(monthlyContribution)
        let trimmedName = TextNormalization.trimmed(name)

        let goal = Goal(
            name: trimmedName,
            icon: icon,
            targetAmount: target,
            currentAmount: 0,
            targetDate: hasTargetDate ? targetDate : nil,
            monthlyContribution: monthly,
            status: .active
        )
        modelContext.insert(goal)

        // Capture the starting balance as a seed contribution so history is
        // authoritative from day one. Service also auto-completes the goal if
        // the seed already hits the target.
        if current > 0 {
            GoalContributionService.addContribution(
                to: goal,
                amount: current,
                kind: .manual,
                note: "Starting balance",
                context: modelContext
            )
        }
        dismiss()
    }
}
