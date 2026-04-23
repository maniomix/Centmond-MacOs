import SwiftUI
import SwiftData

/// Read-only strip that surfaces any GoalContributions routed from a given
/// Transaction. Used in the Transaction Inspector to show where income was
/// allocated. Pure display — editing lives in a later phase.
struct TransactionGoalAllocationsView: View {
    let transactionID: UUID
    @Query private var contributions: [GoalContribution]

    init(transactionID: UUID) {
        self.transactionID = transactionID
        let id = transactionID
        _contributions = Query(filter: #Predicate<GoalContribution> { $0.sourceTransactionID == id })
    }

    var body: some View {
        if !contributions.isEmpty {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                Text("Allocated to Goals")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                VStack(spacing: 1) {
                    ForEach(contributions) { c in
                        HStack(spacing: CentmondTheme.Spacing.sm) {
                            Image(systemName: c.goal?.icon ?? "target")
                                .font(CentmondTheme.Typography.captionSmall)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                                .frame(width: 16)
                            Text(c.goal?.name ?? "Deleted goal")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(CurrencyFormat.standard(c.amount))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(CentmondTheme.Colors.positive)
                        }
                        .frame(height: 32)
                        .padding(.horizontal, CentmondTheme.Spacing.md)
                    }
                }
                .background(CentmondTheme.Colors.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            }
        }
    }
}

/// Two-line trailing label for an income transaction in the transactions
/// list. When the income has any goal allocations, replaces the plain
/// "income" caption with a "→ $X goals · $Y to spend" breakdown so the user
/// can see at a glance what landed in their pocket. Falls back to the
/// existing "income" label when no allocations exist.
struct IncomeAllocationSubLabel: View {
    let transactionID: UUID
    let totalAmount: Decimal
    @Query private var contributions: [GoalContribution]

    init(transactionID: UUID, totalAmount: Decimal) {
        self.transactionID = transactionID
        self.totalAmount = totalAmount
        let id = transactionID
        _contributions = Query(filter: #Predicate<GoalContribution> { $0.sourceTransactionID == id })
    }

    private var allocated: Decimal { contributions.reduce(.zero) { $0 + $1.amount } }
    private var toSpend: Decimal { max(totalAmount - allocated, 0) }

    var body: some View {
        if allocated > 0 {
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: "target")
                        .font(.system(size: 7, weight: .semibold))
                    Text(CurrencyFormat.compact(allocated))
                        .font(CentmondTheme.Typography.micro.weight(.semibold).monospacedDigit())
                        .monospacedDigit()
                }
                .foregroundStyle(CentmondTheme.Colors.accent)
                .help("Allocated to goals")

                HStack(spacing: 3) {
                    Image(systemName: "wallet.pass.fill")
                        .font(.system(size: 7, weight: .semibold))
                    Text(CurrencyFormat.compact(toSpend))
                        .font(CentmondTheme.Typography.micro.weight(.semibold).monospacedDigit())
                        .monospacedDigit()
                }
                .foregroundStyle(CentmondTheme.Colors.positive.opacity(0.85))
                .help("To spend")
            }
        } else {
            Text("income")
                .font(CentmondTheme.Typography.micro)
                .foregroundStyle(CentmondTheme.Colors.positive.opacity(0.7))
        }
    }
}

/// Compact chip for a transaction row. Shows "→ 🎯 N" when the transaction
/// funded goals. Hides itself when there are none.
struct TransactionGoalChip: View {
    let transactionID: UUID
    @Query private var contributions: [GoalContribution]

    init(transactionID: UUID) {
        self.transactionID = transactionID
        let id = transactionID
        _contributions = Query(filter: #Predicate<GoalContribution> { $0.sourceTransactionID == id })
    }

    var body: some View {
        if !contributions.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "target")
                    .font(CentmondTheme.Typography.micro.weight(.semibold))
                Text("\(contributions.count)")
                    .font(CentmondTheme.Typography.overlineSemibold.monospacedDigit())
            }
            .foregroundStyle(CentmondTheme.Colors.accent)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(CentmondTheme.Colors.accent.opacity(0.12))
            .clipShape(Capsule())
            .help("Funded \(contributions.count) goal\(contributions.count == 1 ? "" : "s")")
        }
    }
}
