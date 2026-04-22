import SwiftUI
import SwiftData
import AppKit

/// Household hub. P5 rebuild: tabbed layout with Overview / Splits /
/// Settlements / Members. Surfaces per-member net worth, open splits,
/// pairwise balances, and the settle-up entry point.
struct HouseholdView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HouseholdMember.joinedAt) private var allMembers: [HouseholdMember]
    @Query private var transactions: [Transaction]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var shares: [ExpenseShare]
    @Query(sort: \HouseholdSettlement.date, order: .reverse) private var settlements: [HouseholdSettlement]

    @State private var tab: HubTab = .overview
    @State private var showAddMember = false
    @State private var newMemberName = ""
    @State private var newMemberEmail = ""
    @State private var memberToDelete: HouseholdMember?
    @State private var showDeleteConfirmation = false

    // MARK: - Snapshot cache
    //
    // Pattern mirrors DashboardSnapshot. Heaviest hotspots before cache:
    // balancesPanel + memberBalance(m) + totalUnsettled() each called
    // HouseholdService.balances(in:) which is a full balance pass over
    // shares+settlements; called multiple times per body render.
    // HouseholdService.netWorth(for:in:) was also called per-member.
    @State private var snapshot = HouseholdSnapshot()

    struct HouseholdSnapshot {
        var balances: [HouseholdService.Balance] = []
        var balanceByMemberID: [UUID: Decimal] = [:]
        var netWorthByMemberID: [UUID: Decimal] = [:]
        var monthSpendingByMemberID: [UUID: Decimal] = [:]
        var splitTxns: [Transaction] = []
        var currentMonthSpending: Decimal = 0
        var totalUnsettled: Decimal = 0
        var openSplitCount: Int = 0
        /// Debt-first pair list for the "who owes who" panel on the
        /// Overview tab — precomputed so body stays O(1).
        var pairBalances: [HouseholdService.PairBalance] = []
    }

    private func rebuildSnapshot() {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: .now))!

        var monthSpending: Decimal = 0
        var spendByMember: [UUID: Decimal] = [:]
        var splits: [Transaction] = []
        for tx in transactions {
            if !tx.shares.isEmpty { splits.append(tx) }
            guard tx.date >= monthStart, BalanceService.isSpendingExpense(tx) else { continue }
            monthSpending += tx.amount
            if let mid = tx.householdMember?.id {
                spendByMember[mid, default: 0] += tx.amount
            }
        }
        splits.sort { $0.date > $1.date }

        let bals = HouseholdService.balances(in: modelContext)
        var balByMember: [UUID: Decimal] = [:]
        var unsettled: Decimal = 0
        for b in bals {
            balByMember[b.member.id] = b.amount
            if b.amount > 0 { unsettled += b.amount }
        }

        var nwByMember: [UUID: Decimal] = [:]
        for m in allMembers where m.isActive {
            nwByMember[m.id] = HouseholdService.netWorth(for: m, in: modelContext)
        }

        var next = HouseholdSnapshot()
        next.balances = bals
        next.balanceByMemberID = balByMember
        next.netWorthByMemberID = nwByMember
        next.monthSpendingByMemberID = spendByMember
        next.splitTxns = splits
        next.currentMonthSpending = monthSpending
        next.totalUnsettled = unsettled
        next.openSplitCount = shares.filter { $0.status == .owed }.count
        next.pairBalances = HouseholdService.openPairBalances(in: modelContext)
        snapshot = next
    }

    private let avatarColors = ["3B82F6", "8B5CF6", "EC4899", "F97316", "22C55E", "EF4444", "06B6D4", "F59E0B"]

    enum HubTab: String, CaseIterable, Identifiable {
        case overview, splits, settlements, members
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview: return "Overview"
            case .splits: return "Splits"
            case .settlements: return "Settlements"
            case .members: return "Members"
            }
        }
        var icon: String {
            switch self {
            case .overview: return "chart.bar.fill"
            case .splits: return "rectangle.split.3x1.fill"
            case .settlements: return "arrow.left.arrow.right.circle.fill"
            case .members: return "person.2.fill"
            }
        }
    }

    private var members: [HouseholdMember] { allMembers.filter(\.isActive) }
    private var archivedMembers: [HouseholdMember] { allMembers.filter { !$0.isActive } }

    var body: some View {
        Group {
            if allMembers.isEmpty {
                emptySetup
            } else {
                VStack(spacing: 0) {
                    headerBar
                    tabBar
                    tabContent
                }
            }
        }
        .alert("Delete Member?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let m = memberToDelete {
                    // Clear scope if the deleted member was the active scope.
                    if router.selectedMemberID == m.id {
                        router.selectedMemberID = nil
                    }
                    modelContext.delete(m)
                    try? modelContext.save()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let m = memberToDelete {
                Text("Delete \"\(m.name)\"? Their transaction attributions and open share rows will be cleared. This cannot be undone.")
            }
        }
        .onAppear { rebuildSnapshot() }
        .onChange(of: snapshotRebuildKey) { _, _ in rebuildSnapshot() }
    }

    /// One composite key for every observable that should rebuild the
    /// household snapshot. Collapsing many `.onChange` modifiers into a
    /// single hashable string keeps the body type-checkable (the chained
    /// form tripped "compiler unable to type-check this expression in
    /// reasonable time") while still covering: (a) collection counts,
    /// (b) gating scalars (amount, status), and (c) every relationship id
    /// the service-layer joins use (share.member, share.parentTransaction,
    /// transaction.householdMember).
    private var snapshotRebuildKey: String {
        var parts: [String] = []
        parts.append("m\(allMembers.count)")
        parts.append("t\(transactions.count)")
        parts.append("s\(shares.count)")
        parts.append("st\(settlements.count)")
        parts.append("a\(accounts.count)")
        for tx in transactions {
            parts.append("\(tx.amount)|\(tx.householdMember?.id.uuidString ?? "_")")
        }
        for s in shares {
            parts.append("\(s.amount)|\(s.status.rawValue)|\(s.member?.id.uuidString ?? "_")|\(s.parentTransaction?.id.uuidString ?? "_")")
        }
        for st in settlements { parts.append("\(st.amount)") }
        for a in accounts { parts.append("\(a.currentBalance)") }
        return parts.joined(separator: ";")
    }

    // MARK: - Empty state

    /// Single centered card. Earlier iteration used EmptyStateView with a
    /// "Create Household" CTA that revealed a form at the BOTTOM of the
    /// page — which produced a huge gap between the icon/title and the
    /// form, looked broken. This version puts everything in one card so
    /// there's no spatial disconnect between the prompt and the input.
    private var emptySetup: some View {
        VStack {
            Spacer(minLength: 0)
            emptySetupCard
                .frame(maxWidth: 360)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CentmondTheme.Spacing.xxl)
    }

    /// Minimal name/email form. User asked to drop the icon + heading +
    /// description + caption — just the two fields and a create button.
    private var emptySetupCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                setupField("NAME") {
                    TextField("", text: $newMemberName, prompt: Text("Your name").foregroundStyle(CentmondTheme.Colors.textQuaternary))
                        .textFieldStyle(.plain)
                }
                setupField("EMAIL") {
                    TextField("", text: $newMemberEmail, prompt: Text("optional").foregroundStyle(CentmondTheme.Colors.textQuaternary))
                        .textFieldStyle(.plain)
                }
                Button {
                    createFirstMember()
                } label: {
                    Text("Create").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(newMemberName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(CentmondTheme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func setupField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text(label)
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
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

    private func createFirstMember() {
        let name = newMemberName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let member = HouseholdMember(
            name: name,
            email: newMemberEmail.isEmpty ? nil : newMemberEmail.trimmingCharacters(in: .whitespaces),
            avatarColor: avatarColors[0],
            isOwner: true
        )
        modelContext.insert(member)
        newMemberName = ""
        newMemberEmail = ""
        showAddMember = false
    }

    // MARK: - Header (hero strip)

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack {
                Text("Household")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Spacer()
                Button {
                    router.showSheet(.householdSettleUp)
                } label: {
                    Label("Record Payment", systemImage: "arrow.left.arrow.right.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(members.count < 2)

                Button {
                    showAddMember.toggle()
                    newMemberName = ""
                    newMemberEmail = ""
                } label: {
                    Label("Add Member", systemImage: "person.badge.plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            heroStrip
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    private var heroStrip: some View {
        HStack(spacing: CentmondTheme.Spacing.lg) {
            heroCard(
                label: "MEMBERS",
                value: "\(members.count)",
                icon: "person.2.fill",
                color: CentmondTheme.Colors.accent
            )
            heroCard(
                label: "THIS MONTH",
                value: CurrencyFormat.compact(currentMonthSpending()),
                icon: "cart.fill",
                color: CentmondTheme.Colors.negative
            )
            heroCard(
                label: "UNSETTLED",
                value: CurrencyFormat.compact(totalUnsettled()),
                icon: "exclamationmark.arrow.triangle.2.circlepath",
                color: totalUnsettled() > 0 ? CentmondTheme.Colors.warning : CentmondTheme.Colors.positive
            )
            heroCard(
                label: "OPEN SPLITS",
                value: "\(openSplitCount())",
                icon: "rectangle.split.3x1",
                color: CentmondTheme.Colors.textSecondary
            )
        }
    }

    private func heroCard(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)
                Text(value)
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: CentmondTheme.Spacing.xs) {
            ForEach(HubTab.allCases) { t in
                Button {
                    withAnimation(CentmondTheme.Motion.micro) { tab = t }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon)
                            .font(.system(size: 11))
                        Text(t.label)
                            .font(CentmondTheme.Typography.captionMedium)
                    }
                    .padding(.horizontal, CentmondTheme.Spacing.md)
                    .padding(.vertical, CentmondTheme.Spacing.xs + 2)
                    .background(tab == t ? CentmondTheme.Colors.bgSecondary : Color.clear)
                    .foregroundStyle(tab == t ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgTertiary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        ScrollView {
            VStack(spacing: CentmondTheme.Spacing.xxl) {
                if showAddMember, !allMembers.isEmpty {
                    addMemberForm(isFirstMember: false)
                }
                switch tab {
                case .overview:    overviewTab
                case .splits:      splitsTab
                case .settlements: settlementsTab
                case .members:     membersTab
                }
            }
            .padding(CentmondTheme.Spacing.xxl)
        }
    }

    // MARK: - Overview

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
            whoOwesWhoPanel
            memberCardsGrid
            recentActivity
        }
    }

    /// Debt-first block. Plain-English statements ("Ali owes you $25") with
    /// a Record Paid button + Nudge clipboard action on each row. Hidden
    /// when there are no open balances so the empty common case stays
    /// uncluttered.
    @ViewBuilder
    private var whoOwesWhoPanel: some View {
        let pairs = snapshot.pairBalances
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text("WHO OWES WHO")
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .tracking(0.5)
                    Spacer()
                    Text("\(pairs.count) open")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
                CardContainer {
                    VStack(spacing: CentmondTheme.Spacing.xs) {
                        ForEach(pairs) { pair in
                            debtRow(pair)
                            if pair.id != pairs.last?.id {
                                Divider().background(CentmondTheme.Colors.strokeSubtle)
                            }
                        }
                    }
                    .padding(.vertical, CentmondTheme.Spacing.xs)
                }
            }
        }
    }

    private func debtRow(_ pair: HouseholdService.PairBalance) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            Circle()
                .fill(Color(hex: pair.debtor.avatarColor))
                .frame(width: 28, height: 28)
                .overlay {
                    Text(String(pair.debtor.name.prefix(1)))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 1) {
                // Plain-English statement, payer→payee direction inverted
                // from the data-model direction so it reads naturally.
                (Text(pair.debtor.name).bold() +
                 Text(" owes ") +
                 Text(pair.creditor.name).bold())
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(CurrencyFormat.standard(pair.amount))
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(CentmondTheme.Colors.warning)
                    .monospacedDigit()
            }

            Spacer()

            Button {
                nudge(pair)
            } label: {
                Label("Nudge", systemImage: "paperplane")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .help("Copy a reminder message to your clipboard")

            Button {
                router.showSheet(.householdSettleUp)
            } label: {
                Label("Record Paid", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(AccentChipButtonStyle())
            .help("Log this payment — they already paid you")
        }
        .padding(.horizontal, CentmondTheme.Spacing.sm)
        .padding(.vertical, CentmondTheme.Spacing.xs)
    }

    /// Copies a templated reminder message to the clipboard so the user can
    /// paste it into Messages / Slack / email. No model state changes — this
    /// is explicitly a "poke your roommate" soft nudge, not a ledger write.
    private func nudge(_ pair: HouseholdService.PairBalance) {
        let msg = "Hey \(pair.debtor.name) — friendly reminder, you owe me \(CurrencyFormat.standard(pair.amount)) from our shared expenses. Send it over when you get a chance!"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(msg, forType: .string)
        Haptics.tap()
    }

    private var memberCardsGrid: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Text("MEMBER BREAKDOWN")
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg),
                GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg)
            ], spacing: CentmondTheme.Spacing.lg) {
                ForEach(members) { m in memberCard(m) }
            }
        }
    }

    private func memberCard(_ member: HouseholdMember) -> some View {
        let balance = memberBalance(member)
        return CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack(spacing: CentmondTheme.Spacing.md) {
                    Circle()
                        .fill(Color(hex: member.avatarColor))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Text(String(member.name.prefix(1)))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(member.name)
                                .font(CentmondTheme.Typography.heading3)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            if member.isOwner {
                                roleBadge("Owner", tint: CentmondTheme.Colors.accent)
                            }
                        }
                        if let email = member.email {
                            Text(email)
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                        Text("Joined \(member.joinedAt.formatted(.dateTime.month().year()))")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                    Spacer()
                }

                HStack(spacing: CentmondTheme.Spacing.lg) {
                    statPair(
                        label: "THIS MONTH",
                        value: CurrencyFormat.compact(monthlySpending(for: member)),
                        tint: CentmondTheme.Colors.negative
                    )
                    statPair(
                        label: "NET WORTH",
                        value: CurrencyFormat.compact(memberNetWorth(member)),
                        tint: CentmondTheme.Colors.accent
                    )
                    Spacer()
                    if balance != 0 {
                        statPair(
                            label: balance > 0 ? "OWED" : "OWES",
                            value: CurrencyFormat.compact(abs(balance)),
                            tint: balance > 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.warning
                        )
                    }
                }
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                memberToDelete = member
                showDeleteConfirmation = true
            } label: {
                Label("Delete Member", systemImage: "trash")
            }
            .disabled(member.isOwner && members.count == 1)
        }
    }

    private func roleBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(CentmondTheme.Typography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
    }

    private func statPair(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Text("RECENT ACTIVITY")
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            CardContainer {
                let recent = Array(transactions
                    .filter { $0.householdMember != nil }
                    .sorted(by: { $0.date > $1.date })
                    .prefix(15))
                if recent.isEmpty {
                    Text("No attributed activity yet")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .padding(.vertical, CentmondTheme.Spacing.lg)
                } else {
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                        ForEach(recent) { tx in activityRow(tx) }
                    }
                }
            }
        }
    }

    private func activityRow(_ tx: Transaction) -> some View {
        Button {
            // Guard against tombstoned snapshot references. The snapshot
            // array can hold a Transaction that was just deleted from
            // elsewhere; accessing `tx.id` on such a reference crashes
            // with SwiftData's "backing data could no longer be found"
            // fatal error. Skip silently — the next snapshot rebuild
            // will drop the row.
            guard tx.modelContext != nil, !tx.isDeleted else { return }
            // Open the transaction inspector sidebar — same entry point
            // TransactionsView uses. Gives the Household hub parity with
            // the ledger view so users can drill into any attributed row.
            router.inspectTransaction(tx.id)
        } label: {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Text(tx.date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 60, alignment: .leading)
                Text(tx.payee)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                if !tx.shares.isEmpty {
                    Text("split")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(CentmondTheme.Colors.bgTertiary)
                        .clipShape(Capsule())
                }
                Spacer()
                if let m = tx.householdMember {
                    Circle()
                        .fill(Color(hex: m.avatarColor))
                        .frame(width: 14, height: 14)
                        .overlay {
                            Text(String(m.name.prefix(1)))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .help(m.name)
                }
                Text(CurrencyFormat.compact(tx.amount))
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, CentmondTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHover)
    }

    // MARK: - Splits tab

    private var splitsTab: some View {
        let splitTxns = snapshot.splitTxns
        return VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Text("SHARED TRANSACTIONS (\(splitTxns.count))")
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            if splitTxns.isEmpty {
                emptyPanel(icon: "rectangle.split.3x1",
                           title: "Nothing is split yet",
                           body: "Open any transaction's inspector and tap 'Share' to split it across household members.")
            } else {
                CardContainer {
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        ForEach(splitTxns) { tx in splitRow(tx) }
                    }
                }
            }
        }
    }

    private func splitRow(_ tx: Transaction) -> some View {
        Button {
            router.showSheet(.shareTransaction(tx))
        } label: {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Text(tx.date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 60, alignment: .leading)
                Text(tx.payee)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: -6) {
                    ForEach(tx.shares.prefix(4)) { s in
                        if let m = s.member {
                            Circle()
                                .fill(Color(hex: m.avatarColor))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(CentmondTheme.Colors.bgSecondary, lineWidth: 1.5))
                                .help(m.name)
                        }
                    }
                }
                Text(CurrencyFormat.compact(tx.amount))
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 80, alignment: .trailing)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settlements tab

    private var settlementsTab: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
            balancesPanel
            settlementHistoryPanel
        }
    }

    private var balancesPanel: some View {
        let balances = snapshot.balances
        return VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack {
                Text("BALANCES")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)
                Spacer()
                Button {
                    router.showSheet(.householdSettleUp)
                } label: {
                    Label("Record Payment", systemImage: "arrow.left.arrow.right.circle")
                        .font(CentmondTheme.Typography.captionMedium)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(members.count < 2)
            }
            CardContainer {
                if balances.allSatisfy({ $0.amount == 0 }) {
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(CentmondTheme.Colors.positive)
                        Text("All balances are settled.")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    }
                    .padding(.vertical, CentmondTheme.Spacing.md)
                } else {
                    VStack(spacing: CentmondTheme.Spacing.xs) {
                        ForEach(balances, id: \.member.id) { b in
                            HStack {
                                Circle().fill(Color(hex: b.member.avatarColor)).frame(width: 10, height: 10)
                                Text(b.member.name)
                                    .font(CentmondTheme.Typography.body)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                Spacer()
                                Text(formatBalance(b.amount))
                                    .font(CentmondTheme.Typography.mono)
                                    .foregroundStyle(balanceTint(b.amount))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    private var settlementHistoryPanel: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Text("SETTLEMENT HISTORY (\(settlements.count))")
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            CardContainer {
                if settlements.isEmpty {
                    Text("No settlements yet.")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .padding(.vertical, CentmondTheme.Spacing.md)
                } else {
                    VStack(spacing: CentmondTheme.Spacing.xs) {
                        ForEach(settlements) { s in settlementRow(s) }
                    }
                }
            }
        }
    }

    private func settlementRow(_ s: HouseholdSettlement) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Text(s.date.formatted(.dateTime.month(.abbreviated).day().year()))
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 90, alignment: .leading)
            if let from = s.fromMember {
                Text(from.name)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            if let to = s.toMember {
                Text(to.name)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            if s.linkedTransaction != nil {
                Text("ledger")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(Capsule())
            }
            Spacer()
            Text(CurrencyFormat.compact(s.amount))
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Members tab

    private var membersTab: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xl) {
            memberCardsGrid
        }
    }

    // MARK: - Add member form

    private func addMemberForm(isFirstMember: Bool) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text(isFirstMember ? "Create Your Household" : "Add Member")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                if isFirstMember {
                    Text("Start by adding yourself as the household owner.")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }
                TextField("Name", text: $newMemberName)
                    .textFieldStyle(.roundedBorder)
                TextField("Email (optional)", text: $newMemberEmail)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button {
                        guard !newMemberName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        let member = HouseholdMember(
                            name: newMemberName.trimmingCharacters(in: .whitespaces),
                            email: newMemberEmail.isEmpty ? nil : newMemberEmail.trimmingCharacters(in: .whitespaces),
                            avatarColor: avatarColors[members.count % avatarColors.count],
                            isOwner: members.isEmpty
                        )
                        modelContext.insert(member)
                        newMemberName = ""
                        newMemberEmail = ""
                        showAddMember = false
                    } label: {
                        Text(isFirstMember ? "Create" : "Add").frame(width: 80)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(newMemberName.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !isFirstMember {
                        Button("Cancel") {
                            showAddMember = false
                            newMemberName = ""
                            newMemberEmail = ""
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
    }

    private func emptyPanel(icon: String, title: String, body: String) -> some View {
        CardContainer {
            VStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Text(title)
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(body)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(CentmondTheme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    private func currentMonthSpending() -> Decimal { snapshot.currentMonthSpending }

    private func monthlySpending(for member: HouseholdMember) -> Decimal {
        snapshot.monthSpendingByMemberID[member.id] ?? 0
    }

    private func memberBalance(_ m: HouseholdMember) -> Decimal {
        snapshot.balanceByMemberID[m.id] ?? 0
    }

    private func memberNetWorth(_ m: HouseholdMember) -> Decimal {
        snapshot.netWorthByMemberID[m.id] ?? 0
    }

    private func totalUnsettled() -> Decimal { snapshot.totalUnsettled }

    private func openSplitCount() -> Int { snapshot.openSplitCount }

    private func formatBalance(_ v: Decimal) -> String {
        if v > 0 { return "+\(CurrencyFormat.compact(v))" }
        if v < 0 { return "-\(CurrencyFormat.compact(-v))" }
        return CurrencyFormat.compact(0)
    }
    private func balanceTint(_ v: Decimal) -> Color {
        if v > 0 { return CentmondTheme.Colors.positive }
        if v < 0 { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.textSecondary
    }
}
