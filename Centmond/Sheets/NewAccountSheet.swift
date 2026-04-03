import SwiftUI
import SwiftData

struct NewAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var type: AccountType = .checking
    @State private var institutionName = ""
    @State private var lastFourDigits = ""
    @State private var balance = ""
    @State private var currency = "USD"
    @State private var hasAttemptedSave = false

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Account")
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
                    formField("ACCOUNT NAME", isRequired: true, showError: hasAttemptedSave && name.trimmingCharacters(in: .whitespaces).isEmpty) {
                        TextField("e.g., Chase Checking", text: $name)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    formField("TYPE") {
                        Picker("", selection: $type) {
                            ForEach(AccountType.allCases) { accountType in
                                Label(accountType.displayName, systemImage: accountType.iconName)
                                    .tag(accountType)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    formField("INSTITUTION (OPTIONAL)") {
                        TextField("e.g., Chase Bank", text: $institutionName)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    formField("LAST 4 DIGITS (OPTIONAL)") {
                        TextField("e.g., 4521", text: $lastFourDigits)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .onChange(of: lastFourDigits) { _, newValue in
                                let filtered = newValue.filter(\.isNumber)
                                if filtered.count > 4 {
                                    lastFourDigits = String(filtered.prefix(4))
                                } else if filtered != newValue {
                                    lastFourDigits = filtered
                                }
                            }
                    }

                    formField("CURRENT BALANCE") {
                        HStack {
                            Text("$")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)

                            TextField("0.00", text: $balance)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }

                    if type == .creditCard {
                        HStack(spacing: CentmondTheme.Spacing.sm) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(CentmondTheme.Colors.info)
                            Text("Enter a positive balance for amount owed.")
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

                Button("Create Account") {
                    hasAttemptedSave = true
                    if isValid { saveAccount() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!isValid && hasAttemptedSave)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 450)
    }

    @ViewBuilder
    private func formField<Content: View>(_ label: String, isRequired: Bool = false, showError: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            HStack(spacing: 2) {
                Text(label)
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(showError ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textTertiary)
                    .tracking(0.3)
                if isRequired {
                    Text("*")
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                }
            }

            content()
                .padding(.horizontal, CentmondTheme.Spacing.sm)
                .frame(height: CentmondTheme.Sizing.inputHeight)
                .background(CentmondTheme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                        .stroke(showError ? CentmondTheme.Colors.negative : CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                )

            if showError {
                Text("Account name is required")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }
        }
    }

    private func saveAccount() {
        let balanceDecimal = Decimal(string: balance) ?? 0
        let account = Account(
            name: name.trimmingCharacters(in: .whitespaces),
            type: type,
            institutionName: institutionName.isEmpty ? nil : institutionName.trimmingCharacters(in: .whitespaces),
            lastFourDigits: lastFourDigits.isEmpty ? nil : lastFourDigits,
            currentBalance: balanceDecimal,
            currency: currency
        )
        modelContext.insert(account)
        dismiss()
    }
}
