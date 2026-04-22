import SwiftUI
import SwiftData

/// Pairwise balance viewer + settle-up action. Shows every pair of active
/// members with an open balance, lets the user record a settlement (optionally
/// backed by a real Transaction that cashes through a chosen Account).
struct HouseholdSettleUpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HouseholdMember.joinedAt) private var allMembers: [HouseholdMember]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var balancesSnapshot: [HouseholdService.Balance] = []
    @State private var pairBalances: [PairBalance] = []
    @State private var selectedPair: PairBalance.ID?
    @State private var settleAmount: String = ""
    @State private var createLinkedTransaction: Bool = true
    @State private var selectedAccount: Account?
    @State private var saveError: String?

    struct PairBalance: Identifiable, Hashable {
        let id: String
        let debtor: HouseholdMember
        let creditor: HouseholdMember
        let amount: Decimal
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Record Payment") { dismiss() }
            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xl) {
                    summary
                    if pairBalances.isEmpty {
                        emptyState
                    } else {
                        pairList
                        if selectedPair != nil { settleForm }
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)
            footer
        }
        .frame(minHeight: 560)
        .onAppear(perform: refresh)
    }

    // MARK: - Sections

    private var summary: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text("MEMBER BALANCES")
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.3)
            ForEach(balancesSnapshot, id: \.member.id) { b in
                HStack {
                    Circle()
                        .fill(Color(hex: b.member.avatarColor))
                        .frame(width: 10, height: 10)
                    Text(b.member.name)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    Text(balanceLabel(b.amount))
                        .font(CentmondTheme.Typography.mono)
                        .foregroundStyle(balanceTint(b.amount))
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var pairList: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text("OPEN BALANCES")
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.3)
            ForEach(pairBalances) { pair in
                Button {
                    selectedPair = pair.id
                    settleAmount = DecimalInput.editableString(pair.amount)
                } label: {
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: selectedPair == pair.id ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 14))
                            .foregroundStyle(selectedPair == pair.id ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                        Text("\(pair.debtor.name)")
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        Text("\(pair.creditor.name)")
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Spacer()
                        Text(CurrencyFormat.standard(pair.amount))
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.negative)
                    }
                    .padding(CentmondTheme.Spacing.sm)
                    .background(CentmondTheme.Colors.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var settleForm: some View {
        if let pair = pairBalances.first(where: { $0.id == selectedPair }) {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                Text("PAYMENT DETAILS")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.3)
                Text("Logs a payment that has already happened. This does not transfer money on your behalf.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Amount paid")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    TextField("0.00", text: $settleAmount)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                Toggle(isOn: $createLinkedTransaction) {
                    Text("Also add a matching Transaction to the ledger")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }
                if createLinkedTransaction, !accounts.filter({ !$0.isArchived }).isEmpty {
                    HStack {
                        Text("Account")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        Spacer()
                        Picker("", selection: $selectedAccount) {
                            Text("None").tag(nil as Account?)
                            ForEach(accounts.filter { !$0.isArchived }) { acc in
                                Text(acc.name).tag(acc as Account?)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 180)
                    }
                }
                Text("\(pair.debtor.name) pays \(pair.creditor.name)")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: CentmondTheme.Spacing.xs) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28))
                .foregroundStyle(CentmondTheme.Colors.positive)
            Text("All balances are settled")
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
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
            Button("Record Payment") { settle() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSettle)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
    }

    // MARK: - Logic

    private var canSettle: Bool {
        guard let amt = DecimalInput.parsePositive(settleAmount), amt > 0 else { return false }
        return selectedPair != nil
    }

    private func balanceLabel(_ v: Decimal) -> String {
        if v > 0 { return "+ \(CurrencyFormat.standard(v)) owed to" }
        if v < 0 { return "\(CurrencyFormat.standard(-v)) owed by" }
        return CurrencyFormat.standard(0)
    }
    private func balanceTint(_ v: Decimal) -> Color {
        if v > 0 { return CentmondTheme.Colors.positive }
        if v < 0 { return CentmondTheme.Colors.negative }
        return CentmondTheme.Colors.textSecondary
    }

    private func refresh() {
        balancesSnapshot = HouseholdService.balances(in: modelContext)
        pairBalances = computePairBalances()
        if selectedAccount == nil {
            selectedAccount = accounts.first(where: { !$0.isArchived })
        }
    }

    private func computePairBalances() -> [PairBalance] {
        var tallies: [String: Decimal] = [:]
        var keyToPair: [String: (HouseholdMember, HouseholdMember)] = [:]

        let shareDescriptor = FetchDescriptor<ExpenseShare>()
        let shares = (try? modelContext.fetch(shareDescriptor)) ?? []
        for s in shares where s.status == .owed {
            guard
                let debtor = s.member,
                let parent = s.parentTransaction,
                let creditor = parent.householdMember,
                debtor.id != creditor.id
            else { continue }
            let key = "\(debtor.id)->\(creditor.id)"
            tallies[key, default: 0] += s.amount
            keyToPair[key] = (debtor, creditor)
        }

        let settleDescriptor = FetchDescriptor<HouseholdSettlement>()
        for st in (try? modelContext.fetch(settleDescriptor)) ?? [] {
            guard let from = st.fromMember, let to = st.toMember else { continue }
            let key = "\(from.id)->\(to.id)"
            tallies[key, default: 0] -= st.amount
        }

        return tallies.compactMap { key, amount in
            guard amount > 0, let pair = keyToPair[key] else { return nil }
            return PairBalance(id: key, debtor: pair.0, creditor: pair.1, amount: amount)
        }
        .sorted { $0.amount > $1.amount }
    }

    private func settle() {
        guard
            let amt = DecimalInput.parsePositive(settleAmount),
            let pair = pairBalances.first(where: { $0.id == selectedPair })
        else { return }

        HouseholdService.recordSettlement(
            from: pair.debtor,
            to: pair.creditor,
            amount: amt,
            date: .now,
            note: nil,
            account: createLinkedTransaction ? selectedAccount : nil,
            createLinkedTransaction: createLinkedTransaction,
            in: modelContext
        )
        try? modelContext.save()
        HouseholdTelemetry.shared.recordSettlementLogged()
        settleAmount = ""
        selectedPair = nil
        refresh()
        if pairBalances.isEmpty {
            dismiss()
        }
    }
}
