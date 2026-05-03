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
    /// "Join with Code" alert — visible for parity with iOS empty state,
    /// but the macOS app has no auth identity yet so the action explains
    /// the gap instead of pretending it works. Wired up when the macOS
    /// Cloud Port (project_macos_cloud_port) lands sign-in.
    @State private var showJoinComingSoon = false

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
        for m in liveMembers where m.isActive {
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
        next.openSplitCount = liveShares.filter { $0.status == .owed }.count
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

    /// Tombstone-safe view of the @Query arrays. Cloud-prune deletes
    /// (when iOS removes a household entity) leave detached SwiftData
    /// instances in the array for one frame; reading any persisted
    /// attribute on them faults with "This backing data was detached
    /// from a context …". Filter once, use everywhere.
    private var liveMembers: [HouseholdMember] {
        allMembers.filter { $0.modelContext != nil && !$0.isDeleted }
    }
    private var liveSettlements: [HouseholdSettlement] {
        settlements.filter { $0.modelContext != nil && !$0.isDeleted }
    }
    private var liveShares: [ExpenseShare] {
        shares.filter { $0.modelContext != nil && !$0.isDeleted }
    }

    private var members: [HouseholdMember] { liveMembers.filter(\.isActive) }
    private var archivedMembers: [HouseholdMember] { liveMembers.filter { !$0.isActive } }

    var body: some View {
        Group {
            if liveMembers.isEmpty {
                emptySetup
            } else {
                VStack(spacing: 0) {
                    SectionTutorialStrip(screen: .household)
                        .padding(.horizontal, CentmondTheme.Spacing.lg)
                        .padding(.top, CentmondTheme.Spacing.sm)
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
                    modelContext.persist()
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

    /// Native-mac iOS-feel empty state: icon + heading + description on top,
    /// inline name/email form in a card below. The form stays inline (vs
    /// iOS's separate sheet step) because keyboard-and-mouse desktop flows
    /// punish extra clicks.
    private var emptySetupCard: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            VStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.accent.opacity(0.7))
                    .frame(width: 72, height: 72)
                    .background(CentmondTheme.Colors.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))

                Text("Shared Finance")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                Text("Manage money together with your partner.\nSplit expenses, share budgets, and settle up.")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, CentmondTheme.Spacing.md)

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
                        Label("Create Household", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(newMemberName.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button {
                        showJoinComingSoon = true
                    } label: {
                        Text("Join with Code")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .padding(.top, 2)
                }
                .padding(CentmondTheme.Spacing.lg)
                .frame(maxWidth: .infinity)
            }
        }
        .alert("Sign-in required", isPresented: $showJoinComingSoon) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Joining a household via code needs cross-device sign-in, which isn't wired up on macOS yet. For now, you can create a household here and manage members locally.")
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

    // MARK: - Header (lean iOS-style)
    //
    // Replaces the legacy 4-card hero metric strip. iOS keeps its header
    // light (name + member chips + avatars) and pushes balance/spending
    // into a separate Balance Summary card below; this header now does
    // the same. The 4 metric cards moved to the top of the Overview tab
    // (`overviewTab` body) so the data isn't lost — just relocated.

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack(alignment: .center, spacing: CentmondTheme.Spacing.md) {
                Text("Household")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text("\(members.count) member\(members.count == 1 ? "" : "s")")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)

                Spacer()

                avatarRow

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
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    /// Overlapping circle avatars, max 3 + "+N" pill. iOS dashboard card uses
    /// the same pattern.
    private var avatarRow: some View {
        HStack(spacing: -8) {
            ForEach(members.prefix(3)) { m in
                Text(String(m.name.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color(hex: m.avatarColor), in: Circle())
                    .overlay(Circle().stroke(CentmondTheme.Colors.bgSecondary, lineWidth: 2))
            }
            if members.count > 3 {
                Text("+\(members.count - 3)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(CentmondTheme.Colors.bgTertiary, in: Circle())
                    .overlay(Circle().stroke(CentmondTheme.Colors.bgSecondary, lineWidth: 2))
            }
        }
    }

    /// iOS-style balance hero card. Replaces the legacy 4-card metric grid.
    /// One big primary line (your net balance state), one secondary metric
    /// (this month's shared spending), and small chips for the housekeeping
    /// counts. "You" = the owner member on macOS (no auth-identity yet).
    private var balanceHero: some View {
        let owner = members.first(where: { $0.isOwner }) ?? members.first
        let yourNet: Decimal = owner.flatMap { snapshot.balanceByMemberID[$0.id] } ?? 0
        let unsettled = snapshot.totalUnsettled
        let openSplits = snapshot.openSplitCount
        let monthSpend = snapshot.currentMonthSpending
        let isSolo = members.count <= 1

        return CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {

                // Primary line — the big iOS-style balance statement.
                HStack(alignment: .firstTextBaseline, spacing: CentmondTheme.Spacing.md) {
                    if isSolo {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Solo household")
                                .font(CentmondTheme.Typography.heading2)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            Text("Invite someone to start splitting")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    } else if yourNet > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Owed to you")
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .tracking(0.3)
                            Text(CurrencyFormat.standard(yourNet))
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(CentmondTheme.Colors.positive)
                                .monospacedDigit()
                        }
                    } else if yourNet < 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("You owe")
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .tracking(0.3)
                            Text(CurrencyFormat.standard(abs(yourNet)))
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(CentmondTheme.Colors.warning)
                                .monospacedDigit()
                        }
                    } else {
                        HStack(spacing: CentmondTheme.Spacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(CentmondTheme.Colors.positive)
                            Text("All settled")
                                .font(CentmondTheme.Typography.heading2)
                                .foregroundStyle(CentmondTheme.Colors.positive)
                        }
                    }

                    Spacer()

                    if monthSpend > 0 {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("THIS MONTH")
                                .font(CentmondTheme.Typography.overline)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .tracking(0.5)
                            Text(CurrencyFormat.standard(monthSpend))
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }
                }

                // Secondary chips row — only render when there's something to say.
                if !isSolo && (unsettled > 0 || openSplits > 0) {
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        if unsettled > 0 {
                            heroChip(
                                icon: "exclamationmark.arrow.triangle.2.circlepath",
                                text: "\(CurrencyFormat.compact(unsettled)) unsettled",
                                tint: CentmondTheme.Colors.warning
                            )
                        }
                        if openSplits > 0 {
                            heroChip(
                                icon: "rectangle.split.3x1",
                                text: "\(openSplits) open split\(openSplits == 1 ? "" : "s")",
                                tint: CentmondTheme.Colors.accent
                            )
                        }
                        Spacer()
                    }
                }
            }
            .padding(CentmondTheme.Spacing.lg)
        }
    }

    private func heroChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(CentmondTheme.Typography.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
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
                            .font(CentmondTheme.Typography.captionSmall)
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
            balanceHero
            whoOwesWhoPanel
            memberRowsList
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
                        .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
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

    /// iOS-style member rows. One row per member: avatar + name + role
    /// badge on the left, single primary spending number on the right, and
    /// a muted "owes" / "owed" / "even" sub-line under the name. Replaces
    /// the legacy 2-column grid of cards with stacked stat columns
    /// ("THIS MONTH" + "NET WORTH" + "OWED") that read like a database
    /// table.
    private var memberRowsList: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack {
                Text("MEMBERS")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)
                Spacer()
                Text("\(members.count)")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
            CardContainer {
                VStack(spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { idx, m in
                        memberRow(m)
                        if idx != members.count - 1 {
                            Divider().background(CentmondTheme.Colors.strokeSubtle)
                        }
                    }
                }
                .padding(.vertical, CentmondTheme.Spacing.xs)
            }
        }
    }

    private func memberRow(_ member: HouseholdMember) -> some View {
        let balance = memberBalance(member)
        let monthSpend = monthlySpending(for: member)
        return HStack(spacing: CentmondTheme.Spacing.md) {
            Circle()
                .fill(Color(hex: member.avatarColor))
                .frame(width: 36, height: 36)
                .overlay {
                    Text(String(member.name.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name)
                        .font(CentmondTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    if member.isOwner {
                        roleBadge("Owner", tint: CentmondTheme.Colors.accent)
                    }
                }
                // Sub-line: net debt status in plain English. Mirrors iOS
                // "you owe / owed to you / all settled" pattern at row level.
                if balance > 0 {
                    Text("Owed \(CurrencyFormat.compact(balance))")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.positive)
                } else if balance < 0 {
                    Text("Owes \(CurrencyFormat.compact(abs(balance)))")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.warning)
                } else {
                    Text("All settled")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }

            Spacer()

            // Primary number: this month's spending, like iOS shows
            // "Anna · €240" with the amount as the dominant right-side glyph.
            VStack(alignment: .trailing, spacing: 2) {
                Text(CurrencyFormat.standard(monthSpend))
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(monthSpend > 0 ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textTertiary)
                    .monospacedDigit()
                Text("this month")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .contentShape(Rectangle())
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

    private var recentActivity: some View {
        let recent = Array(transactions
            .filter { $0.householdMember != nil }
            .sorted(by: { $0.date > $1.date })
            .prefix(15))
        return VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack {
                Text("RECENT ACTIVITY")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)
                Spacer()
                if !recent.isEmpty {
                    Text("\(recent.count)")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
            CardContainer {
                if recent.isEmpty {
                    // iOS-style empty state — icon + title + subtitle inside
                    // the card so the card has presence, not just a thin
                    // strip of grey text.
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "tray")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        Text("No shared activity yet")
                            .font(CentmondTheme.Typography.body.weight(.semibold))
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        Text("Transactions you attribute to a member show up here.")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CentmondTheme.Spacing.xl)
                } else {
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                        ForEach(recent) { tx in activityRow(tx) }
                    }
                    .padding(.vertical, CentmondTheme.Spacing.xs)
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
                                .font(CentmondTheme.Typography.microBold.weight(.semibold))
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
                    // Filter tombstoned shares before reading .member —
                    // cloud-prune may have detached one mid-frame.
                    let liveTxShares = tx.shares
                        .filter { $0.modelContext != nil && !$0.isDeleted }
                        .prefix(4)
                    ForEach(Array(liveTxShares)) { s in
                        if let m = s.member,
                           m.modelContext != nil, !m.isDeleted {
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
            Text("SETTLEMENT HISTORY (\(liveSettlements.count))")
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            CardContainer {
                if liveSettlements.isEmpty {
                    Text("No settlements yet.")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .padding(.vertical, CentmondTheme.Spacing.md)
                } else {
                    VStack(spacing: CentmondTheme.Spacing.xs) {
                        // Iterate live array — settlementRow reads
                        // .amount/.date/.fromMember/.toMember which would
                        // fault on a tombstoned HouseholdSettlement.
                        ForEach(liveSettlements) { s in settlementRow(s) }
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
                .font(CentmondTheme.Typography.overlineRegular)
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
            memberRowsList
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
