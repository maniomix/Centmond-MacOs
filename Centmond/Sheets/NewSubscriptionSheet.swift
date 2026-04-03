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

    private var isValid: Bool {
        !serviceName.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Decimal(string: amount) ?? 0) > 0
    }

    private var annualPreview: Decimal {
        let amt = Decimal(string: amount) ?? 0
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
            HStack {
                Text("New Subscription")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Spacer()
                Button { dismiss() } label: {
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
                    subField("SERVICE NAME", showError: hasAttemptedSave && serviceName.trimmingCharacters(in: .whitespaces).isEmpty) {
                        TextField("e.g., Netflix", text: $serviceName)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    subField("AMOUNT", showError: hasAttemptedSave && (Decimal(string: amount) ?? 0) <= 0) {
                        HStack {
                            Text("$")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            TextField("15.99", text: $amount)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }

                    subField("BILLING CYCLE") {
                        Picker("", selection: $billingCycle) {
                            ForEach(BillingCycle.allCases) { cycle in
                                Text(cycle.displayName).tag(cycle)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Annual cost preview
                    if (Decimal(string: amount) ?? 0) > 0 {
                        HStack(spacing: CentmondTheme.Spacing.sm) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(CentmondTheme.Colors.info)
                            Text("Annual cost: \(CurrencyFormat.standard(annualPreview))")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }

                    subField("NEXT PAYMENT DATE") {
                        DatePicker("", selection: $nextPaymentDate, displayedComponents: .date)
                            .labelsHidden()
                    }

                    subField("CATEGORY") {
                        TextField("e.g., Entertainment", text: $categoryName)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    if !accounts.isEmpty {
                        subField("PAYMENT ACCOUNT (OPTIONAL)") {
                            Picker("", selection: $selectedAccount) {
                                Text("None").tag(nil as Account?)
                                ForEach(accounts.filter { !$0.isArchived }) { account in
                                    Text(account.name).tag(account as Account?)
                                }
                            }
                            .pickerStyle(.menu)
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
                Button("Add Subscription") {
                    hasAttemptedSave = true
                    if isValid { saveSubscription() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 480)
    }

    @ViewBuilder
    private func subField<Content: View>(_ label: String, showError: Bool = false, @ViewBuilder content: () -> Content) -> some View {
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

    private func saveSubscription() {
        let amountDecimal = Decimal(string: amount) ?? 0
        let subscription = Subscription(
            serviceName: serviceName.trimmingCharacters(in: .whitespaces),
            categoryName: categoryName.trimmingCharacters(in: .whitespaces),
            amount: amountDecimal,
            billingCycle: billingCycle,
            nextPaymentDate: nextPaymentDate,
            account: selectedAccount
        )
        modelContext.insert(subscription)
        dismiss()
    }
}
