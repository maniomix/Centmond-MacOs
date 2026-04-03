import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var showDeleteConfirmation = false
    @State private var accountToDelete: Account?
    @State private var showArchived = false

    private var activeAccounts: [Account] {
        accounts.filter { !$0.isArchived }
    }

    private var archivedAccounts: [Account] {
        accounts.filter { $0.isArchived }
    }

    private var totalAssets: Decimal {
        activeAccounts
            .filter { $0.type != .creditCard }
            .reduce(0) { $0 + $1.currentBalance }
    }

    private var totalLiabilities: Decimal {
        activeAccounts
            .filter { $0.type == .creditCard }
            .reduce(0) { $0 + abs($1.currentBalance) }
    }

    private var groupedAccounts: [(AccountType, [Account])] {
        let groups = Dictionary(grouping: activeAccounts, by: \.type)
        return AccountType.allCases.compactMap { type in
            guard let accts = groups[type], !accts.isEmpty else { return nil }
            return (type, accts.sorted { $0.sortOrder < $1.sortOrder })
        }
    }

    private var selectedAccountID: UUID? {
        if case .account(let id) = router.inspectorContext { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if activeAccounts.isEmpty && archivedAccounts.isEmpty {
                EmptyStateView(
                    icon: "building.columns",
                    heading: "No accounts yet",
                    description: "Add your bank accounts, credit cards, and other financial accounts to start tracking your finances.",
                    primaryAction: "Add Account",
                    onPrimaryAction: { router.showSheet(.newAccount) }
                )
            } else {
                accountsSummary

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                ScrollView {
                    VStack(spacing: CentmondTheme.Spacing.xxl) {
                        ForEach(groupedAccounts, id: \.0) { type, accts in
                            accountGroup(type: type, accounts: accts)
                        }

                        if activeAccounts.isEmpty {
                            VStack(spacing: CentmondTheme.Spacing.md) {
                                Text("All accounts are archived")
                                    .font(CentmondTheme.Typography.body)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)

                                Button("Add Account") {
                                    router.showSheet(.newAccount)
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CentmondTheme.Spacing.huge)
                        }

                        if !archivedAccounts.isEmpty {
                            archivedSection
                        }
                    }
                    .padding(CentmondTheme.Spacing.xxl)
                }
            }
        }
        .alert("Delete Account", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { accountToDelete = nil }
            Button("Delete", role: .destructive) {
                if let account = accountToDelete {
                    if case .account(let id) = router.inspectorContext, id == account.id {
                        router.inspectorContext = .none
                    }
                    // Unlink transactions before deleting
                    for tx in account.transactions {
                        tx.account = nil
                    }
                    modelContext.delete(account)
                }
                accountToDelete = nil
            }
        } message: {
            if let account = accountToDelete {
                let txCount = account.transactions.count
                if txCount > 0 {
                    Text("This will permanently delete \"\(account.name)\" and unlink \(txCount) transaction\(txCount == 1 ? "" : "s"). Consider archiving instead. This cannot be undone.")
                } else {
                    Text("This will permanently delete \"\(account.name)\". This cannot be undone.")
                }
            } else {
                Text("This will permanently delete this account.")
            }
        }
    }

    // MARK: - Summary

    private var accountsSummary: some View {
        HStack(spacing: CentmondTheme.Spacing.xxxl) {
            summaryItem("Total Assets", value: CurrencyFormat.standard(totalAssets), color: CentmondTheme.Colors.positive)
            summaryItem("Total Liabilities", value: CurrencyFormat.standard(totalLiabilities), color: CentmondTheme.Colors.negative)

            let netWorth = totalAssets - totalLiabilities
            summaryItem("Net Worth", value: CurrencyFormat.standard(netWorth),
                         color: netWorth >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)

            Spacer()

            Text("\(activeAccounts.count) account\(activeAccounts.count == 1 ? "" : "s")")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)

            Button {
                router.showSheet(.newAccount)
            } label: {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Add Account")
                        .font(CentmondTheme.Typography.captionMedium)
                }
                .foregroundStyle(CentmondTheme.Colors.accent)
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .padding(.vertical, CentmondTheme.Spacing.sm)
                .background(CentmondTheme.Colors.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
    }

    private func summaryItem(_ label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)

            Text(value)
                .font(CentmondTheme.Typography.monoLarge)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    // MARK: - Account Group

    private func accountGroup(type: AccountType, accounts: [Account]) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack {
                Text(type.displayName.uppercased())
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)

                Spacer()

                let groupTotal = accounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
                Text(CurrencyFormat.standard(groupTotal))
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .monospacedDigit()
            }

            VStack(spacing: CentmondTheme.Spacing.sm) {
                ForEach(accounts) { account in
                    AccountCardView(
                        account: account,
                        isSelected: selectedAccountID == account.id,
                        onTap: { router.inspectAccount(account.id) },
                        onArchive: { archiveAccount(account) },
                        onDelete: {
                            accountToDelete = account
                            showDeleteConfirmation = true
                        }
                    )
                }
            }
        }
    }

    // MARK: - Archived Section

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Button {
                withAnimation(CentmondTheme.Motion.layout) {
                    showArchived.toggle()
                }
            } label: {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Archived (\(archivedAccounts.count))")
                        .font(CentmondTheme.Typography.captionMedium)
                }
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .textCase(.uppercase)
            }
            .buttonStyle(.plain)

            if showArchived {
                VStack(spacing: CentmondTheme.Spacing.sm) {
                    ForEach(archivedAccounts) { account in
                        AccountCardView(
                            account: account,
                            isSelected: false,
                            isArchived: true,
                            onTap: { router.inspectAccount(account.id) },
                            onUnarchive: { account.isArchived = false },
                            onDelete: {
                                accountToDelete = account
                                showDeleteConfirmation = true
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func archiveAccount(_ account: Account) {
        withAnimation(CentmondTheme.Motion.layout) {
            account.isArchived = true
            if case .account(let id) = router.inspectorContext, id == account.id {
                router.inspectorContext = .none
            }
        }
    }
}

// MARK: - Account Card

private struct AccountCardView: View {
    let account: Account
    var isSelected: Bool = false
    var isArchived: Bool = false
    var onTap: () -> Void = {}
    var onArchive: (() -> Void)?
    var onUnarchive: (() -> Void)?
    var onDelete: (() -> Void)?

    @State private var isHovered = false

    private var balanceColor: Color {
        if account.type == .creditCard {
            return account.currentBalance > 0 ? CentmondTheme.Colors.negative : CentmondTheme.Colors.positive
        }
        return account.currentBalance >= 0 ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.negative
    }

    var body: some View {
        HStack {
            HStack(spacing: CentmondTheme.Spacing.md) {
                Image(systemName: account.type.iconName)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(isSelected ? CentmondTheme.Colors.accentMuted : CentmondTheme.Colors.bgQuaternary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        if let institution = account.institutionName, !institution.isEmpty {
                            Text(institution)
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                        if let digits = account.lastFourDigits, !digits.isEmpty {
                            Text("•••• \(digits)")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(CurrencyFormat.standard(account.currentBalance))
                    .font(CentmondTheme.Typography.monoLarge)
                    .foregroundStyle(balanceColor)
                    .monospacedDigit()

                Text("\(account.transactions.count) txns")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
        }
        .padding(CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(
                    isSelected ? CentmondTheme.Colors.accent :
                    isHovered ? CentmondTheme.Colors.strokeDefault : CentmondTheme.Colors.strokeSubtle,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .opacity(isArchived ? 0.6 : 1)
        .shadow(color: isHovered && !isArchived ? .black.opacity(0.2) : .clear, radius: 6, y: 2)
        .onHover { hovering in
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
        .onTapGesture { onTap() }
        .contextMenu {
            if isArchived {
                if let onUnarchive {
                    Button {
                        onUnarchive()
                    } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                }
                Divider()
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                }
            } else {
                Button {
                    onTap()
                } label: {
                    Label("View Details", systemImage: "eye")
                }
                Divider()
                if let onArchive {
                    Button {
                        onArchive()
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
                Divider()
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
}
