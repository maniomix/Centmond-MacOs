import SwiftUI
import SwiftData

struct NewTransactionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var amount = ""
    @State private var payee = ""
    @State private var selectedCategory: BudgetCategory?
    @State private var selectedAccount: Account?
    @State private var date = Date.now
    @State private var notes = ""
    @State private var isIncome = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Transaction")
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

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xl) {
                    // Amount
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                        Text("AMOUNT")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.3)

                        HStack {
                            Text("$")
                                .font(CentmondTheme.Typography.monoLarge)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)

                            TextField("0.00", text: $amount)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.monoLarge)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, CentmondTheme.Spacing.md)
                        .frame(height: 48)
                        .background(CentmondTheme.Colors.bgInput)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                                .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                        )
                    }

                    // Type toggle
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        Text("Type:")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)

                        Picker("", selection: $isIncome) {
                            Text("Expense").tag(false)
                            Text("Income").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }

                    // Payee
                    formField("PAYEE") {
                        TextField("e.g., Whole Foods", text: $payee)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    // Category
                    formField("CATEGORY") {
                        Picker("Select category", selection: $selectedCategory) {
                            Text("Uncategorized").tag(nil as BudgetCategory?)
                            ForEach(categories) { category in
                                Label(category.name, systemImage: category.icon)
                                    .tag(category as BudgetCategory?)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Account
                    formField("ACCOUNT") {
                        Picker("Select account", selection: $selectedAccount) {
                            Text("No account").tag(nil as Account?)
                            ForEach(accounts) { account in
                                Text(account.name).tag(account as Account?)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Date
                    formField("DATE") {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.field)
                            .labelsHidden()
                    }

                    // Notes
                    formField("NOTES") {
                        TextField("Optional notes...", text: $notes)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Footer
            HStack {
                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())

                Button("Save Transaction") { saveTransaction() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(amount.isEmpty || payee.isEmpty)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 500)
    }

    @ViewBuilder
    private func formField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
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

    private func saveTransaction() {
        guard let amountDecimal = Decimal(string: amount) else { return }

        let transaction = Transaction(
            date: date,
            payee: payee,
            amount: amountDecimal,
            notes: notes.isEmpty ? nil : notes,
            isIncome: isIncome,
            account: selectedAccount,
            category: selectedCategory
        )
        modelContext.insert(transaction)
        dismiss()
    }
}
