import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var showDeleteConfirmation = false
    @State private var accountToDelete: Account?
    @State private var showArchived = false
    @State private var searchText = ""
    @State private var filterType: AccountType?
    @State private var filterStatus: AccountStatusFilter = .active
    @State private var sortOption: AccountSortOption = .custom
    @State private var showCloseConfirmation = false
    @State private var accountToClose: Account?

    // MARK: - Filters

    enum AccountStatusFilter: String, CaseIterable {
        case active = "Active"
        case closed = "Closed"
        case all = "All"
    }

    enum AccountSortOption: String, CaseIterable {
        case custom = "Custom"
        case name = "Name"
        case balance = "Balance"
        case type = "Type"
        case recent = "Recent"
    }

    private var filteredAccounts: [Account] {
        var result = accounts

        // Status filter
        switch filterStatus {
        case .active:
            result = result.filter { !$0.isArchived && !$0.isClosed }
        case .closed:
            result = result.filter { $0.isClosed }
        case .all:
            result = result.filter { !$0.isArchived }
        }

        // Type filter
        if let filterType {
            result = result.filter { $0.type == filterType }
        }

        // Search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query)
                || ($0.institutionName?.lowercased().contains(query) ?? false)
                || ($0.lastFourDigits?.contains(query) ?? false)
                || ($0.notes?.lowercased().contains(query) ?? false)
            }
        }

        // Sort
        switch sortOption {
        case .custom:
            result.sort { $0.sortOrder < $1.sortOrder }
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .balance:
            result.sort { $0.currentBalance > $1.currentBalance }
        case .type:
            result.sort {
                if $0.type == $1.type { return $0.sortOrder < $1.sortOrder }
                return $0.type.rawValue < $1.type.rawValue
            }
        case .recent:
            result.sort { $0.createdAt > $1.createdAt }
        }

        return result
    }

    private var activeAccounts: [Account] {
        accounts.filter { !$0.isArchived && !$0.isClosed }
    }

    private var archivedAccounts: [Account] {
        accounts.filter { $0.isArchived }
    }

    private var groupedAccounts: [(AccountType, [Account])] {
        let groups = Dictionary(grouping: filteredAccounts, by: \.type)
        return AccountType.allCases.compactMap { type in
            guard let accts = groups[type], !accts.isEmpty else { return nil }
            return (type, accts)
        }
    }

    private var totalAssets: Decimal {
        activeAccounts
            .filter { $0.type != .creditCard && $0.includeInNetWorth }
            .reduce(0) { $0 + $1.currentBalance }
    }

    private var totalLiabilities: Decimal {
        activeAccounts
            .filter { $0.type == .creditCard && $0.includeInNetWorth }
            .reduce(0) { $0 + abs($1.currentBalance) }
    }

    private var selectedAccountID: UUID? {
        if case .account(let id) = router.inspectorContext { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if accounts.isEmpty {
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

                // Toolbar: Search + Filters + Sort
                accountsToolbar

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                ScrollView {
                    VStack(spacing: CentmondTheme.Spacing.xxl) {
                        if filteredAccounts.isEmpty {
                            VStack(spacing: CentmondTheme.Spacing.md) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 28))
                                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                Text("No accounts match your filters")
                                    .font(CentmondTheme.Typography.body)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                Button("Clear Filters") {
                                    searchText = ""
                                    filterType = nil
                                    filterStatus = .active
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CentmondTheme.Spacing.huge)
                        } else if sortOption == .type || sortOption == .custom {
                            ForEach(groupedAccounts, id: \.0) { type, accts in
                                accountGroup(type: type, accounts: accts)
                            }
                        } else {
                            // Flat list when sorting by name/balance/recent
                            VStack(spacing: CentmondTheme.Spacing.sm) {
                                ForEach(filteredAccounts) { account in
                                    AccountCardView(
                                        account: account,
                                        isSelected: selectedAccountID == account.id,
                                        onTap: { router.inspectAccount(account.id) },
                                        onEdit: { router.showSheet(.editAccount(account)) },
                                        onArchive: { archiveAccount(account) },
                                        onClose: {
                                            accountToClose = account
                                            showCloseConfirmation = true
                                        },
                                        onDuplicate: { duplicateAccount(account) },
                                        onDelete: {
                                            accountToDelete = account
                                            showDeleteConfirmation = true
                                        }
                                    )
                                }
                            }
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
                    deleteAccount(account)
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
        .alert("Close Account", isPresented: $showCloseConfirmation) {
            Button("Cancel", role: .cancel) { accountToClose = nil }
            Button("Close Account", role: .destructive) {
                if let account = accountToClose {
                    closeAccount(account)
                }
                accountToClose = nil
            }
        } message: {
            if let account = accountToClose {
                Text("Closing \"\(account.name)\" will mark it as inactive. It will remain visible but won't count toward budgets or net worth. You can reopen it later.")
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
                Label("Add Account", systemImage: "plus")
            }
            .buttonStyle(AccentChipButtonStyle())
            .help("Add a new bank account")
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

    // MARK: - Toolbar

    private var accountsToolbar: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            // Search
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                TextField("Search accounts…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, CentmondTheme.Spacing.sm)
            .frame(height: 28)
            .background(CentmondTheme.Colors.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
            )
            .frame(maxWidth: 220)

            Divider()
                .frame(height: 18)

            // Type filter
            Picker("Type", selection: $filterType) {
                Text("All Types").tag(AccountType?.none)
                Divider()
                ForEach(AccountType.allCases) { type in
                    Label(type.displayName, systemImage: type.iconName)
                        .tag(AccountType?.some(type))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 120)
            .help("Filter by account type")

            // Status filter
            Picker("Status", selection: $filterStatus) {
                ForEach(AccountStatusFilter.allCases, id: \.self) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .help("Filter by account status")

            Spacer()

            // Sort
            Picker("Sort", selection: $sortOption) {
                ForEach(AccountSortOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .help("Change sort order")
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgPrimary)
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
                        onEdit: { router.showSheet(.editAccount(account)) },
                        onArchive: { archiveAccount(account) },
                        onClose: {
                            accountToClose = account
                            showCloseConfirmation = true
                        },
                        onDuplicate: { duplicateAccount(account) },
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
            .buttonStyle(.plainHover)
            .help(showArchived ? "Hide archived accounts" : "Show archived accounts")

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
        Haptics.tap()
        withAnimation(CentmondTheme.Motion.layout) {
            account.isArchived = true
            if case .account(let id) = router.inspectorContext, id == account.id {
                router.inspectorContext = .none
            }
        }
    }

    private func closeAccount(_ account: Account) {
        withAnimation(CentmondTheme.Motion.layout) {
            account.isClosed = true
            account.closedAt = .now
            account.includeInNetWorth = false
            account.includeInBudgeting = false
        }
    }

    private func duplicateAccount(_ account: Account) {
        let copy = Account(
            name: "\(account.name) (Copy)",
            type: account.type,
            institutionName: account.institutionName,
            lastFourDigits: nil,
            currentBalance: 0,
            currency: account.currency,
            colorHex: account.colorHex,
            sortOrder: accounts.count,
            openingBalance: 0,
            openingBalanceDate: .now,
            notes: account.notes,
            includeInNetWorth: account.includeInNetWorth,
            includeInBudgeting: account.includeInBudgeting,
            creditLimit: account.creditLimit
        )
        modelContext.insert(copy)
    }

    private func deleteAccount(_ account: Account) {
        Haptics.impact()
        if case .account(let id) = router.inspectorContext, id == account.id {
            router.inspectorContext = .none
        }
        for tx in account.transactions {
            tx.account = nil
        }
        modelContext.delete(account)
    }
}

// MARK: - Account Card

private struct AccountCardView: View {
    let account: Account
    var isSelected: Bool = false
    var isArchived: Bool = false
    var onTap: () -> Void = {}
    var onEdit: (() -> Void)?
    var onArchive: (() -> Void)?
    var onUnarchive: (() -> Void)?
    var onClose: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?

    @State private var isHovered = false

    private var accountColor: Color {
        Color(hex: account.effectiveColor)
    }

    private var balanceColor: Color {
        if account.type == .creditCard {
            return account.currentBalance > 0 ? CentmondTheme.Colors.negative : CentmondTheme.Colors.positive
        }
        return account.currentBalance >= 0 ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.negative
    }

    var body: some View {
        HStack(spacing: 0) {
            // Color indicator
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accountColor)
                .frame(width: 4)
                .padding(.vertical, CentmondTheme.Spacing.sm)

            HStack {
                HStack(spacing: CentmondTheme.Spacing.md) {
                    Image(systemName: account.type.iconName)
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? accountColor : CentmondTheme.Colors.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(isSelected ? accountColor.opacity(0.15) : CentmondTheme.Colors.bgQuaternary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: CentmondTheme.Spacing.sm) {
                            Text(account.name)
                                .font(CentmondTheme.Typography.bodyMedium)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .lineLimit(1)

                            if account.isClosed {
                                statusBadge("Closed", color: CentmondTheme.Colors.textQuaternary)
                            }
                        }

                        HStack(spacing: CentmondTheme.Spacing.sm) {
                            if let institution = account.institutionName, !institution.isEmpty {
                                Text(institution)
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .lineLimit(1)
                            }
                            if let digits = account.lastFourDigits, !digits.isEmpty {
                                Text("•••• \(digits)")
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            }
                            if account.currency != "USD" {
                                Text(account.currency)
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(CentmondTheme.Colors.bgQuaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            }
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(CurrencyFormat.standard(account.currentBalance, currencyCode: account.currency))
                        .font(CentmondTheme.Typography.monoLarge)
                        .foregroundStyle(balanceColor)
                        .monospacedDigit()

                    if account.type == .creditCard, let utilization = account.creditUtilization {
                        HStack(spacing: 4) {
                            // Mini utilization bar
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                        .fill(CentmondTheme.Colors.bgQuaternary)
                                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                        .fill(utilizationColor(utilization))
                                        .frame(width: max(0, geo.size.width * min(utilization, 1.0)))
                                }
                            }
                            .frame(width: 40, height: 3)

                            Text("\(Int(utilization * 100))%")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(utilizationColor(utilization))
                        }
                    } else {
                        Text("\(account.transactions.count) txns")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                }
            }
            .padding(.leading, CentmondTheme.Spacing.md)
            .padding(.trailing, CentmondTheme.Spacing.lg)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(
                    isSelected ? accountColor :
                    isHovered ? CentmondTheme.Colors.strokeDefault : CentmondTheme.Colors.strokeSubtle,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .opacity(isArchived || account.isClosed ? 0.6 : 1)
        .shadow(color: isHovered && !isArchived ? .black.opacity(0.2) : .clear, radius: 6, y: 2)
        .onHover { hovering in
            if hovering { Haptics.tick() }
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
        .onTapGesture { onTap() }
        .contextMenu {
            if isArchived {
                if let onUnarchive {
                    Button { onUnarchive() } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                }
                Divider()
                if let onDelete {
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                }
            } else {
                Button { onTap() } label: {
                    Label("View Details", systemImage: "eye")
                }

                if let onEdit {
                    Button { onEdit() } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }

                Divider()

                if let onDuplicate {
                    Button { onDuplicate() } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                }

                if !account.isClosed, let onClose {
                    Button { onClose() } label: {
                        Label("Close Account", systemImage: "xmark.circle")
                    }
                }

                if let onArchive {
                    Button { onArchive() } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }

                Divider()

                if let onDelete {
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
    }

    private func utilizationColor(_ utilization: Double) -> Color {
        if utilization > 0.9 { return CentmondTheme.Colors.negative }
        if utilization > 0.7 { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.positive
    }
}
