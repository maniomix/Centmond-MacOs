#if os(iOS)
import SwiftUI
import SwiftData

/// iOS Budgets list (Track B3). For each expense category with a budget
/// this month, show spent / cap as a progress bar. Reads the same
/// MonthlyBudget rows the Mac creates.
struct IOSBudgetsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query private var monthlyBudgets: [MonthlyBudget]
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    overviewCard
                    ForEach(rows) { row in
                        budgetRow(row)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Budgets")
            .navigationBarTitleDisplayMode(.large)
            .overlay {
                if rows.isEmpty {
                    emptyState
                }
            }
        }
    }

    // MARK: - Computation

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var currentMonth: Int { Calendar.current.component(.month, from: Date()) }

    private struct Row: Identifiable {
        let id: UUID
        let name: String
        let icon: String
        let colorHex: String
        let cap: Decimal
        let spent: Decimal
        var fraction: Double {
            guard cap > 0 else { return 0 }
            return min(1.5, NSDecimalNumber(decimal: spent / cap).doubleValue)
        }
    }

    private var monthRange: (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: currentYear, month: currentMonth)) ?? Date()
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }

    private var thisMonthExpenses: [Transaction] {
        let r = monthRange
        return transactions.filter { !$0.isIncome && $0.date >= r.start && $0.date < r.end }
    }

    private var rows: [Row] {
        let budgetsForMonth = monthlyBudgets.filter { $0.year == currentYear && $0.month == currentMonth }
        let spendByCat = Dictionary(grouping: thisMonthExpenses.compactMap { tx -> (UUID, Decimal)? in
            guard let cat = tx.category else { return nil }
            return (cat.id, tx.amount)
        }, by: \.0)
            .mapValues { $0.reduce(Decimal.zero) { $0 + $1.1 } }

        return budgetsForMonth.compactMap { mb -> Row? in
            guard let cat = categories.first(where: { $0.id == mb.categoryID }) else { return nil }
            return Row(
                id: cat.id,
                name: cat.name,
                icon: cat.icon,
                colorHex: cat.colorHex,
                cap: mb.amount,
                spent: spendByCat[cat.id] ?? 0
            )
        }
        .sorted { $0.fraction > $1.fraction }
    }

    private var overviewCard: some View {
        let totalCap = rows.reduce(Decimal.zero) { $0 + $1.cap }
        let totalSpent = rows.reduce(Decimal.zero) { $0 + $1.spent }
        let remaining = totalCap - totalSpent
        return VStack(alignment: .leading, spacing: 6) {
            Text(monthLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(currency(remaining))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(remaining >= 0 ? Color.primary : Color.red)
            Text("remaining of \(currency(totalCap))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func budgetRow(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill((Color(hex: row.colorHex) ?? .accentColor).opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: row.icon)
                        .foregroundStyle(Color(hex: row.colorHex) ?? .accentColor)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(currency(row.spent)) / \(currency(row.cap))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: row.fraction, total: 1.0) {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(barTint(row))
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func barTint(_ row: Row) -> Color {
        if row.fraction >= 1.0 { return .red }
        if row.fraction >= 0.85 { return .orange }
        return Color(hex: row.colorHex) ?? .accentColor
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.pie")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("No budgets for \(monthLabel)")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Set budgets on Mac and they'll sync here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var monthLabel: String {
        let cal = Calendar.current
        let date = cal.date(from: DateComponents(year: currentYear, month: currentMonth)) ?? Date()
        return date.formatted(.dateTime.month(.wide).year())
    }

    private func currency(_ d: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = defaultCurrency
        nf.maximumFractionDigits = 0
        return nf.string(from: d as NSDecimalNumber) ?? "\(d)"
    }
}
#endif
