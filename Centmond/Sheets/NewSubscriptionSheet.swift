import SwiftUI
import SwiftData

struct NewSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var serviceName = ""
    @State private var categoryName = "Subscriptions"
    @State private var amount = ""
    @State private var billingCycle: BillingCycle = .monthly
    @State private var nextPaymentDate = Date.now
    @State private var selectedAccount: Account?
    @State private var hasAttemptedSave = false
    @State private var appeared = false
    @State private var showDatePicker = false

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
        }
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

                Text("New Subscription")
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
                    TextField("Service name (e.g., Netflix)", text: $serviceName)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }

                fieldRow {
                    fieldIcon("dollarsign.circle", error: amountError != nil)
                    Text("$")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    TextField("15.99", text: $amount)
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
                        .font(.system(size: 11))
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
                        .font(.system(size: 10))
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
                if isValid { saveSubscription() }
            } label: {
                Text("Add Subscription")
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

    private func inlineChip(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.accent)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(CentmondTheme.Colors.accent.opacity(0.6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(CentmondTheme.Colors.accent.opacity(0.1))
        .clipShape(Capsule())
    }


    // MARK: - Save

    private func saveSubscription() {
        Haptics.impact()
        guard let amountDecimal = DecimalInput.parsePositive(amount) else { return }
        let subscription = Subscription(
            serviceName: TextNormalization.trimmed(serviceName),
            categoryName: TextNormalization.trimmed(categoryName),
            amount: amountDecimal,
            billingCycle: billingCycle,
            nextPaymentDate: nextPaymentDate,
            account: selectedAccount
        )
        modelContext.insert(subscription)
        dismiss()
    }
}
