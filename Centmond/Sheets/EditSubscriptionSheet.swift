import SwiftUI
import SwiftData

struct EditSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    let subscription: Subscription

    @State private var serviceName: String
    @State private var categoryName: String
    @State private var amount: String
    @State private var billingCycle: BillingCycle
    @State private var nextPaymentDate: Date
    @State private var selectedAccount: Account?

    init(subscription: Subscription) {
        self.subscription = subscription
        _serviceName = State(initialValue: subscription.serviceName)
        _categoryName = State(initialValue: subscription.categoryName)
        _amount = State(initialValue: "\(subscription.amount)")
        _billingCycle = State(initialValue: subscription.billingCycle)
        _nextPaymentDate = State(initialValue: subscription.nextPaymentDate)
        _selectedAccount = State(initialValue: subscription.account)
    }

    private var isValid: Bool {
        !serviceName.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Decimal(string: amount) ?? 0) > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Subscription")
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
                    subEditField("SERVICE NAME") {
                        TextField("Service name", text: $serviceName)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    subEditField("AMOUNT") {
                        HStack {
                            Text("$")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            TextField("0.00", text: $amount)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }

                    subEditField("BILLING CYCLE") {
                        Picker("", selection: $billingCycle) {
                            ForEach(BillingCycle.allCases) { cycle in
                                Text(cycle.displayName).tag(cycle)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    subEditField("NEXT PAYMENT DATE") {
                        DatePicker("", selection: $nextPaymentDate, displayedComponents: .date)
                            .labelsHidden()
                    }

                    subEditField("CATEGORY") {
                        TextField("e.g., Entertainment", text: $categoryName)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    if !accounts.isEmpty {
                        subEditField("PAYMENT ACCOUNT") {
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
                Button("Save Changes") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isValid)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 480)
    }

    @ViewBuilder
    private func subEditField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
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
        subscription.serviceName = serviceName.trimmingCharacters(in: .whitespaces)
        subscription.categoryName = categoryName.trimmingCharacters(in: .whitespaces)
        if let amt = Decimal(string: amount) { subscription.amount = amt }
        subscription.billingCycle = billingCycle
        subscription.nextPaymentDate = nextPaymentDate
        subscription.account = selectedAccount
        dismiss()
    }
}
