import SwiftUI
import SwiftData

struct EditAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: Account

    @State private var name: String
    @State private var type: AccountType
    @State private var institutionName: String
    @State private var lastFourDigits: String
    @State private var balance: String
    @State private var currency: String

    init(account: Account) {
        self.account = account
        _name = State(initialValue: account.name)
        _type = State(initialValue: account.type)
        _institutionName = State(initialValue: account.institutionName ?? "")
        _lastFourDigits = State(initialValue: account.lastFourDigits ?? "")
        _balance = State(initialValue: "\(account.currentBalance)")
        _currency = State(initialValue: account.currency)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Account")
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
                    editField("ACCOUNT NAME") {
                        TextField("Account name", text: $name)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    editField("TYPE") {
                        Picker("", selection: $type) {
                            ForEach(AccountType.allCases) { t in
                                Label(t.displayName, systemImage: t.iconName).tag(t)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    editField("INSTITUTION") {
                        TextField("e.g., Chase Bank", text: $institutionName)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    editField("LAST 4 DIGITS") {
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

                    editField("CURRENT BALANCE") {
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
        .frame(minHeight: 450)
    }

    @ViewBuilder
    private func editField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
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
        account.name = name.trimmingCharacters(in: .whitespaces)
        account.type = type
        account.institutionName = institutionName.isEmpty ? nil : institutionName.trimmingCharacters(in: .whitespaces)
        account.lastFourDigits = lastFourDigits.isEmpty ? nil : lastFourDigits
        if let bal = Decimal(string: balance) {
            account.currentBalance = bal
        }
        account.currency = currency
        dismiss()
    }
}
