import SwiftUI
import SwiftData

struct NewAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.sortOrder) private var existingAccounts: [Account]

    // Core fields
    @State private var name = ""
    @State private var type: AccountType = .checking
    @State private var institutionName = ""
    @State private var lastFourDigits = ""
    @State private var balance = ""
    @State private var currency: SupportedCurrency = .usd
    @State private var selectedColor: String = AccountColorPreset.blue.rawValue

    // Extended fields
    @State private var notes = ""
    @State private var includeInNetWorth = true
    @State private var includeInBudgeting = true

    // Credit card fields
    @State private var creditLimit = ""

    // Validation & animation
    @State private var hasAttemptedSave = false
    @State private var appeared = false

    private var accentColor: Color { Color(hex: selectedColor) }

    // MARK: - Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameError: String? {
        guard hasAttemptedSave else { return nil }
        if trimmedName.isEmpty { return "Account name is required" }
        if existingAccounts.contains(where: { $0.name.lowercased() == trimmedName.lowercased() }) {
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
        && !existingAccounts.contains(where: { $0.name.lowercased() == trimmedName.lowercased() })
        && (balance.isEmpty || Decimal(string: balance) != nil)
        && (creditLimit.isEmpty || Decimal(string: creditLimit) != nil)
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

            // Hero: Big icon + type picker + color
            VStack(spacing: CentmondTheme.Spacing.lg) {
                // Big icon
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

                // Type picker
                Picker("", selection: $type) {
                    ForEach(AccountType.allCases) { accountType in
                        Label(accountType.displayName, systemImage: accountType.iconName)
                            .tag(accountType)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                // Color swatches
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
                                Haptics.tick()
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
                    TextField("Opening balance", text: $balance)
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

            // Credit card extra fields
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
                }
                .background(CentmondTheme.Colors.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.top, CentmondTheme.Spacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
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
                        .font(CentmondTheme.Typography.overlineRegular)
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
                if isValid { saveAccount() }
            } label: {
                Text("Create Account")
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
        .onChange(of: type) { _, newType in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                switch newType {
                case .checking:   selectedColor = "3B82F6"
                case .savings:    selectedColor = "22C55E"
                case .creditCard: selectedColor = "EF4444"
                case .investment: selectedColor = "8B5CF6"
                case .cash:       selectedColor = "F59E0B"
                case .other:      selectedColor = "64748B"
                }
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

    // MARK: - Save

    private func saveAccount() {
        Haptics.impact()
        let balanceDecimal = Decimal(string: balance) ?? 0
        let account = Account(
            name: trimmedName,
            type: type,
            institutionName: institutionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : institutionName.trimmingCharacters(in: .whitespacesAndNewlines),
            lastFourDigits: lastFourDigits.isEmpty ? nil : lastFourDigits,
            currentBalance: balanceDecimal,
            currency: currency.rawValue,
            colorHex: selectedColor,
            sortOrder: existingAccounts.count,
            openingBalance: balanceDecimal,
            openingBalanceDate: .now,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines),
            includeInNetWorth: includeInNetWorth,
            includeInBudgeting: includeInBudgeting,
            creditLimit: Decimal(string: creditLimit)
        )
        modelContext.insert(account)
        dismiss()
    }
}
