#if os(iOS)
import SwiftUI
import SwiftData
import Charts

/// First real iOS view (Track B3). Reads the same SwiftData store + Cloud
/// sync state the Mac uses. Shows: total balance hero, this-month
/// income/spend, top categories chart, recent transactions, accounts list.
struct IOSDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Account.name) private var accounts: [Account]
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    heroCard
                    monthCardsRow
                    categoriesCard
                    accountsCard
                    recentTransactionsCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Derived data

    private var liveAccounts: [Account] { accounts.filter { !$0.isArchived } }

    private var totalBalance: Decimal {
        liveAccounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
    }

    private var monthRange: (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? now
        return (start, end)
    }

    private var thisMonthTransactions: [Transaction] {
        let r = monthRange
        return transactions.filter { $0.date >= r.start && $0.date < r.end }
    }

    private var monthIncome: Decimal {
        thisMonthTransactions.filter(\.isIncome).reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var monthSpend: Decimal {
        thisMonthTransactions.filter { !$0.isIncome }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private struct CategorySlice: Identifiable {
        let id: UUID
        let name: String
        let amount: Decimal
        let colorHex: String
    }

    private var topCategories: [CategorySlice] {
        let grouped = Dictionary(grouping: thisMonthTransactions.filter { !$0.isIncome && $0.category != nil }) {
            $0.category!.id
        }
        return grouped.compactMap { (_, txs) -> CategorySlice? in
            guard let cat = txs.first?.category else { return nil }
            let total = txs.reduce(Decimal.zero) { $0 + $1.amount }
            return CategorySlice(id: cat.id, name: cat.name, amount: total, colorHex: cat.colorHex)
        }
        .sorted { $0.amount > $1.amount }
        .prefix(5)
        .map { $0 }
    }

    // MARK: - Cards

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Total balance")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(currency(totalBalance))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text("\(liveAccounts.count) account\(liveAccounts.count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var monthCardsRow: some View {
        HStack(spacing: 12) {
            monthMiniCard(title: "Income", value: monthIncome, color: .green, icon: "arrow.down.left.circle.fill")
            monthMiniCard(title: "Spend", value: monthSpend, color: .red, icon: "arrow.up.right.circle.fill")
        }
    }

    private func monthMiniCard(title: String, value: Decimal, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Text(currency(value))
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var categoriesCard: some View {
        if !topCategories.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Top categories this month")
                    .font(.headline)
                Chart(topCategories) { slice in
                    BarMark(
                        x: .value("Amount", slice.amount as NSDecimalNumber as Decimal),
                        y: .value("Category", slice.name)
                    )
                    .foregroundStyle(Color(hex: slice.colorHex) ?? .accentColor)
                    .cornerRadius(6)
                }
                .frame(height: CGFloat(topCategories.count) * 36 + 24)
                .chartXAxis(.hidden)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var accountsCard: some View {
        if !liveAccounts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Accounts")
                    .font(.headline)
                ForEach(liveAccounts) { account in
                    HStack {
                        Circle()
                            .fill(Color(hex: account.colorHex ?? "") ?? .accentColor)
                            .frame(width: 10, height: 10)
                        Text(account.name)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(currency(account.currentBalance))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var recentTransactionsCard: some View {
        if !transactions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent activity")
                    .font(.headline)
                ForEach(transactions.prefix(8)) { tx in
                    HStack(spacing: 12) {
                        Image(systemName: tx.category?.icon ?? "circle.dashed")
                            .foregroundStyle(Color(hex: tx.category?.colorHex ?? "") ?? .secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tx.payee.isEmpty ? (tx.category?.name ?? "Untitled") : tx.payee)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(tx.date, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                OptionalCategoryPill(category: tx.category, size: .compact, showsIcon: false)
                            }
                        }
                        Spacer()
                        Text(currency(tx.amount))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tx.isIncome ? .green : .primary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    if tx.id != transactions.prefix(8).last?.id { Divider() }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Helpers

    private func currency(_ d: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = defaultCurrency
        nf.maximumFractionDigits = 2
        return nf.string(from: d as NSDecimalNumber) ?? "\(d)"
    }
}

#endif
// Color(hex:) lives in Centmond/Theme/Color+Hex.swift
