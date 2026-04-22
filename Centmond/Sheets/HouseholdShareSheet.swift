import SwiftUI
import SwiftData

/// Split a transaction across household members — the "who owes what" layer,
/// distinct from `SplitTransactionSheet` which slices a transaction across
/// *categories*. Writes `ExpenseShare` rows via `HouseholdService` helpers.
///
/// Three methods:
///   • Equal — total ÷ selected member count, remainder cent on first share.
///   • Percent — user weights; normalized against their sum.
///   • Exact — user types each amount; must sum to total within 1¢.
struct HouseholdShareSheet: View {
    let transaction: Transaction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HouseholdMember.joinedAt) private var allMembers: [HouseholdMember]

    @State private var method: ExpenseShareMethod = .equal
    @State private var selectedIDs: Set<UUID> = []
    @State private var percents: [UUID: Double] = [:]
    @State private var exactAmounts: [UUID: String] = [:]
    @State private var saveError: String?

    private static let reconcileTolerance: Decimal = Decimal(string: "0.01") ?? 0

    private var activeMembers: [HouseholdMember] { allMembers.filter(\.isActive) }
    private var chosenMembers: [HouseholdMember] {
        activeMembers.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Share Across Members") { dismiss() }
            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xl) {
                    parentCard
                    methodPicker
                    if activeMembers.isEmpty {
                        emptyState
                    } else {
                        memberRows
                        if method != .equal { reconciliationFooter }
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)
            footer
        }
        .frame(minHeight: 540)
        .onAppear(perform: seedState)
    }

    // MARK: - Sections

    private var parentCard: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text("TRANSACTION")
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.3)
            HStack {
                Text(transaction.payee)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Spacer()
                Text(CurrencyFormat.standard(transaction.amount))
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            .padding(CentmondTheme.Spacing.sm)
            .background(CentmondTheme.Colors.bgQuaternary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
        }
    }

    private var methodPicker: some View {
        Picker("Method", selection: $method) {
            Text("Equal").tag(ExpenseShareMethod.equal)
            Text("Percent").tag(ExpenseShareMethod.percent)
            Text("Exact").tag(ExpenseShareMethod.exact)
        }
        .pickerStyle(.segmented)
    }

    private var memberRows: some View {
        VStack(spacing: CentmondTheme.Spacing.xs) {
            ForEach(activeMembers, id: \.id) { m in
                memberRow(m)
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ m: HouseholdMember) -> some View {
        let isOn = selectedIDs.contains(m.id)
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Button {
                toggle(m)
            } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
            }
            .buttonStyle(.plain)

            Text(m.name)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Spacer()
            trailingField(for: m, enabled: isOn)
        }
        .padding(CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
    }

    @ViewBuilder
    private func trailingField(for m: HouseholdMember, enabled: Bool) -> some View {
        switch method {
        case .equal:
            Text(enabled ? CurrencyFormat.standard(equalPreviewAmount(for: m)) : "—")
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
        case .percent:
            TextField("0", value: Binding(
                get: { percents[m.id] ?? 0 },
                set: { percents[m.id] = $0 }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
            .disabled(!enabled)
            Text("%")
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        case .exact:
            TextField("0.00", text: Binding(
                get: { exactAmounts[m.id] ?? "" },
                set: { exactAmounts[m.id] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 96)
            .disabled(!enabled)
        case .shares:
            EmptyView()
        }
    }

    private var reconciliationFooter: some View {
        HStack {
            Text(footerLabel)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(footerTint)
            Spacer()
            Text(footerValue)
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(footerTint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: CentmondTheme.Spacing.xs) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 28))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text("Add household members first")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(CentmondTheme.Spacing.xl)
    }

    private var footer: some View {
        HStack {
            if let e = saveError {
                Text(e)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.negative)
            } else if !transaction.shares.isEmpty {
                Button(role: .destructive) {
                    clearExisting()
                } label: {
                    Text("Clear")
                        .font(CentmondTheme.Typography.captionMedium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(CentmondTheme.Colors.negative)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
            Button("Save Split") { save() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!isValid)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
    }

    // MARK: - Validation / preview

    private var isValid: Bool {
        guard !chosenMembers.isEmpty else { return false }
        switch method {
        case .equal:
            return chosenMembers.count >= 1
        case .percent:
            let sum = chosenMembers.reduce(0.0) { $0 + (percents[$1.id] ?? 0) }
            return sum > 0
        case .exact:
            let sum = chosenMembers.reduce(Decimal(0)) { $0 + (DecimalInput.parseNonNegative(exactAmounts[$1.id] ?? "") ?? 0) }
            return magnitude(transaction.amount - sum) <= Self.reconcileTolerance
        case .shares:
            return false
        }
    }

    private var footerLabel: String {
        method == .exact ? "Remaining" : "Weights sum"
    }
    private var footerValue: String {
        switch method {
        case .exact:
            let sum = chosenMembers.reduce(Decimal(0)) { $0 + (DecimalInput.parseNonNegative(exactAmounts[$1.id] ?? "") ?? 0) }
            return CurrencyFormat.standard(transaction.amount - sum)
        case .percent:
            let sum = chosenMembers.reduce(0.0) { $0 + (percents[$1.id] ?? 0) }
            return String(format: "%.0f%%", sum)
        default:
            return ""
        }
    }
    private var footerTint: Color {
        isValid ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textTertiary
    }

    private func equalPreviewAmount(for m: HouseholdMember) -> Decimal {
        let count = chosenMembers.count
        guard count > 0, chosenMembers.contains(where: { $0.id == m.id }) else { return 0 }
        let amounts = HouseholdService.equalShares(total: transaction.amount, memberCount: count)
        guard let idx = chosenMembers.firstIndex(where: { $0.id == m.id }) else { return 0 }
        return amounts[idx]
    }

    private func magnitude(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

    // MARK: - Actions

    private func toggle(_ m: HouseholdMember) {
        if selectedIDs.contains(m.id) {
            selectedIDs.remove(m.id)
        } else {
            selectedIDs.insert(m.id)
        }
    }

    private func seedState() {
        if transaction.shares.isEmpty {
            selectedIDs = Set(activeMembers.map(\.id))
        } else {
            selectedIDs = Set(transaction.shares.compactMap { $0.member?.id })
            if let first = transaction.shares.first {
                method = first.method == .shares ? .equal : first.method
            }
            for s in transaction.shares {
                guard let mid = s.member?.id else { continue }
                if let p = s.percent { percents[mid] = p }
                exactAmounts[mid] = DecimalInput.editableString(s.amount)
            }
        }
    }

    private func save() {
        guard isValid else { return }
        switch method {
        case .equal:
            HouseholdService.applyEqualSplit(
                to: transaction, members: chosenMembers, in: modelContext
            )
        case .percent:
            let values = chosenMembers.map { percents[$0.id] ?? 0 }
            HouseholdService.applyPercentSplit(
                to: transaction, members: chosenMembers,
                percents: values, in: modelContext
            )
        case .exact:
            let amounts = chosenMembers.map {
                DecimalInput.parseNonNegative(exactAmounts[$0.id] ?? "") ?? 0
            }
            HouseholdService.applyExactSplit(
                to: transaction, members: chosenMembers,
                amounts: amounts, in: modelContext
            )
        case .shares:
            break
        }
        transaction.updatedAt = .now
        try? modelContext.save()
        HouseholdTelemetry.shared.recordSplitCreated()
        dismiss()
    }

    private func clearExisting() {
        for s in transaction.shares {
            modelContext.delete(s)
        }
        try? modelContext.save()
        dismiss()
    }
}
