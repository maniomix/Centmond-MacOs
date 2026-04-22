import SwiftUI
import SwiftData

struct NetWorthView: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]

    /// Accounts eligible for net-worth math: not archived, not closed,
    /// and explicitly opted in via `includeInNetWorth`. The user can
    /// toggle that flag per account to keep e.g. an experimental cash
    /// account out of the totals without archiving it.
    private var activeAccounts: [Account] {
        accounts.filter { !$0.isArchived && !$0.isClosed && $0.includeInNetWorth }
    }

    private var assetAccounts: [Account] {
        activeAccounts.filter { !$0.type.isLiability }
    }
    private var liabilityAccounts: [Account] {
        activeAccounts.filter { $0.type.isLiability }
    }

    private var totalAssets: Decimal {
        assetAccounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
    }
    private var totalLiabilities: Decimal {
        liabilityAccounts.reduce(Decimal.zero) { $0 + abs($1.currentBalance) }
    }
    private var netWorth: Decimal {
        totalAssets - totalLiabilities
    }

    private var selectedAccountID: UUID? {
        if case .account(let id) = router.inspectorContext { return id }
        return nil
    }

    var body: some View {
        Group {
            if accounts.isEmpty {
                EmptyStateView(
                    icon: "chart.bar.fill",
                    heading: "No accounts yet",
                    description: "Add your accounts to track your net worth over time.",
                    primaryAction: "Add Account",
                    onPrimaryAction: { router.showSheet(.newAccount) }
                )
            } else if activeAccounts.isEmpty {
                EmptyStateView(
                    icon: "archivebox",
                    heading: "All accounts archived",
                    description: "Unarchive or add accounts to see your net worth.",
                    primaryAction: "Add Account",
                    onPrimaryAction: { router.showSheet(.newAccount) }
                )
            } else {
                ScrollView {
                    VStack(spacing: CentmondTheme.Spacing.xxl) {
                        netWorthSummary
                        NetWorthMilestonesCard(snapshots: snapshots)
                        NetWorthTrendChart(snapshots: snapshots)
                        NetWorthCompositionCard(
                            assetSlices: NetWorthCompositionCard.slices(from: assetAccounts, liabilities: false),
                            liabilitySlices: NetWorthCompositionCard.slices(from: liabilityAccounts, liabilities: true),
                            totalAssets: totalAssets,
                            totalLiabilities: totalLiabilities
                        )
                        LiabilityPayoffCard(liabilityAccounts: liabilityAccounts)
                        breakdown
                    }
                    .padding(CentmondTheme.Spacing.xxl)
                }
            }
        }
    }

    // MARK: - Summary

    private var netWorthSummary: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                        Text("NET WORTH")
                            .font(CentmondTheme.Typography.overline)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(1)

                        Text(CurrencyFormat.standard(netWorth))
                            .font(CentmondTheme.Typography.monoDisplay)
                            .foregroundStyle(netWorth >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                            .monospacedDigit()

                        Text("as of \(Date.now.formatted(.dateTime.month(.wide).day().year()))")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }

                    Spacer()

                    // Allocation ratio pill
                    if totalAssets > 0 || totalLiabilities > 0 {
                        let debtRatio: Double = totalAssets > 0
                            ? Double(truncating: (totalLiabilities / totalAssets) as NSDecimalNumber)
                            : 1.0
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("DEBT RATIO")
                                .font(CentmondTheme.Typography.overline)
                                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                .tracking(0.5)
                            Text("\(Int(debtRatio * 100))%")
                                .font(CentmondTheme.Typography.monoLarge)
                                .foregroundStyle(debtRatio > 0.5 ? CentmondTheme.Colors.negative :
                                                    debtRatio > 0.3 ? CentmondTheme.Colors.warning : CentmondTheme.Colors.positive)
                                .monospacedDigit()
                        }
                    }
                }

                // Horizontal bar showing assets vs liabilities proportion
                if totalAssets > 0 || totalLiabilities > 0 {
                    assetLiabilityBar
                }

                // Summary metrics row
                HStack(spacing: CentmondTheme.Spacing.xxxl) {
                    metricColumn(
                        label: "Total Assets",
                        value: CurrencyFormat.standard(totalAssets),
                        color: CentmondTheme.Colors.positive
                    )
                    metricColumn(
                        label: "Total Liabilities",
                        value: CurrencyFormat.standard(totalLiabilities),
                        color: CentmondTheme.Colors.negative
                    )
                    metricColumn(
                        label: "Accounts",
                        value: "\(activeAccounts.count)",
                        color: CentmondTheme.Colors.textSecondary
                    )

                    Spacer()
                }
            }
        }
    }

    private var assetLiabilityBar: some View {
        let total = totalAssets + totalLiabilities
        let assetFraction = total > 0 ? Double(truncating: (totalAssets / total) as NSDecimalNumber) : 0.5

        return VStack(spacing: CentmondTheme.Spacing.xs) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(CentmondTheme.Colors.positive)
                        .frame(width: max(4, geo.size.width * assetFraction))

                    if totalLiabilities > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(CentmondTheme.Colors.negative)
                            .frame(width: max(4, geo.size.width * (1.0 - assetFraction)))
                    }
                }
            }
            .frame(height: 10)

            HStack {
                Text("Assets \(CurrencyFormat.compact(totalAssets))")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.positive)
                Spacer()
                if totalLiabilities > 0 {
                    Text("Liabilities \(CurrencyFormat.compact(totalLiabilities))")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                }
            }
        }
    }

    private func metricColumn(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(CentmondTheme.Typography.monoLarge)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    // MARK: - Breakdown

    private var breakdown: some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.xxl) {
            // Assets column
            CardContainer {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    HStack {
                        Text("Assets")
                            .font(CentmondTheme.Typography.heading3)
                            .foregroundStyle(CentmondTheme.Colors.positive)

                        Spacer()

                        Text(CurrencyFormat.standard(totalAssets))
                            .font(CentmondTheme.Typography.monoLarge)
                            .foregroundStyle(CentmondTheme.Colors.positive)
                            .monospacedDigit()
                    }

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    if assetAccounts.isEmpty {
                        Text("No asset accounts")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .padding(.vertical, CentmondTheme.Spacing.sm)
                    } else {
                        ForEach(assetTypeGroups, id: \.type) { group in
                            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                                HStack {
                                    Text(group.type.displayName)
                                        .font(CentmondTheme.Typography.captionMedium)
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                        .textCase(.uppercase)
                                    Spacer()
                                    Text(CurrencyFormat.compact(group.total))
                                        .font(CentmondTheme.Typography.caption)
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                        .monospacedDigit()
                                }

                                ForEach(group.accounts) { account in
                                    nwAccountRow(
                                        account: account,
                                        fraction: totalAssets > 0 ? Double(truncating: (account.currentBalance / totalAssets) as NSDecimalNumber) : 0,
                                        color: CentmondTheme.Colors.positive,
                                        isSelected: selectedAccountID == account.id
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // Liabilities column
            CardContainer {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    HStack {
                        Text("Liabilities")
                            .font(CentmondTheme.Typography.heading3)
                            .foregroundStyle(CentmondTheme.Colors.negative)

                        Spacer()

                        Text(CurrencyFormat.standard(totalLiabilities))
                            .font(CentmondTheme.Typography.monoLarge)
                            .foregroundStyle(CentmondTheme.Colors.negative)
                            .monospacedDigit()
                    }

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    if liabilityAccounts.isEmpty {
                        VStack(spacing: CentmondTheme.Spacing.sm) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 24))
                                .foregroundStyle(CentmondTheme.Colors.positive)
                            Text("No liabilities — great job!")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CentmondTheme.Spacing.lg)
                    } else {
                        ForEach(liabilityAccounts.sorted(by: { abs($0.currentBalance) > abs($1.currentBalance) })) { account in
                            nwAccountRow(
                                account: account,
                                fraction: totalLiabilities > 0 ? Double(truncating: (abs(account.currentBalance) / totalLiabilities) as NSDecimalNumber) : 0,
                                color: CentmondTheme.Colors.negative,
                                isSelected: selectedAccountID == account.id
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Account Type Groups

    private struct AccountTypeGroup {
        let type: AccountType
        let accounts: [Account]
        var total: Decimal { accounts.reduce(Decimal.zero) { $0 + $1.currentBalance } }
    }

    private var assetTypeGroups: [AccountTypeGroup] {
        let types: [AccountType] = [.checking, .savings, .investment, .cash, .other]
        return types.compactMap { type in
            let matching = assetAccounts.filter { $0.type == type }
                .sorted { $0.currentBalance > $1.currentBalance }
            return matching.isEmpty ? nil : AccountTypeGroup(type: type, accounts: matching)
        }
    }

    // MARK: - Account Row with proportion bar

    private func nwAccountRow(account: Account, fraction: Double, color: Color, isSelected: Bool) -> some View {
        let history = recentHistory(for: account, days: 30)
        let delta30: Decimal = {
            guard let first = history.first else { return 0 }
            return account.currentBalance - first.balance
        }()
        let isLiability = account.type.isLiability

        return Button {
            router.inspectAccount(account.id)
        } label: {
            VStack(spacing: CentmondTheme.Spacing.xs) {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    if isLiability, let util = account.creditUtilization {
                        UtilizationRing(utilization: util)
                            .frame(width: 24)
                    } else {
                        Image(systemName: account.type.iconName)
                            .font(.system(size: 14))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .frame(width: 24)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name)
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .lineLimit(1)

                        if let institution = account.institutionName, !institution.isEmpty {
                            Text(institution)
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    AccountSparkline(points: history, color: color)
                        .frame(width: 64, height: 22)

                    if delta30 != 0 {
                        AccountChangeChip(delta: delta30, isLiability: isLiability)
                    }

                    Text("\(Int(fraction * 100))%")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)

                    Text(CurrencyFormat.standard(abs(account.currentBalance)))
                        .font(CentmondTheme.Typography.mono)
                        .foregroundStyle(color)
                        .monospacedDigit()
                }

                // Proportion bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(CentmondTheme.Colors.strokeSubtle)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color.opacity(0.5))
                            .frame(width: max(2, geo.size.width * min(fraction, 1.0)))
                    }
                }
                .frame(height: 3)
            }
            .padding(.vertical, CentmondTheme.Spacing.xs)
            .padding(.horizontal, CentmondTheme.Spacing.xs)
            .background(isSelected ? CentmondTheme.Colors.accentMuted.opacity(0.5) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHover)
    }

    /// Last `days` days of `AccountBalancePoint`s for an account, sorted by date.
    /// Filters the relationship in-memory rather than re-querying so SwiftData
    /// faulting stays cheap. Returns [] if there's no history (fresh install).
    private func recentHistory(for account: Account, days: Int) -> [AccountBalancePoint] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        return account.balanceHistory
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
    }
}
