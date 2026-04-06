import SwiftUI
import SwiftData

struct EditRecurringSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    let item: RecurringTransaction

    @State private var name: String
    @State private var amount: String
    @State private var isIncome: Bool
    @State private var frequency: RecurrenceFrequency
    @State private var nextOccurrence: Date
    @State private var autoCreate: Bool
    @State private var selectedAccount: Account?
    @State private var selectedCategory: BudgetCategory?

    init(item: RecurringTransaction) {
        self.item = item
        _name = State(initialValue: item.name)
        _amount = State(initialValue: "\(item.amount)")
        _isIncome = State(initialValue: item.isIncome)
        _frequency = State(initialValue: item.frequency)
        _nextOccurrence = State(initialValue: item.nextOccurrence)
        _autoCreate = State(initialValue: item.autoCreate)
        _selectedAccount = State(initialValue: item.account)
        _selectedCategory = State(initialValue: item.category)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Decimal(string: amount) ?? 0) > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Recurring")
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
                    recEditField("NAME") {
                        TextField("Name", text: $name)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    Picker("Type", selection: $isIncome) {
                        Text("Expense").tag(false)
                        Text("Income").tag(true)
                    }
                    .pickerStyle(.segmented)

                    recEditField("AMOUNT") {
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

                    recEditField("FREQUENCY") {
                        Picker("", selection: $frequency) {
                            ForEach(RecurrenceFrequency.allCases) { freq in
                                Text(freq.displayName).tag(freq)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    recEditField("NEXT OCCURRENCE") {
                        DatePicker("", selection: $nextOccurrence, displayedComponents: .date)
                            .labelsHidden()
                    }

                    if !categories.isEmpty {
                        recEditField("CATEGORY") {
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
                        recEditField("ACCOUNT") {
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
                Button("Save Changes") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isValid)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 520)
    }

    @ViewBuilder
    private func recEditField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
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
        item.name = name.trimmingCharacters(in: .whitespaces)
        if let amt = Decimal(string: amount) { item.amount = amt }
        item.isIncome = isIncome
        item.frequency = frequency
        item.nextOccurrence = nextOccurrence
        item.autoCreate = autoCreate
        item.account = selectedAccount
        item.category = selectedCategory
        dismiss()
    }
}
