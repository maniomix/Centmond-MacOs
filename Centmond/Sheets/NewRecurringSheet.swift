import SwiftUI
import SwiftData

struct NewRecurringSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var name = ""
    @State private var amount = ""
    @State private var isIncome = false
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var nextOccurrence = Date.now
    @State private var autoCreate = false
    @State private var selectedAccount: Account?
    @State private var selectedCategory: BudgetCategory?
    @State private var hasAttemptedSave = false

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Decimal(string: amount) ?? 0) > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Recurring Transaction")
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
                .buttonStyle(.plainHover)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.top, CentmondTheme.Spacing.xl)
            .padding(.bottom, CentmondTheme.Spacing.lg)

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xl) {
                    recField("NAME", showError: hasAttemptedSave && name.trimmingCharacters(in: .whitespaces).isEmpty) {
                        TextField("e.g., Rent Payment", text: $name)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    // Type toggle
                    Picker("Type", selection: $isIncome) {
                        Text("Expense").tag(false)
                        Text("Income").tag(true)
                    }
                    .pickerStyle(.segmented)

                    recField("AMOUNT", showError: hasAttemptedSave && (Decimal(string: amount) ?? 0) <= 0) {
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

                    recField("FREQUENCY") {
                        Picker("", selection: $frequency) {
                            ForEach(RecurrenceFrequency.allCases) { freq in
                                Text(freq.displayName).tag(freq)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    recField("NEXT OCCURRENCE") {
                        DatePicker("", selection: $nextOccurrence, displayedComponents: .date)
                            .labelsHidden()
                    }

                    if !categories.isEmpty {
                        recField("CATEGORY (OPTIONAL)") {
                            Picker("", selection: $selectedCategory) {
                                Text("None").tag(nil as BudgetCategory?)
                                ForEach(categories) { cat in
                                    Label(cat.name, systemImage: cat.icon).tag(cat as BudgetCategory?)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    if !accounts.isEmpty {
                        recField("ACCOUNT (OPTIONAL)") {
                            Picker("", selection: $selectedAccount) {
                                Text("None").tag(nil as Account?)
                                ForEach(accounts.filter { !$0.isArchived }) { acct in
                                    Text(acct.name).tag(acct as Account?)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    Toggle("Auto-create transaction when due", isOn: $autoCreate)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Add Recurring") {
                    hasAttemptedSave = true
                    if isValid { save() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 520)
    }

    @ViewBuilder
    private func recField<Content: View>(_ label: String, showError: Bool = false, @ViewBuilder content: () -> Content) -> some View {
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

    private func save() {
        let item = RecurringTransaction(
            name: name.trimmingCharacters(in: .whitespaces),
            amount: Decimal(string: amount) ?? 0,
            isIncome: isIncome,
            frequency: frequency,
            nextOccurrence: nextOccurrence,
            autoCreate: autoCreate,
            account: selectedAccount,
            category: selectedCategory
        )
        modelContext.insert(item)
        dismiss()
    }
}
