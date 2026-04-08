import SwiftUI
import SwiftData

struct NewTransactionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    /// Raw cents digits (only digits stored, e.g. "125099" → $1,250.99)
    @State private var rawCents = ""
    @State private var payee = ""
    @State private var selectedCategory: BudgetCategory?
    @State private var selectedAccount: Account?
    @State private var date = Date.now
    @State private var notes = ""
    @State private var isIncome = false
    @State private var appeared = false
    @State private var amountScale: CGFloat = 1.0
    @FocusState private var focusedField: FormField?

    private enum FormField: Hashable { case amount, payee, notes }

    private var amountActive: Bool { focusedField == .amount }

    private var isValid: Bool { !rawCents.isEmpty && !TextNormalization.isBlank(payee) }

    private var filteredCategories: [BudgetCategory] {
        categories.filter { isIncome ? !$0.isExpenseCategory : $0.isExpenseCategory }
    }

    /// "125099" → "1,250.99"
    private var formattedAmount: String {
        guard !rawCents.isEmpty else { return "" }
        let cents = Int(rawCents) ?? 0
        let dollars = cents / 100
        let remainder = cents % 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let dollarsStr = formatter.string(from: NSNumber(value: dollars)) ?? "\(dollars)"
        return String(format: "%@.%02d", dollarsStr, remainder)
    }

    private var decimalAmount: Decimal? {
        guard !rawCents.isEmpty else { return nil }
        return Decimal(Int(rawCents) ?? 0) / 100
    }

    private var amountColor: Color {
        if rawCents.isEmpty { return CentmondTheme.Colors.textTertiary }
        return isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary
    }

    // The hidden TextField binds to this — we intercept and filter to digits only
    @State private var amountInput = ""

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

            // Type + Amount
            VStack(spacing: CentmondTheme.Spacing.md) {
                HStack(spacing: 6) {
                    typeChip("Expense", color: CentmondTheme.Colors.negative, selected: !isIncome) {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            isIncome = false
                            selectedCategory = nil
                        }
                    }
                    typeChip("Income", color: CentmondTheme.Colors.positive, selected: isIncome) {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            isIncome = true
                            selectedCategory = nil
                        }
                    }
                }

                // Amount area — tap to activate
                ZStack {
                    // Hidden TextField — actual input target for amount
                    TextField("", text: $amountInput)
                        .textFieldStyle(.plain)
                        .frame(width: 1, height: 1)
                        .opacity(0.001)
                        .focused($focusedField, equals: .amount)
                        .onChange(of: amountInput) { _, new in
                            let digits = new.filter(\.isNumber)
                            let capped = String(digits.prefix(8))
                            let trimmed = capped.isEmpty ? "" : String(Int(capped) ?? 0)
                            let oldCount = rawCents.count
                            // Animate rawCents change so contentTransition(.numericText) fires
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                rawCents = trimmed
                            }
                            if amountInput != trimmed {
                                amountInput = trimmed
                            }
                            // Scale bounce
                            if trimmed.count > oldCount {
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { amountScale = 1.06 }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { amountScale = 1.0 }
                                }
                            } else if trimmed.count < oldCount {
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { amountScale = 0.95 }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                    withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { amountScale = 1.0 }
                                }
                            }
                        }

                    // Visual display
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("$")
                            .font(.system(size: 36, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)

                        if rawCents.isEmpty {
                            BlinkingCursor(color: amountActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textQuaternary)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(formattedAmount)
                                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(amountColor)
                                    .monospacedDigit()
                                    .contentTransition(.numericText(countsDown: false))
                                    .scaleEffect(amountScale, anchor: .bottom)
                                    .shadow(
                                        color: (isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative).opacity(0.35),
                                        radius: 14, y: 4
                                    )
                                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isIncome)

                                if amountActive {
                                    BlinkingCursor(color: amountColor)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .amount }
                }
                .frame(height: 50)
            }
            .padding(.bottom, CentmondTheme.Spacing.lg)
            .offset(y: appeared ? 0 : 8)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.05), value: appeared)

            // Fields
            VStack(spacing: 1) {
                fieldRow {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .frame(width: 16)
                    TextField("Transaction name", text: $payee)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .focused($focusedField, equals: .payee)
                }

                fieldRow {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .frame(width: 16)
                    Picker("Category", selection: $selectedCategory) {
                        Text("Uncategorized").tag(nil as BudgetCategory?)
                        ForEach(filteredCategories) { category in
                            Label(category.name, systemImage: category.icon)
                                .tag(category as BudgetCategory?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer()
                }

                fieldRow {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .frame(width: 16)
                    Picker("Account", selection: $selectedAccount) {
                        Text("No account").tag(nil as Account?)
                        ForEach(accounts) { account in
                            Text(account.name).tag(account as Account?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer()
                }

                fieldRow {
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .frame(width: 16)
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.field)
                        .labelsHidden()
                    Spacer()
                }

                fieldRow {
                    Image(systemName: "note.text")
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .frame(width: 16)
                    TextField("Note (optional)", text: $notes)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .focused($focusedField, equals: .notes)
                }
            }
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .offset(y: appeared ? 0 : 8)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.1), value: appeared)

            Spacer(minLength: CentmondTheme.Spacing.lg)

            Button { saveTransaction() } label: {
                Text("Add Transaction")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!isValid)
            .opacity(isValid ? 1 : 0.4)
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
                focusedField = .amount
            }
        }
    }

    // MARK: - Components

    private func typeChip(_ title: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(selected ? .white : CentmondTheme.Colors.textQuaternary)
                .padding(.horizontal, CentmondTheme.Spacing.xl)
                .frame(height: 28)
                .background(selected ? color : CentmondTheme.Colors.bgTertiary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plainHover)
    }

    private func fieldRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            content()
        }
        .frame(height: 36)
        .padding(.horizontal, CentmondTheme.Spacing.md)
    }

    // MARK: - Save

    private func saveTransaction() {
        Haptics.impact()
        guard let amount = decimalAmount, amount > 0 else { return }
        let trimmedPayee = TextNormalization.trimmed(payee)
        guard !trimmedPayee.isEmpty else { return }
        let transaction = Transaction(
            date: date,
            payee: trimmedPayee,
            amount: amount,
            notes: TextNormalization.trimmedOrNil(notes),
            isIncome: isIncome,
            account: selectedAccount,
            category: selectedCategory
        )
        modelContext.insert(transaction)
        dismiss()
    }
}

// MARK: - Blinking Cursor

private struct BlinkingCursor: View {
    let color: Color
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2.5, height: 32)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible = false }
    }
}
