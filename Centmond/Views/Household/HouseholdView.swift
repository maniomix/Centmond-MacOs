import SwiftUI
import SwiftData

struct HouseholdView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HouseholdMember.joinedAt) private var members: [HouseholdMember]
    @Query private var transactions: [Transaction]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var viewMode: ViewMode = .combined
    @State private var showAddMember = false
    @State private var newMemberName = ""
    @State private var newMemberEmail = ""
    @State private var memberToDelete: HouseholdMember?
    @State private var showDeleteConfirmation = false

    enum ViewMode: Hashable {
        case combined
        case member(UUID)
    }

    private let avatarColors = ["3B82F6", "8B5CF6", "EC4899", "F97316", "22C55E", "EF4444", "06B6D4", "F59E0B"]

    var body: some View {
        Group {
            if members.isEmpty {
                emptySetup
            } else {
                VStack(spacing: 0) {
                    headerBar
                    householdContent
                }
            }
        }
        .alert("Remove Member?", isPresented: $showDeleteConfirmation) {
            Button("Remove", role: .destructive) {
                if let member = memberToDelete {
                    modelContext.delete(member)
                    if case .member(let id) = viewMode, id == member.id {
                        viewMode = .combined
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let member = memberToDelete {
                Text("Remove \"\(member.name)\" from the household?")
            }
        }
    }

    // MARK: - Empty Setup

    private var emptySetup: some View {
        VStack(spacing: CentmondTheme.Spacing.xxl) {
            EmptyStateView(
                icon: "person.2.fill",
                heading: "No household set up",
                description: "Create a local household to label transactions by family member and see per-person spending.",
                primaryAction: "Create Household",
                onPrimaryAction: { showAddMember = true }
            )

            if showAddMember {
                addMemberForm(isFirstMember: true)
                    .frame(maxWidth: 400)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: CentmondTheme.Spacing.lg) {
            Text("Household")
                .font(CentmondTheme.Typography.heading2)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            // Member avatars
            HStack(spacing: -8) {
                ForEach(members) { member in
                    Button {
                        withAnimation(CentmondTheme.Motion.micro) {
                            if case .member(let id) = viewMode, id == member.id {
                                viewMode = .combined
                            } else {
                                viewMode = .member(member.id)
                            }
                        }
                    } label: {
                        Circle()
                            .fill(Color(hex: member.avatarColor))
                            .frame(width: 32, height: 32)
                            .overlay {
                                Text(String(member.name.prefix(1)))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .overlay(
                                Circle()
                                    .stroke(
                                        isSelected(member) ? CentmondTheme.Colors.accent : CentmondTheme.Colors.bgSecondary,
                                        lineWidth: isSelected(member) ? 3 : 2
                                    )
                            )
                    }
                    .buttonStyle(.plainHover)
                    .help(member.name)
                }
            }

            Spacer()

            // View toggle
            Picker("View", selection: $viewMode) {
                Text("Combined").tag(ViewMode.combined)
                ForEach(members) { member in
                    Text(member.name).tag(ViewMode.member(member.id))
                }
            }
            .pickerStyle(.segmented)
            .frame(width: CGFloat(min(members.count + 1, 5)) * 100)

            Button {
                showAddMember.toggle()
                newMemberName = ""
                newMemberEmail = ""
            } label: {
                Label("Add Member", systemImage: "person.badge.plus")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    private func isSelected(_ member: HouseholdMember) -> Bool {
        if case .member(let id) = viewMode { return id == member.id }
        return false
    }

    // MARK: - Content

    private var householdContent: some View {
        ScrollView {
            VStack(spacing: CentmondTheme.Spacing.xxl) {
                if showAddMember {
                    addMemberForm(isFirstMember: false)
                }

                combinedStats
                memberCards
                activityFeed
            }
            .padding(CentmondTheme.Spacing.xxl)
        }
    }

    // MARK: - Scoped data

    /// Transactions visible under the current viewMode. Combined returns
    /// everything; member returns only that member's attributed rows.
    /// Transfer legs are kept here — the spending/income filters below
    /// strip them so balance math stays correct.
    private var scopedTransactions: [Transaction] {
        switch viewMode {
        case .combined:
            return transactions
        case .member(let id):
            return transactions.filter { $0.householdMember?.id == id }
        }
    }

    private var selectedMember: HouseholdMember? {
        if case .member(let id) = viewMode {
            return members.first { $0.id == id }
        }
        return nil
    }

    // MARK: - Add Member Form

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
                        Text(isFirstMember ? "Create" : "Add")
                            .frame(width: 80)
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

    // MARK: - Combined Stats

    private var combinedStats: some View {
        HStack(spacing: CentmondTheme.Spacing.xl) {
            let activeAccounts = accounts.filter { !$0.isArchived }
            let balance = activeAccounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
            let spending = currentMonthSpending()
            let isMemberView = selectedMember != nil

            // Total balance is household-wide even in member view — accounts
            // are not owned by individuals in this schema, so showing a
            // member-scoped balance would be misleading.
            statCard(
                label: "Total Balance",
                value: CurrencyFormat.compact(balance),
                icon: "building.columns.fill",
                color: CentmondTheme.Colors.accent
            )
            statCard(
                label: isMemberView ? "\(selectedMember?.name ?? "")'s Spending" : "This Month's Spending",
                value: CurrencyFormat.compact(spending),
                icon: "cart.fill",
                color: CentmondTheme.Colors.negative
            )
            statCard(
                label: isMemberView ? "Transactions" : "Members",
                value: isMemberView ? "\(scopedTransactions.count)" : "\(members.count)",
                icon: isMemberView ? "list.bullet" : "person.2.fill",
                color: CentmondTheme.Colors.positive
            )

            if !isMemberView, members.count > 1 {
                let perPerson = members.count > 0 ? spending / Decimal(members.count) : 0
                statCard(
                    label: "Avg per Person",
                    value: CurrencyFormat.compact(perPerson),
                    icon: "person.fill",
                    color: CentmondTheme.Colors.warning
                )
            } else {
                statCard(
                    label: "Accounts",
                    value: "\(accounts.filter { !$0.isArchived }.count)",
                    icon: "banknote.fill",
                    color: CentmondTheme.Colors.warning
                )
            }
        }
    }

    private func statCard(label: String, value: String, icon: String, color: Color) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text(label.uppercased())
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .tracking(0.5)

                    Spacer()

                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(color)
                        .frame(width: 28, height: 28)
                        .background(color.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                }

                Text(value)
                    .font(CentmondTheme.Typography.monoLarge)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Member Cards

    private var memberCards: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Text("MEMBERS")
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg),
                GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg)
            ], spacing: CentmondTheme.Spacing.lg) {
                ForEach(members) { member in
                    memberCard(member)
                }
            }
        }
    }

    private func memberCard(_ member: HouseholdMember) -> some View {
        let selected = isSelected(member)
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
                                Text("Owner")
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(CentmondTheme.Colors.accent.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
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

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("THIS MONTH")
                            .font(CentmondTheme.Typography.overline)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.5)
                        Text(CurrencyFormat.compact(monthlySpending(for: member)))
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(selected ? CentmondTheme.Colors.accent : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(CentmondTheme.Motion.micro) {
                viewMode = .member(member.id)
            }
        }
        .contextMenu {
            Button {
                viewMode = .member(member.id)
            } label: {
                Label("View \(member.name)'s Activity", systemImage: "person.fill")
            }
            if !member.isOwner {
                Divider()
                Button(role: .destructive) {
                    memberToDelete = member
                    showDeleteConfirmation = true
                } label: {
                    Label("Remove from Household", systemImage: "person.badge.minus")
                }
            }
        }
    }

    // MARK: - Activity Feed

    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack {
                Text("RECENT ACTIVITY")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)
                if let member = selectedMember {
                    Text("· \(member.name)")
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                }
            }

            CardContainer {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    if scopedTransactions.isEmpty {
                        Text(selectedMember == nil
                             ? "No recent activity"
                             : "Nothing attributed to \(selectedMember?.name ?? "this member") yet")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .padding(.vertical, CentmondTheme.Spacing.lg)
                    } else {
                        let recent = Array(scopedTransactions.sorted(by: { $0.date > $1.date }).prefix(15))
                        ForEach(recent) { tx in
                            HStack(spacing: CentmondTheme.Spacing.sm) {
                                Circle()
                                    .fill(tx.isIncome ? CentmondTheme.Colors.positive.opacity(0.3) : CentmondTheme.Colors.accent.opacity(0.2))
                                    .frame(width: 6, height: 6)

                                Text(tx.date.formatted(.dateTime.month(.abbreviated).day()))
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .frame(width: 60, alignment: .leading)

                                Text(tx.payee)
                                    .font(CentmondTheme.Typography.body)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                    .lineLimit(1)

                                if let cat = tx.category {
                                    Text(cat.name)
                                        .font(CentmondTheme.Typography.caption)
                                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                }

                                if selectedMember == nil, let member = tx.householdMember {
                                    Circle()
                                        .fill(Color(hex: member.avatarColor))
                                        .frame(width: 14, height: 14)
                                        .overlay {
                                            Text(String(member.name.prefix(1)))
                                                .font(.system(size: 8, weight: .semibold))
                                                .foregroundStyle(.white)
                                        }
                                        .help(member.name)
                                }

                                Spacer()

                                Text(CurrencyFormat.compact(tx.amount))
                                    .font(CentmondTheme.Typography.mono)
                                    .foregroundStyle(tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, CentmondTheme.Spacing.xs)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Spending for the current calendar month, scoped to the active
    /// viewMode. Uses `BalanceService.isSpendingExpense` so transfer legs
    /// are excluded — counting them would double-bill the household every
    /// time money moved between accounts.
    private func monthlySpending(for member: HouseholdMember) -> Decimal {
        let calendar = Calendar.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: .now))!
        return transactions
            .filter {
                $0.householdMember?.id == member.id
                && $0.date >= startOfMonth
                && BalanceService.isSpendingExpense($0)
            }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func currentMonthSpending() -> Decimal {
        let calendar = Calendar.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: .now))!
        return scopedTransactions
            .filter { $0.date >= startOfMonth && BalanceService.isSpendingExpense($0) }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

}
