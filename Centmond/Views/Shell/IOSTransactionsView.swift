#if os(iOS)
import SwiftUI
import SwiftData

/// iOS Transactions list (Track B3). Searchable, grouped-by-day,
/// swipe-to-delete. Reads the same SwiftData store that the Mac
/// Transactions view writes to — Cloud sync keeps both in lockstep.
struct IOSTransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"

    @State private var search: String = ""
    @State private var pendingDelete: Transaction?
    @State private var showingAddSheet = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.0) { (label, txs) in
                    Section(header: Text(label).textCase(nil)) {
                        ForEach(txs) { tx in
                            row(for: tx)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        pendingDelete = tx
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search payee or notes")
            .navigationTitle("Transactions")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddSheet = true } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                IOSAddTransactionSheet()
            }
            .overlay {
                if filtered.isEmpty {
                    emptyState
                }
            }
            .confirmationDialog(
                "Delete this transaction?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { tx in
                Button("Delete", role: .destructive) {
                    modelContext.delete(tx)
                    try? modelContext.save()
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { tx in
                Text("\(tx.payee) — \(currency(tx.amount))")
            }
        }
    }

    // MARK: - Filtering + grouping

    private var filtered: [Transaction] {
        guard !search.isEmpty else { return transactions }
        let q = search.lowercased()
        return transactions.filter {
            $0.payee.lowercased().contains(q) ||
            ($0.notes?.lowercased().contains(q) ?? false) ||
            ($0.category?.name.lowercased().contains(q) ?? false)
        }
    }

    /// Groups by calendar day with friendly labels.
    private var grouped: [(String, [Transaction])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today

        let buckets = Dictionary(grouping: filtered) { tx in
            cal.startOfDay(for: tx.date)
        }
        return buckets
            .sorted { $0.key > $1.key }
            .map { (day, txs) in
                let label: String
                if day == today { label = "Today" }
                else if day == yesterday { label = "Yesterday" }
                else { label = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
                return (label, txs)
            }
    }

    // MARK: - Row

    private func row(for tx: Transaction) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((Color(hex: tx.category?.colorHex ?? "") ?? .accentColor).opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: tx.category?.icon ?? "circle.dashed")
                    .foregroundStyle(Color(hex: tx.category?.colorHex ?? "") ?? .accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.payee.isEmpty ? (tx.category?.name ?? "Untitled") : tx.payee)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let cat = tx.category {
                        Text(cat.name)
                    }
                    if let acc = tx.account {
                        Text("·")
                        Text(acc.name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text((tx.isIncome ? "+" : "") + currency(tx.amount))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tx.isIncome ? .green : .primary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: search.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "No transactions yet" : "No matches")
                .font(.headline)
                .foregroundStyle(.secondary)
            if search.isEmpty {
                Text("Add one on Mac and it'll sync here.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func currency(_ d: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = defaultCurrency
        nf.maximumFractionDigits = 2
        return nf.string(from: d as NSDecimalNumber) ?? "\(d)"
    }
}
#endif
