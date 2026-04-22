import SwiftUI
import SwiftData

struct EditAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.sortOrder) private var existingAccounts: [Account]
    @Query(sort: \HouseholdMember.joinedAt) private var members: [HouseholdMember]

    let account: Account

    // Core fields
    @State private var name: String
    @State private var type: AccountType
    @State private var institutionName: String
    @State private var lastFourDigits: String
    @State private var balance: String
    @State private var currency: SupportedCurrency
    @State private var selectedColor: String

    // Extended fields
    @State private var notes: String
    @State private var includeInNetWorth: Bool
    @State private var includeInBudgeting: Bool

    // Credit card fields
    @State private var creditLimit: String

    // Liability payoff fields (P6)
    @State private var interestRate: String
    @State private var minimumPayment: String
    @State private var selectedOwner: HouseholdMember?

    // Validation & animation
    @State private var hasAttemptedSave = false
    @State private var appeared = false

    private var accentColor: Color { Color(hex: selectedColor) }

    init(account: Account) {
        self.account = account
        _name = State(initialValue: account.name)
        _type = State(initialValue: account.type)
        _institutionName = State(initialValue: account.institutionName ?? "")
        _lastFourDigits = State(initialValue: account.lastFourDigits ?? "")
        _balance = State(initialValue: account.currentBalance == 0 ? "" : "\(account.currentBalance)")
        _currency = State(initialValue: SupportedCurrency(rawValue: account.currency) ?? .usd)
        _selectedColor = State(initialValue: account.colorHex ?? AccountColorPreset.blue.rawValue)
        _notes = State(initialValue: account.notes ?? "")
        _includeInNetWorth = State(initialValue: account.includeInNetWorth)
        _includeInBudgeting = State(initialValue: account.includeInBudgeting)
        _creditLimit = State(initialValue: account.creditLimit.map { "\($0)" } ?? "")
        _interestRate = State(initialValue: account.interestRatePercent.map { String(format: "%g", $0) } ?? "")
        _minimumPayment = State(initialValue: account.minimumPaymentMonthly.map { "\($0)" } ?? "")
        _selectedOwner = State(initialValue: account.ownerMember)
    }

    // MARK: - Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameError: String? {
        guard hasAttemptedSave else { return nil }
        if trimmedName.isEmpty { return "Account name is required" }
        if existingAccounts.contains(where: {
            $0.id != account.id && $0.name.lowercased() == trimmedName.lowercased()
        }) {
            return "An account with this name already exists"
        }
        return nil
    }

    private var balanceError: String? {
        guard hasAttemptedSave, !balance.isEmpty else { return nil }
        if Decimal(string: balance) == nil { return "Enter a valid number" }
        return nil
    }

    private var creditLimitError: String? {
        guard hasAttemptedSave, !creditLimit.isEmpty else { return nil }
        if Decimal(string: creditLimit) == nil { return "Enter a valid number" }
        return nil
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
        && !existingAccounts.contains(where: { $0.id != account.id && $0.name.lowercased() == trimmedName.lowercased() })
        && (balance.isEmpty || Decimal(string: balance) != nil)
        && (creditLimit.isEmpty || Decimal(string: creditLimit) != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Close
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
                        .fill(accentColor.opacity(0.15))
                        .frame(width: 64, height: 64)

                    Image(systemName: type.iconName)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(accentColor)
                        .contentTransition(.symbolEffect(.replace))
                }
                .shadow(color: accentColor.opacity(0.3), radius: 16, y: 4)

                Picker("", selection: $type) {
                    ForEach(AccountType.allCases) { accountType in
                        Label(accountType.displayName, systemImage: accountType.iconName)
                            .tag(accountType)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                HStack(spacing: 8) {
                    ForEach(AccountColorPreset.allCases, id: \.rawValue) { preset in
                        Circle()
                            .fill(Color(hex: preset.rawValue))
                            .frame(width: selectedColor == preset.rawValue ? 22 : 16,
                                   height: selectedColor == preset.rawValue ? 22 : 16)
                            .overlay {
                                if selectedColor == preset.rawValue {
                                    Circle()
                                        .strokeBorder(.white, lineWidth: 2)
                                }
                            }
                            .onTapGesture {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    selectedColor = preset.rawValue
                                }
                            }
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
                    TextField("Account name", text: $name)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }

                fieldRow {
                    fieldIcon("building.columns")
                    TextField("Institution (optional)", text: $institutionName)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }

                fieldRow {
                    fieldIcon("number")
                    TextField("Last 4 digits", text: $lastFourDigits)
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
                    Spacer()
                    fieldIcon("dollarsign.circle")
                    Picker("", selection: $currency) {
                        ForEach(SupportedCurrency.allCases) { cur in
                            Text("\(cur.symbol) \(cur.rawValue)").tag(cur)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                fieldRow {
                    fieldIcon("banknote", error: balanceError != nil)
                    Text(currency.symbol)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    TextField("Current balance", text: $balance)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }

                fieldRow {
                    fieldIcon("note.text")
                    TextField("Note (optional)", text: $notes)
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

            // Credit card extras
            if type == .creditCard {
                VStack(spacing: 1) {
                    fieldRow {
                        fieldIcon("creditcard")
                        Text(currency.symbol)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        TextField("Credit limit", text: $creditLimit)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .monospacedDigit()
                    }
                    fieldRow {
                        fieldIcon("percent")
                        TextField("APR (e.g. 19.99)", text: $interestRate)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .monospacedDigit()
                    }
                    fieldRow {
                        fieldIcon("calendar.badge.clock")
                        Text(currency.symbol)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        TextField("Minimum monthly payment", text: $minimumPayment)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .monospacedDigit()
                    }
                }
                .background(CentmondTheme.Colors.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.top, CentmondTheme.Spacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Owner (P4 — only shown if any household members exist)
            if !members.isEmpty {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Text("Owner")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Spacer()
                    Picker("", selection: $selectedOwner) {
                        Text("Joint / household").tag(nil as HouseholdMember?)
                        ForEach(members.filter(\.isActive)) { m in
                            Text(m.name).tag(m as HouseholdMember?)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.top, CentmondTheme.Spacing.md)
            }

            // Options
            HStack(spacing: CentmondTheme.Spacing.xl) {
                Toggle("Net Worth", isOn: $includeInNetWorth)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)

                Toggle("Budgeting", isOn: $includeInBudgeting)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.top, CentmondTheme.Spacing.md)

            // Errors
            if hasAttemptedSave, let error = nameError ?? balanceError ?? creditLimitError {
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

            // Save
            Button {
                hasAttemptedSave = true
                if isValid { save() }
            } label: {
                Text("Save Changes")
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

    // MARK: - Save

    private func save() {
        Haptics.impact()
        account.name = trimmedName
        account.type = type
        account.institutionName = institutionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : institutionName.trimmingCharacters(in: .whitespacesAndNewlines)
        account.lastFourDigits = lastFourDigits.isEmpty ? nil : lastFourDigits
        if let bal = Decimal(string: balance) {
            account.currentBalance = bal
        } else if balance.isEmpty {
            account.currentBalance = 0
        }
        account.currency = currency.rawValue
        account.colorHex = selectedColor
        account.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines)
        account.includeInNetWorth = includeInNetWorth
        account.includeInBudgeting = includeInBudgeting
        account.creditLimit = Decimal(string: creditLimit)
        account.interestRatePercent = interestRate.isEmpty ? nil : Double(interestRate)
        account.minimumPaymentMonthly = minimumPayment.isEmpty ? nil : Decimal(string: minimumPayment)
        account.ownerMember = selectedOwner
        dismiss()
    }
}
