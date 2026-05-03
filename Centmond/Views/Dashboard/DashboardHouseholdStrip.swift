import SwiftUI
import SwiftData

/// Surfaces household state at the top level so users don't have to dive into
/// the hub to see split/settle-up load. Only renders when the household has at
/// least one member — single-user installs stay uncluttered. P6 of the
/// Household rebuild.
struct DashboardHouseholdStrip: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HouseholdMember.joinedAt) private var allMembers: [HouseholdMember]
    @Query private var transactions: [Transaction]
    @Query private var shares: [ExpenseShare]

    /// Tombstone-safe @Query views. Cloud-prune deletes a member /
    /// share / transaction → @Query republish lags one frame → reading
    /// any persisted attribute on the dead reference faults.
    private var liveMembers: [HouseholdMember] {
        allMembers.filter { $0.modelContext != nil && !$0.isDeleted }
    }
    private var liveTransactions: [Transaction] {
        transactions.filter { $0.modelContext != nil && !$0.isDeleted }
    }
    private var liveShares: [ExpenseShare] {
        shares.filter { $0.modelContext != nil && !$0.isDeleted }
    }

    private var members: [HouseholdMember] { liveMembers.filter(\.isActive) }

    var body: some View {
        if members.isEmpty {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        let unsettled = totalUnsettled()
        let openSplits = liveShares.filter { $0.status == .owed }.count
        let top = topSpenderThisMonth()

        return CardContainer {
            HStack(spacing: CentmondTheme.Spacing.lg) {
                headerBlock

                Divider().frame(height: 38)

                metricBlock(
                    label: "TOP SPENDER",
                    value: top?.name ?? "—",
                    detail: top.map { CurrencyFormat.compact(monthlySpending(for: $0)) } ?? "",
                    tint: CentmondTheme.Colors.negative
                )

                Divider().frame(height: 38)

                metricBlock(
                    label: "UNSETTLED",
                    value: CurrencyFormat.compact(unsettled),
                    detail: unsettled > 0 ? "pending" : "all clear",
                    tint: unsettled > 0 ? CentmondTheme.Colors.warning : CentmondTheme.Colors.positive
                )

                Divider().frame(height: 38)

                metricBlock(
                    label: "OPEN SPLITS",
                    value: "\(openSplits)",
                    detail: openSplits == 0 ? "none" : "txns",
                    tint: CentmondTheme.Colors.accent
                )

                Spacer()

                Button {
                    router.showSheet(.householdSettleUp)
                } label: {
                    Label("Record Payment", systemImage: "arrow.left.arrow.right.circle")
                }
                .buttonStyle(SecondaryChipButtonStyle())
                .disabled(members.count < 2)

                Button {
                    router.selectedScreen = .household
                } label: {
                    Label("Open", systemImage: "arrow.up.right")
                }
                .buttonStyle(SecondaryChipButtonStyle())
            }
        }
    }

    private var headerBlock: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "person.2.fill")
                .font(CentmondTheme.Typography.bodyLarge)
                .foregroundStyle(CentmondTheme.Colors.accent)
                .frame(width: 32, height: 32)
                .background(CentmondTheme.Colors.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("HOUSEHOLD")
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)
                Text("\(members.count) members")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
        }
    }

    private func metricBlock(label: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
        }
    }

    // MARK: - Derivations

    private func totalUnsettled() -> Decimal {
        HouseholdService.balances(in: modelContext)
            .map { $0.amount > 0 ? $0.amount : 0 }
            .reduce(0, +)
    }

    private func topSpenderThisMonth() -> HouseholdMember? {
        guard !members.isEmpty else { return nil }
        var top: (HouseholdMember, Decimal)?
        for m in members {
            let amt = monthlySpending(for: m)
            if let current = top {
                if amt > current.1 { top = (m, amt) }
            } else if amt > 0 {
                top = (m, amt)
            }
        }
        return top?.0
    }

    private func monthlySpending(for m: HouseholdMember) -> Decimal {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: .now))!
        return transactions
            .filter {
                $0.householdMember?.id == m.id
                && $0.date >= start
                && BalanceService.isSpendingExpense($0)
            }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }
}
