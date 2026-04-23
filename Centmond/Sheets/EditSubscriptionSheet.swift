import SwiftUI
import SwiftData

struct EditSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \HouseholdMember.joinedAt) private var members: [HouseholdMember]
    let subscription: Subscription

    @State private var serviceName: String
    @State private var categoryName: String
    @State private var amount: String
    @State private var billingCycle: BillingCycle
    @State private var nextPaymentDate: Date
    @State private var selectedAccount: Account?
    @State private var selectedMember: HouseholdMember?
    @State private var hasAttemptedSave = false
    @State private var appeared = false
    @State private var showDatePicker = false

    init(subscription: Subscription) {
        self.subscription = subscription
        _serviceName = State(initialValue: subscription.serviceName)
        _categoryName = State(initialValue: subscription.categoryName)
        _amount = State(initialValue: DecimalInput.editableString(subscription.amount))
        _billingCycle = State(initialValue: subscription.billingCycle)
        _nextPaymentDate = State(initialValue: subscription.nextPaymentDate)
        _selectedAccount = State(initialValue: subscription.account)
        _selectedMember = State(initialValue: subscription.householdMember)
    }

    private var isValid: Bool {
        !TextNormalization.isBlank(serviceName) &&
        DecimalInput.parsePositive(amount) != nil
    }

    private var nameError: String? {
        guard hasAttemptedSave else { return nil }
        if TextNormalization.isBlank(serviceName) { return "Service name is required" }
        return nil
    }

    private var amountError: String? {
        guard hasAttemptedSave else { return nil }
        if DecimalInput.parsePositive(amount) == nil { return "Enter an amount" }
        return nil
    }

    private var annualPreview: Decimal {
        let amt = DecimalInput.parsePositive(amount) ?? 0
        switch billingCycle {
        case .weekly: return amt * 52
        case .biweekly: return amt * 26
        case .monthly: return amt * 12
        case .quarterly: return amt * 4
        case .semiannual: return amt * 2
        case .annual: return amt
        case .custom: return amt * 12
        }
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

            // Hero
            VStack(spacing: CentmondTheme.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(CentmondTheme.Colors.accent.opacity(0.15))
                        .frame(width: 64, height: 64)

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                }
                .shadow(color: CentmondTheme.Colors.accent.opacity(0.3), radius: 16, y: 4)

                Text("Edit Subscription")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            .padding(.bottom, CentmondTheme.Spacing.xl)
            .offset(y: appeared ? 0 : 10)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.05), value: appeared)

            // Main fields card
            VStack(spacing: 1) {
                fieldRow {
                    fieldIcon("pencil", error: nameError != nil)
                    TextField("Service name", text: $serviceName)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }

                fieldRow {
                    fieldIcon("dollarsign.circle", error: amountError != nil)
                    Text("$")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    TextField("0.00", text: $amount)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }

                fieldRow {
                    fieldIcon("tag")
                    TextField("Category", text: $categoryName)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }
            }
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .offset(y: appeared ? 0 : 8)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.1), value: appeared)

            // Billing & date card
            VStack(spacing: 1) {
                fieldRow {
                    fieldIcon("repeat")
                    Text("Billing cycle")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    Menu {
                        ForEach(BillingCycle.allCases) { cycle in
                            Button {
                                billingCycle = cycle
                                Haptics.tap()
                            } label: {
                                if cycle == billingCycle {
                                    Label(cycle.displayName, systemImage: "checkmark")
                                } else {
                                    Text(cycle.displayName)
                                }
                            }
                        }
                    } label: {
                        inlineChip(billingCycle.displayName)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                fieldRow {
                    fieldIcon("calendar")
                    Text("Next payment")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    Button {
                        showDatePicker.toggle()
                    } label: {
                        inlineChip(nextPaymentDate.formatted(.dateTime.day().month(.abbreviated).year()))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
                        DatePicker("", selection: $nextPaymentDate, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.graphical)
                            .padding()
                    }
                }

                if !members.isEmpty {
                    fieldRow {
                        fieldIcon("person.2")
                        Text("Member")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Spacer()
                        Menu {
                            Button {
                                selectedMember = nil
                                Haptics.tap()
                            } label: {
                                if selectedMember == nil {
                                    Label("Household", systemImage: "checkmark")
                                } else {
                                    Text("Household")
                                }
                            }
                            ForEach(members.filter(\.isActive)) { m in
                                Button {
                                    selectedMember = m
                                    Haptics.tap()
                                } label: {
                                    if selectedMember?.id == m.id {
                                        Label(m.name, systemImage: "checkmark")
                                    } else {
                                        Text(m.name)
                                    }
                                }
                            }
                        } label: {
                            inlineChip(selectedMember?.name ?? "Household")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                if !accounts.isEmpty {
                    fieldRow {
                        fieldIcon("building.columns")
                        Text("Account")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Spacer()
                        Menu {
                            Button {
                                selectedAccount = nil
                                Haptics.tap()
                            } label: {
                                if selectedAccount == nil {
                                    Label("None", systemImage: "checkmark")
                                } else {
                                    Text("None")
                                }
                            }
                            ForEach(accounts.filter { !$0.isArchived }) { account in
                                Button {
                                    selectedAccount = account
                                    Haptics.tap()
                                } label: {
                                    if selectedAccount?.id == account.id {
                                        Label(account.name, systemImage: "checkmark")
                                    } else {
                                        Text(account.name)
                                    }
                                }
                            }
                        } label: {
                            inlineChip(selectedAccount?.name ?? "None")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.top, CentmondTheme.Spacing.sm)
            .offset(y: appeared ? 0 : 6)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.12), value: appeared)

            // Annual cost preview
            if DecimalInput.parsePositive(amount) != nil {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "info.circle")
                        .font(CentmondTheme.Typography.captionSmall)
                        .foregroundStyle(CentmondTheme.Colors.info)

                    Text("Annual cost: \(CurrencyFormat.standard(annualPreview))")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
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

            // Save button
            Button {
                hasAttemptedSave = true
                if isValid { save() }
            } label: {
                Text("Save Changes")
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
        }
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

    private func inlineChip(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.accent)
            Image(systemName: "chevron.up.chevron.down")
                .font(CentmondTheme.Typography.microBold.weight(.semibold))
                .foregroundStyle(CentmondTheme.Colors.accent.opacity(0.6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(CentmondTheme.Colors.accent.opacity(0.1))
        .clipShape(Capsule())
    }


    // MARK: - Save

    private func save() {
        Haptics.impact()
        guard let amt = DecimalInput.parsePositive(amount) else { return }
        subscription.serviceName = TextNormalization.trimmed(serviceName)
        subscription.categoryName = TextNormalization.trimmed(categoryName)
        subscription.amount = amt
        subscription.billingCycle = billingCycle
        subscription.nextPaymentDate = nextPaymentDate
        subscription.account = selectedAccount
        subscription.householdMember = selectedMember
        subscription.updatedAt = .now
        dismiss()
    }
}
