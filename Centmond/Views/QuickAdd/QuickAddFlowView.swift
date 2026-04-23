import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Quick Add — 3-step floating transaction entry. Uses `CentmondTheme`
/// for spacing/color/typography so the popup feels like a native
/// extension of the main window, not a barebones sheet.
struct QuickAddFlowView: View {
    enum Step: Int, CaseIterable { case entry, date, confirm }

    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<Account> { !$0.isArchived && !$0.isClosed },
        sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.name)]
    )
    private var accounts: [Account]

    @Query(sort: [SortDescriptor(\BudgetCategory.sortOrder), SortDescriptor(\BudgetCategory.name)])
    private var categories: [BudgetCategory]

    @Query(filter: #Predicate<HouseholdMember> { $0.isActive },
           sort: [SortDescriptor(\HouseholdMember.joinedAt)])
    private var members: [HouseholdMember]

    @State private var step: Step = .entry

    // Step 1 — core
    @State private var amountText: String = ""
    @State private var isIncome: Bool = false
    @State private var payee: String = ""
    @State private var accountID: UUID?
    @FocusState private var amountFocused: Bool

    // Step 1 — advanced
    @State private var advancedExpanded: Bool = false
    @State private var categoryID: UUID?
    @State private var notes: String = ""
    @State private var receiptData: Data?
    @State private var shareAcrossHousehold: Bool = false

    // Step 2
    @State private var date: Date = .now

    // Save
    @State private var isSaving: Bool = false
    @State private var savedFlash: Bool = false

    private let panelWidth: CGFloat = 460
    private let panelHeight: CGFloat = 480

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header
                Divider()
                    .background(CentmondTheme.Colors.strokeSubtle)
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        switch step {
                        case .entry:   entryStep
                        case .date:    dateStep
                        case .confirm: confirmStep
                        }
                    }
                    .padding(.horizontal, CentmondTheme.Spacing.xl)
                    .padding(.top, CentmondTheme.Spacing.lg)
                    .padding(.bottom, CentmondTheme.Spacing.md)
                }
                footer
            }

            if savedFlash { savedToast }
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(Color.clear)
        .onAppear { primeDefaults() }
    }

    // MARK: - Chrome

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(CentmondTheme.Colors.bgSecondary)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tintColor.opacity(0.10),
                            tintColor.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }

    private var header: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(tintColor.opacity(0.18))
                Image(systemName: stepIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tintColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Quick Add")
                    .font(CentmondTheme.Typography.subheading)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(stepLabel)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Spacer()

            StepIndicator(current: step.rawValue, total: Step.allCases.count, tint: tintColor)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xl)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    private var stepIcon: String {
        switch step {
        case .entry:   return isIncome ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
        case .date:    return "calendar"
        case .confirm: return "checkmark.seal.fill"
        }
    }

    private var stepLabel: String {
        switch step {
        case .entry:   return "Amount & merchant"
        case .date:    return "When did it happen?"
        case .confirm: return "Review and save"
        }
    }

    private var tintColor: Color {
        isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.accent
    }

    // MARK: - Step 1 — Entry

    private var entryStep: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            typeToggle
            amountDisplay
            payeeField
            if accounts.count > 1 { accountPicker }
            advancedSection
        }
    }

    private var typeToggle: some View {
        HStack(spacing: 6) {
            typeTab("Expense", icon: "arrow.up", selected: !isIncome, tint: CentmondTheme.Colors.negative) { isIncome = false }
            typeTab("Income",  icon: "arrow.down", selected: isIncome,  tint: CentmondTheme.Colors.positive) { isIncome = true }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                .fill(CentmondTheme.Colors.bgInput)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                .strokeBorder(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    private func typeTab(_ title: String, icon: String, selected: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title).font(CentmondTheme.Typography.bodyMedium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? tint : CentmondTheme.Colors.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? tint.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(CentmondTheme.Motion.micro, value: selected)
    }

    private var amountDisplay: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(currencySymbol)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            TextField("", text: $amountText, prompt: Text("0.00").foregroundColor(CentmondTheme.Colors.textQuaternary))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .textFieldStyle(.plain)
                .focused($amountFocused)
                .onChange(of: amountText) { _, newValue in
                    amountText = sanitizeAmount(newValue)
                }
            Spacer()
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, 14)
        .background(inputChrome)
    }

    private var payeeField: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: isIncome ? "dollarsign.arrow.circlepath" : "storefront")
                .font(.system(size: 13))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 16)
            TextField(
                "",
                text: $payee,
                prompt: Text(isIncome ? "Source (e.g. Paycheck)" : "Merchant (e.g. Lidl)")
                    .foregroundColor(CentmondTheme.Colors.textQuaternary)
            )
                .font(CentmondTheme.Typography.bodyLarge)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, 10)
        .background(inputChrome)
    }

    private var accountPicker: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "creditcard")
                .font(.system(size: 12))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 16)
            Text("Account")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Spacer()
            Menu {
                ForEach(accounts, id: \.id) { acct in
                    Button(acct.name) { accountID = acct.id }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedAccount?.name ?? "—")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, 10)
        .background(inputChrome)
    }

    // MARK: - Advanced disclosure

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            Button {
                withAnimation(CentmondTheme.Motion.default) { advancedExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                    Text("More options")
                        .font(CentmondTheme.Typography.captionMedium)
                    Spacer()
                    if !advancedExpanded { advancedBadges }
                }
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if advancedExpanded {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                    categoryRow
                    notesField
                    receiptRow
                    if activeMembers.count >= 2, !isIncome { shareRow }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var categoryRow: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "tag")
                .font(.system(size: 12))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 16)
            Text("Category")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Spacer()
            Menu {
                Button("Uncategorized") { categoryID = nil }
                Divider()
                ForEach(filteredCategories, id: \.id) { cat in
                    Button(cat.name) { categoryID = cat.id }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedCategory?.name ?? "Uncategorized")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, 10)
        .background(inputChrome)
    }

    private var notesField: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 12))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 16)
            TextField(
                "",
                text: $notes,
                prompt: Text("Notes").foregroundColor(CentmondTheme.Colors.textQuaternary)
            )
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, 10)
        .background(inputChrome)
    }

    private var receiptRow: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "paperclip")
                .font(.system(size: 12))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 16)
            Text("Receipt")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Spacer()
            if let data = receiptData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Button { receiptData = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            } else {
                Button("Attach…") { attachReceipt() }
                    .font(CentmondTheme.Typography.captionMedium)
                    .buttonStyle(.plain)
                    .foregroundStyle(CentmondTheme.Colors.accent)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, 10)
        .background(inputChrome)
    }

    private var shareRow: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Share across household")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                Text("Splits equally between \(activeMembers.count) members")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $shareAcrossHousehold)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, 10)
        .background(inputChrome)
    }

    private var advancedBadges: some View {
        HStack(spacing: 6) {
            if categoryID != nil { badgeIcon("tag") }
            if !notes.trimmingCharacters(in: .whitespaces).isEmpty { badgeIcon("text.alignleft") }
            if receiptData != nil { badgeIcon("paperclip") }
            if shareAcrossHousehold { badgeIcon("person.2.fill") }
        }
    }

    private func badgeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(CentmondTheme.Colors.accent)
            .padding(5)
            .background(Circle().fill(CentmondTheme.Colors.accentMuted.opacity(0.5)))
    }

    // MARK: - Step 2 — Date

    private var dateStep: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                datePresetChip("Today",      target: startOfDay(offset: 0))
                datePresetChip("Yesterday",  target: startOfDay(offset: -1))
                datePresetChip("2 days ago", target: startOfDay(offset: -2))
            }

            ModernCalendarPicker(date: $date)
                .padding(CentmondTheme.Spacing.md)
                .background(inputChrome)
        }
    }

    private func datePresetChip(_ label: String, target: Date) -> some View {
        let isSelected = Calendar.current.isDate(date, inSameDayAs: target)
        return Button {
            withAnimation(CentmondTheme.Motion.micro) { date = target }
        } label: {
            Text(label)
                .font(CentmondTheme.Typography.captionMedium)
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
                .background(
                    Capsule().fill(isSelected ? CentmondTheme.Colors.accentMuted.opacity(0.45) : CentmondTheme.Colors.bgInput)
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? CentmondTheme.Colors.accent.opacity(0.6) : CentmondTheme.Colors.strokeSubtle,
                        lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 3 — Confirm

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            // Hero
            VStack(alignment: .leading, spacing: 6) {
                Text(isIncome ? "Income" : "Expense")
                    .font(CentmondTheme.Typography.overlineSemibold)
                    .tracking(0.8)
                    .foregroundStyle(tintColor)
                Text(formattedAmount)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(payee)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CentmondTheme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .fill(tintColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .strokeBorder(tintColor.opacity(0.25), lineWidth: 1)
            )

            // Meta
            VStack(spacing: 1) {
                summaryRow(icon: "calendar",    label: "Date",     value: Self.dateFormatter.string(from: date))
                if let name = selectedAccount?.name {
                    summaryRow(icon: "creditcard", label: "Account", value: name)
                }
                if let cat = selectedCategory {
                    summaryRow(icon: "tag",       label: "Category", value: cat.name)
                }
                if receiptData != nil {
                    summaryRow(icon: "paperclip", label: "Receipt",  value: "Attached")
                }
                if shareAcrossHousehold, activeMembers.count >= 2 {
                    summaryRow(icon: "person.2.fill", label: "Split", value: "\(activeMembers.count) members")
                }
            }
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                    .fill(CentmondTheme.Colors.bgInput)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                    .strokeBorder(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
        }
    }

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 14)
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Spacer()
            Text(value)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, 9)
    }

    // MARK: - Footer / save

    private var footer: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            secondaryButton("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if step != .entry {
                secondaryButton("Back") { advance(by: -1) }
                    .disabled(isSaving)
            }
            primaryButton(step == .confirm ? (isSaving ? "Saving…" : "Save") : "Next", tint: tintColor) {
                if step == .confirm { save() } else { advance(by: 1) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdvance)
            .opacity(canAdvance ? 1 : 0.4)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xl)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .background(
            Rectangle()
                .fill(CentmondTheme.Colors.bgTertiary.opacity(0.5))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(CentmondTheme.Colors.strokeSubtle),
                    alignment: .top
                )
        )
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(CentmondTheme.Colors.bgQuaternary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(.white)
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canAdvance: Bool {
        switch step {
        case .entry:   return entryIsValid
        case .date:    return true
        case .confirm: return !isSaving
        }
    }

    private var entryIsValid: Bool {
        guard let amount = parsedAmount, amount > 0 else { return false }
        return !payee.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var savedToast: some View {
        VStack {
            Spacer()
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(CentmondTheme.Colors.positive)
                Text("Saved")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(CentmondTheme.Colors.bgTertiary)
            )
            .overlay(
                Capsule().strokeBorder(CentmondTheme.Colors.positive.opacity(0.4), lineWidth: 1)
            )
            .padding(.bottom, 80)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var inputChrome: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                .fill(CentmondTheme.Colors.bgInput)
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                .strokeBorder(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        }
    }

    // MARK: - Helpers

    private var selectedAccount: Account? {
        accounts.first(where: { $0.id == accountID }) ?? accounts.first
    }

    private var selectedCategory: BudgetCategory? {
        categories.first(where: { $0.id == categoryID })
    }

    private var activeMembers: [HouseholdMember] { members.filter(\.isActive) }

    private var filteredCategories: [BudgetCategory] {
        categories.filter { $0.isExpenseCategory != isIncome }
    }

    private var parsedAmount: Decimal? {
        Decimal(string: amountText.replacingOccurrences(of: ",", with: "."))
    }

    private var formattedAmount: String {
        let code = UserDefaults.standard.string(forKey: "defaultCurrency") ?? "USD"
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        let decimal = (parsedAmount ?? 0) as NSDecimalNumber
        return f.string(from: decimal) ?? "\(currencySymbol)\(amountText)"
    }

    private var currencySymbol: String {
        let code = UserDefaults.standard.string(forKey: "defaultCurrency") ?? "USD"
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        return f.currencySymbol ?? "$"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func startOfDay(offset days: Int) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: .now)
        return cal.date(byAdding: .day, value: days, to: base) ?? base
    }

    private func primeDefaults() {
        if accountID == nil { accountID = accounts.first?.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            amountFocused = true
        }
    }

    private func advance(by delta: Int) {
        let next = step.rawValue + delta
        guard let s = Step(rawValue: next) else { return }
        withAnimation(CentmondTheme.Motion.default) { step = s }
    }

    private func attachReceipt() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Attach"
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        receiptData = Self.downsample(image, maxDimension: 640)
    }

    private static func downsample(_ image: NSImage, maxDimension: CGFloat) -> Data? {
        let size = image.size
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(newSize.width),
            pixelsHigh: Int(newSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return image.tiffRepresentation }
        rep.size = newSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1.0)
        return rep.representation(using: .png, properties: [:])
    }

    private func save() {
        guard let amount = parsedAmount, amount > 0 else { return }
        let trimmed = payee.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isSaving = true

        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        let tx = Transaction(
            date: date,
            payee: trimmed,
            amount: amount,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            isIncome: isIncome,
            status: .cleared,
            isReviewed: true,
            account: selectedAccount,
            category: selectedCategory
        )
        tx.receiptImageData = receiptData
        modelContext.insert(tx)

        if shareAcrossHousehold, !isIncome, activeMembers.count >= 2 {
            HouseholdService.applyEqualSplit(to: tx, members: activeMembers, in: modelContext)
        }

        do {
            try modelContext.save()
        } catch {
            isSaving = false
            return
        }

        NotificationCenter.default.post(name: .quickAddDidSave, object: nil)

        withAnimation(.easeOut(duration: 0.2)) { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            onClose()
        }
    }

    private func sanitizeAmount(_ raw: String) -> String {
        var seenSeparator = false
        var out = ""
        for ch in raw {
            if ch.isNumber {
                out.append(ch)
            } else if ch == "." || ch == "," {
                if seenSeparator { continue }
                seenSeparator = true
                out.append(ch)
            }
        }
        return out
    }
}

private struct StepIndicator: View {
    let current: Int
    let total: Int
    let tint: Color
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? tint : CentmondTheme.Colors.strokeStrong)
                    .frame(width: i == current ? 18 : 6, height: 4)
                    .animation(CentmondTheme.Motion.default, value: current)
            }
        }
    }
}

extension Notification.Name {
    static let quickAddDidSave = Notification.Name("centmond.quickAddDidSave")
}
