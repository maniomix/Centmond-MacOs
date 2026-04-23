import SwiftUI
import SwiftData

/// Canonical entry-sheet style: close chip + type chips + hero amount +
/// grouped row panel + full-width button. Mirrors NewTransactionSheet so
/// the recurring entry feels like the same family of forms — earlier
/// design used native Picker/DatePicker chrome that clashed with the
/// dark theme.
struct NewRecurringSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var name = ""
    @State private var rawCents = ""
    @State private var amountInput = ""
    @State private var amountScale: CGFloat = 1.0
    @State private var isIncome = false
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var nextOccurrence = Date.now
    @State private var showDatePopover = false
    @State private var selectedAccount: Account?
    @State private var selectedCategory: BudgetCategory?
    @State private var hasAttemptedSave = false
    @State private var appeared = false

    @FocusState private var focusedField: FormField?
    private enum FormField: Hashable { case amount, name }

    private var amountActive: Bool { focusedField == .amount }
    private var amountColor: Color {
        isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary
    }

    private var amountDecimal: Decimal {
        guard !rawCents.isEmpty, let cents = Int(rawCents) else { return 0 }
        return Decimal(cents) / 100
    }

    private var formattedAmount: String {
        let n = NSDecimalNumber(decimal: amountDecimal)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: n) ?? "0.00"
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && amountDecimal > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            closeChip

            heroSection
                .padding(.bottom, CentmondTheme.Spacing.lg)
                .offset(y: appeared ? 0 : 8)
                .opacity(appeared ? 1 : 0)
                .animation(CentmondTheme.Motion.default.delay(0.05), value: appeared)

            fieldPanel
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .offset(y: appeared ? 0 : 8)
                .opacity(appeared ? 1 : 0)
                .animation(CentmondTheme.Motion.default.delay(0.1), value: appeared)

            autoCaption
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.top, CentmondTheme.Spacing.md)

            Spacer(minLength: CentmondTheme.Spacing.lg)

            Button {
                hasAttemptedSave = true
                if isValid { save() }
            } label: {
                Text("Add Recurring")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
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

    // MARK: - Header

    private var closeChip: some View {
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
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: CentmondTheme.Spacing.md) {
            HStack(spacing: 6) {
                typeChip("Expense", color: CentmondTheme.Colors.negative, selected: !isIncome) {
                    Haptics.tap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isIncome = false }
                }
                typeChip("Income", color: CentmondTheme.Colors.positive, selected: isIncome) {
                    Haptics.tap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isIncome = true }
                }
            }

            ZStack {
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
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            rawCents = trimmed
                        }
                        if amountInput != trimmed { amountInput = trimmed }
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

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("$")
                        .font(CentmondTheme.Typography.monoDisplay)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)

                    if rawCents.isEmpty {
                        BlinkingCursor(color: amountActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textQuaternary)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(formattedAmount)
                                .font(CentmondTheme.Typography.monoDisplay)
                                .foregroundStyle(amountColor)
                                .monospacedDigit()
                                .contentTransition(.numericText(countsDown: false))
                                .scaleEffect(amountScale, anchor: .bottom)
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
    }

    // MARK: - Field panel

    private var fieldPanel: some View {
        VStack(spacing: 1) {
            fieldRow {
                rowIcon("pencil")
                TextField("Name (e.g., Rent)", text: $name)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .focused($focusedField, equals: .name)
            }

            customPickerRow(
                icon: "repeat",
                label: frequency.displayName,
                options: frequencyOptions,
                selectedID: frequency.rawValue,
                onSelect: { id in
                    if let id, let f = RecurrenceFrequency(rawValue: id) { frequency = f }
                }
            )

            datePickerRow(
                icon: "calendar",
                label: nextOccurrence.formatted(.dateTime.day().month(.abbreviated).year())
            )

            customPickerRow(
                icon: "tag.fill",
                label: selectedCategory?.name ?? "Uncategorized",
                options: categoryOptions,
                selectedID: selectedCategory?.id.uuidString,
                onSelect: { id in
                    selectedCategory = id.flatMap { idStr in
                        categories.first(where: { $0.id.uuidString == idStr })
                    }
                }
            )

            customPickerRow(
                icon: "creditcard.fill",
                label: selectedAccount?.name ?? "No account",
                options: accountOptions,
                selectedID: selectedAccount?.id.uuidString,
                onSelect: { id in
                    selectedAccount = id.flatMap { idStr in
                        accounts.first(where: { $0.id.uuidString == idStr })
                    }
                }
            )
        }
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
    }

    // MARK: - Auto caption

    private var autoCaption: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "bolt.badge.automatic.fill")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.positive)
            Text("Transactions will be created automatically on each due date.")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Spacer()
        }
    }

    // MARK: - Helpers (canonical, mirror NewTransactionSheet)

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

    private func rowIcon(_ system: String) -> some View {
        Image(systemName: system)
            .font(CentmondTheme.Typography.captionSmall)
            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            .frame(width: 16)
    }

    private func fieldRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            content()
        }
        .frame(height: 36)
        .padding(.horizontal, CentmondTheme.Spacing.md)
    }

    private func customPickerRow(
        icon: String,
        label: String,
        options: [CentmondDropdownOption],
        selectedID: String?,
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        CentmondDropdown(options: options, selectedID: selectedID, onSelect: onSelect) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                rowIcon(icon)
                Text(label)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(CentmondTheme.Typography.micro.weight(.semibold))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
            .frame(height: 36)
            .padding(.horizontal, CentmondTheme.Spacing.md)
            .contentShape(Rectangle())
        }
    }

    /// Date row uses Button + .popover (per the project rule that
    /// `Menu { DatePicker }` silently fails to open on macOS). Popover
    /// content is the custom ModernCalendarPicker so we don't get the
    /// dated stock calendar grid.
    private func datePickerRow(icon: String, label: String) -> some View {
        Button {
            showDatePopover.toggle()
        } label: {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                rowIcon(icon)
                Text(label)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(CentmondTheme.Typography.micro.weight(.semibold))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
            .frame(height: 36)
            .padding(.horizontal, CentmondTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDatePopover) {
            ModernCalendarPicker(date: $nextOccurrence)
                .padding(CentmondTheme.Spacing.md)
                .frame(width: 280)
        }
    }

    // MARK: - Dropdown options

    private var frequencyOptions: [CentmondDropdownOption] {
        RecurrenceFrequency.allCases.map { f in
            CentmondDropdownOption(
                id: f.rawValue,
                name: f.displayName,
                iconSystem: "repeat",
                iconColor: CentmondTheme.Colors.accent
            )
        }
    }

    private var categoryOptions: [CentmondDropdownOption] {
        var opts: [CentmondDropdownOption] = [
            CentmondDropdownOption(
                id: "__reset__",
                name: "Uncategorized",
                iconSystem: "questionmark.circle",
                iconColor: nil,
                isResetOption: true
            )
        ]
        opts.append(contentsOf: categories.map { cat in
            CentmondDropdownOption(
                id: cat.id.uuidString,
                name: cat.name,
                iconSystem: cat.icon,
                iconColor: Color(hex: cat.colorHex)
            )
        })
        return opts
    }

    private var accountOptions: [CentmondDropdownOption] {
        var opts: [CentmondDropdownOption] = [
            CentmondDropdownOption(id: "__reset__", name: "No account", isResetOption: true)
        ]
        opts.append(contentsOf: accounts.filter { !$0.isArchived }.map { acct in
            CentmondDropdownOption(
                id: acct.id.uuidString,
                name: acct.name,
                iconSystem: "creditcard.fill",
                iconColor: CentmondTheme.Colors.accent
            )
        })
        return opts
    }

    // MARK: - BlinkingCursor (local copy — peer struct in NewTransactionSheet is fileprivate)

    private struct BlinkingCursor: View {
        let color: Color
        @State private var visible = true

        var body: some View {
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs)
                .fill(color)
                .frame(width: 2.5, height: 32)
                .opacity(visible ? 1 : 0)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
                .onAppear { visible = false }
        }
    }

    // MARK: - Save

    private func save() {
        let item = RecurringTransaction(
            name: name.trimmingCharacters(in: .whitespaces),
            amount: amountDecimal,
            isIncome: isIncome,
            frequency: frequency,
            nextOccurrence: nextOccurrence,
            autoCreate: true,
            account: selectedAccount,
            category: selectedCategory,
            householdMember: HouseholdService.resolveMember(
                forPayee: name,
                in: modelContext
            )
        )
        modelContext.insert(item)
        Haptics.impact()
        dismiss()
    }
}
