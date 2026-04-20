import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var searchText = ""
    @State private var selectedTransactions: Set<UUID> = []
    @State private var showBulkDeleteConfirmation = false
    @State private var typeFilter: TypeFilter = .all
    @State private var selectedAccountFilter: Account?
    @State private var selectedCategoryFilter: BudgetCategory?
    @State private var selectedTagFilter: Tag?
    @State private var dateRange: DateRange = .thisMonth
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
    @State private var customEnd: Date = .now

    enum TypeFilter: String, CaseIterable {
        case all = "All"
        case income = "Income"
        case expense = "Expense"
    }

    enum DateRange: String, CaseIterable {
        case today = "Today"
        case thisWeek = "This Week"
        case thisMonth = "This Month"
        case thisYear = "This Year"
        case all = "All Time"
        case custom = "Custom"

        var startDate: Date? {
            let calendar = Calendar.current
            switch self {
            case .today: return calendar.startOfDay(for: .now)
            case .thisWeek: return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now))
            case .thisMonth: return calendar.date(from: calendar.dateComponents([.year, .month], from: .now))
            case .thisYear: return calendar.date(from: calendar.dateComponents([.year], from: .now))
            case .all: return nil
            case .custom: return nil
            }
        }
    }

    private var filteredTransactions: [Transaction] {
        var result = transactions.filter { !$0.isDeleted && $0.modelContext != nil }

        // Search filter
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.payee.lowercased().contains(query) ||
                ($0.category?.name.lowercased().contains(query) ?? false) ||
                ($0.notes?.lowercased().contains(query) ?? false) ||
                ($0.account?.name.lowercased().contains(query) ?? false) ||
                $0.tags.contains(where: { $0.name.lowercased().contains(query) })
            }
        }

        // Type filter
        switch typeFilter {
        case .all: break
        case .income: result = result.filter { $0.isIncome }
        case .expense: result = result.filter { !$0.isIncome }
        }

        // Account filter
        if let account = selectedAccountFilter {
            result = result.filter { $0.account?.id == account.id }
        }

        // Category filter
        if let category = selectedCategoryFilter {
            result = result.filter { $0.category?.id == category.id }
        }

        // Tag filter
        if let tag = selectedTagFilter {
            result = result.filter { $0.tags.contains(where: { $0.id == tag.id }) }
        }

        // Date filter
        if dateRange == .custom {
            result = result.filter { $0.date >= customStart && $0.date <= customEnd }
        } else if dateRange == .thisMonth {
            result = result.filter { $0.date >= router.selectedMonthStart && $0.date < router.selectedMonthEnd }
        } else if let start = dateRange.startDate {
            result = result.filter { $0.date >= start }
        }

        return result
    }

    private var incomeCount: Int { transactions.filter { $0.isIncome }.count }
    private var expenseCount: Int { transactions.filter { !$0.isIncome }.count }

    private var totalIncome: Decimal {
        filteredTransactions.filter { $0.isIncome }.reduce(Decimal.zero) { $0 + $1.amount }
    }
    private var totalExpenses: Decimal {
        filteredTransactions.filter { !$0.isIncome }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    // Group transactions by date
    private var groupedTransactions: [(date: Date, transactions: [Transaction])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredTransactions) { tx in
            calendar.startOfDay(for: tx.date)
        }
        return grouped.sorted { $0.key > $1.key }
            .map { (date: $0.key, transactions: $0.value.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top filter bar
            filterBar

            // Type tabs + summary
            typeTabBar

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            if filteredTransactions.isEmpty {
                EmptyStateView(
                    icon: "list.bullet.rectangle",
                    heading: "No transactions yet",
                    description: "Start tracking your spending by adding your first transaction or importing from a CSV file.",
                    primaryAction: "Add Transaction",
                    secondaryAction: "Import CSV",
                    onPrimaryAction: { router.showSheet(.newTransaction) },
                    onSecondaryAction: { router.showSheet(.importCSV) }
                )
                .transition(.opacity)
            } else {
                // Date-grouped transaction list
                dateGroupedList
                    .transition(.opacity)
            }

            // Bulk action bar — visible as soon as ANY row is selected so
            // the single-row case still has one-click delete / categorize
            // without forcing the user to pick a second row first.
            if !selectedTransactions.isEmpty {
                bulkActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: router.selectedMonth) {
            withAnimation(CentmondTheme.Motion.micro) {
                dateRange = .thisMonth
            }
        }
    }

    // MARK: - Filter Bar

    @Namespace private var filterBarNamespace

    private var filterBar: some View {
        VStack(spacing: 0) {
            // Row 1: Search + filter pills + actions
            HStack(spacing: CentmondTheme.Spacing.sm) {
                // Search field
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)

                    TextField("Search...", text: $searchText)
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
                        .buttonStyle(.plainHover)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .frame(height: CentmondTheme.Sizing.inputHeight)
                .background(CentmondTheme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                        .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                )
                .layoutPriority(-1)

                // Account filter
                filterPill(
                    icon: "building.columns.fill",
                    label: selectedAccountFilter?.name ?? "All Acco…",
                    isActive: selectedAccountFilter != nil
                ) {
                    Button("All Accounts") { selectedAccountFilter = nil }
                    Divider()
                    ForEach(accounts) { account in
                        Button(account.name) { selectedAccountFilter = account }
                    }
                }

                // Category filter
                filterPill(
                    icon: "tag.fill",
                    label: selectedCategoryFilter?.name ?? "All Cate…",
                    isActive: selectedCategoryFilter != nil
                ) {
                    Button("All Categories") { selectedCategoryFilter = nil }
                    Divider()
                    ForEach(categories) { category in
                        Button {
                            selectedCategoryFilter = category
                        } label: {
                            Label(category.name, systemImage: category.icon)
                        }
                    }
                }

                // Tag filter
                if !allTags.isEmpty {
                    filterPill(
                        icon: "number",
                        label: selectedTagFilter.map { "#\($0.name)" } ?? "All Tags",
                        isActive: selectedTagFilter != nil
                    ) {
                        Button("All Tags") { selectedTagFilter = nil }
                        Divider()
                        ForEach(allTags) { tag in
                            Button("#\(tag.name)") { selectedTagFilter = tag }
                        }
                    }
                }

                Spacer(minLength: 0)

                // Action buttons — glass union
                GlassEffectContainer(spacing: 0) {
                    HStack(spacing: 0) {
                        Button {
                            router.showSheet(.importCSV)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                                .frame(width: 32, height: 30)
                        }
                        .buttonStyle(.plainHover)
                        .help("Import transactions from CSV")
                        .glassEffect(.regular, in: .rect(cornerRadius: CentmondTheme.Radius.sm))
                        .glassEffectUnion(id: "actions", namespace: filterBarNamespace)

                        Button {
                            router.showSheet(.newTransfer)
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                                .frame(width: 32, height: 30)
                        }
                        .buttonStyle(.plainHover)
                        .help("Create a transfer between accounts")
                        .glassEffect(.regular, in: .rect(cornerRadius: CentmondTheme.Radius.sm))
                        .glassEffectUnion(id: "actions", namespace: filterBarNamespace)

                        Button {
                            router.showSheet(.newTransaction)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(CentmondTheme.Colors.accent)
                                .frame(width: 32, height: 30)
                        }
                        .buttonStyle(.plainHover)
                        .help("Add a new transaction")
                        .glassEffect(.regular, in: .rect(cornerRadius: CentmondTheme.Radius.sm))
                        .glassEffectUnion(id: "actions", namespace: filterBarNamespace)
                    }
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.top, CentmondTheme.Spacing.md)
            .padding(.bottom, CentmondTheme.Spacing.sm)

            // Row 2: Date range chips
            HStack(spacing: CentmondTheme.Spacing.xs) {
                ForEach(DateRange.allCases, id: \.self) { range in
                    dateChip(range)
                }

                Spacer()
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.bottom, CentmondTheme.Spacing.md)
        }
        .background(CentmondTheme.Colors.bgSecondary)
    }

    private func dateChip(_ range: DateRange) -> some View {
        Button {
            withAnimation(CentmondTheme.Motion.micro) {
                dateRange = range
            }
        } label: {
            Text(range.rawValue)
                .font(CentmondTheme.Typography.caption)
                .lineLimit(1)
                .foregroundStyle(dateRange == range ? .white : CentmondTheme.Colors.textSecondary)
                .padding(.horizontal, CentmondTheme.Spacing.sm)
                .padding(.vertical, 5)
                .background(dateRange == range ? CentmondTheme.Colors.accent : CentmondTheme.Colors.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                        .stroke(dateRange == range ? .clear : CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
                )
                .animation(CentmondTheme.Motion.micro, value: dateRange)
        }
        .buttonStyle(.plainHover)
    }

    @ViewBuilder
    private func filterPill<MenuContent: View>(
        icon: String,
        label: String,
        isActive: Bool,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: CentmondTheme.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(CentmondTheme.Typography.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, CentmondTheme.Spacing.sm)
            .frame(height: 30)
            .background(isActive ? CentmondTheme.Colors.accentMuted : CentmondTheme.Colors.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                    .stroke(isActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault, lineWidth: 1)
            )
        }
        .buttonStyle(.plainHover)
        .foregroundStyle(isActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
        .animation(CentmondTheme.Motion.micro, value: isActive)
    }

    // MARK: - Type Tab Bar

    private var typeTabBar: some View {
        ViewThatFits(in: .horizontal) {
            // Full layout: tabs + summary + count
            typeTabContent(showSummary: true, showCount: true)
            // Medium: tabs + count only
            typeTabContent(showSummary: false, showCount: true)
            // Compact: tabs only
            typeTabContent(showSummary: false, showCount: false)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.sm)
    }

    private func typeTabContent(showSummary: Bool, showCount: Bool) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            typeTab("All", count: transactions.count, filter: .all)
            typeTab("Income", count: incomeCount, filter: .income)
            typeTab("Expenses", count: expenseCount, filter: .expense)

            Spacer()

            if showSummary && !filteredTransactions.isEmpty {
                HStack(spacing: CentmondTheme.Spacing.md) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(CentmondTheme.Colors.positive)
                        Text(CurrencyFormat.compact(totalIncome))
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.positive)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                            .animation(CentmondTheme.Motion.numeric, value: totalIncome)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(CentmondTheme.Colors.negative)
                        Text(CurrencyFormat.compact(totalExpenses))
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.negative)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                            .animation(CentmondTheme.Motion.numeric, value: totalExpenses)
                    }
                }
            }

            if showCount {
                Text("\(filteredTransactions.count) transactions")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func typeTab(_ title: String, count: Int, filter: TypeFilter) -> some View {
        Button {
            Haptics.tap()
            withAnimation(CentmondTheme.Motion.micro) {
                typeFilter = filter
            }
        } label: {
            HStack(spacing: CentmondTheme.Spacing.xs) {
                Text(title)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .lineLimit(1)

                Text("\(count)")
                    .font(CentmondTheme.Typography.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(typeFilter == filter ? CentmondTheme.Colors.accent.opacity(0.2) : CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
            }
            .foregroundStyle(typeFilter == filter ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
            .padding(.horizontal, CentmondTheme.Spacing.md)
            .padding(.vertical, CentmondTheme.Spacing.xs)
            .background(typeFilter == filter ? CentmondTheme.Colors.accentMuted.opacity(0.5) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
            .animation(CentmondTheme.Motion.micro, value: typeFilter)
        }
        .buttonStyle(.plainHover)
    }

    // MARK: - Date-Grouped List

    private var dateGroupedList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedTransactions, id: \.date) { group in
                    Section {
                        ForEach(group.transactions) { transaction in
                            TransactionRowView(
                                transaction: transaction,
                                isSelected: selectedTransactions.contains(transaction.id),
                                // When ANY row is selected, keep every row's
                                // checkbox permanently visible so users can
                                // keep clicking to add more to the selection
                                // without having to hover each one first.
                                hasAnySelection: !selectedTransactions.isEmpty,
                                categories: categories,
                                onSelect: {
                                    // Click-to-inspect switches to click-to-toggle
                                    // while selection mode is active. Mirrors Finder /
                                    // Mail: once you've started selecting, every click
                                    // adds or removes from the selection; you have to
                                    // deselect everything to get back to single-open.
                                    if !selectedTransactions.isEmpty {
                                        if selectedTransactions.contains(transaction.id) {
                                            selectedTransactions.remove(transaction.id)
                                        } else {
                                            selectedTransactions.insert(transaction.id)
                                        }
                                    } else {
                                        router.inspectTransaction(transaction.id)
                                    }
                                },
                                onToggleSelect: { selected in
                                    if selected {
                                        selectedTransactions.insert(transaction.id)
                                    } else {
                                        selectedTransactions.remove(transaction.id)
                                    }
                                },
                                onDelete: {
                                    if transaction.isTransfer {
                                        TransferService.deletePair(transaction, in: modelContext)
                                    } else {
                                        let account = transaction.account
                                        TransactionDeletionService.delete(transaction, context: modelContext)
                                        if let account { BalanceService.recalculate(account: account) }
                                    }
                                },
                                onDuplicate: {
                                    duplicateTransaction(transaction)
                                }
                            )
                        }
                    } header: {
                        dateSectionHeader(group.date, count: group.transactions.count, total: sectionTotal(group.transactions))
                    }
                }
            }
        }
    }

    private func dateSectionHeader(_ date: Date, count: Int, total: Decimal) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Text(formatSectionDate(date))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .textCase(.uppercase)
                .tracking(0.4)

            Spacer()

            Text("\(count) transaction\(count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary.opacity(0.7))

            Text("·")
                .font(.system(size: 10))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary.opacity(0.4))

            Text(CurrencyFormat.standard(total))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle((total >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative).opacity(0.6))
                .monospacedDigit()
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.xs)
        .background(CentmondTheme.Colors.bgPrimary.opacity(0.95))
    }

    private func formatSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today, \(date.formatted(.dateTime.day().month(.abbreviated)))"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday, \(date.formatted(.dateTime.day().month(.abbreviated)))"
        } else {
            return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        }
    }

    private func sectionTotal(_ transactions: [Transaction]) -> Decimal {
        transactions.reduce(Decimal.zero) { total, tx in
            total + (tx.isIncome ? tx.amount : -tx.amount)
        }
    }

    // MARK: - Bulk Action Bar

    private var bulkActionBar: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            Text("\(selectedTransactions.count) selected")
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            // "Select All" picks up every row currently visible after
            // filters — not the full ledger — so users can confirm with
            // their eyes what's about to be actioned. Idempotent: if
            // they're all already selected, the button re-inserts the
            // same ids (cheap Set op) and the count doesn't change.
            Button("Select All") {
                for tx in filteredTransactions {
                    selectedTransactions.insert(tx.id)
                }
            }
            .buttonStyle(GhostButtonStyle())
            .help("Select all \(filteredTransactions.count) visible transactions")

            Button("Deselect All") {
                selectedTransactions.removeAll()
            }
            .buttonStyle(GhostButtonStyle())
            .help("Deselect all transactions")

            Spacer()

            Menu("Categorize") {
                ForEach(categories) { category in
                    Button {
                        bulkCategorize(category)
                    } label: {
                        Label(category.name, systemImage: category.icon)
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Assign category to selected (transfers are skipped)")

            Button("Mark Reviewed") {
                bulkMarkReviewed()
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Mark selected as reviewed")

            Button("Delete") {
                showBulkDeleteConfirmation = true
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Delete selected transactions")
            .alert("Delete Transactions", isPresented: $showBulkDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { bulkDelete() }
            } message: {
                Text(bulkDeleteWarning)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgTertiary)
        .overlay(alignment: .top) {
            Rectangle().fill(CentmondTheme.Colors.strokeDefault).frame(height: 1)
        }
    }

    // MARK: - Helpers


    // MARK: - Bulk operations

    /// Selected transactions, in stable order, that still exist in the
    /// store. Used by every bulk action so we don't keep stale ids around
    /// after a delete.
    private var selectedLiveTransactions: [Transaction] {
        selectedTransactions.compactMap { id in
            transactions.first(where: { $0.id == id })
        }
    }

    private var bulkDeleteWarning: String {
        let total = selectedLiveTransactions.count
        let transferLegs = selectedLiveTransactions.filter(\.isTransfer).count
        if transferLegs > 0 {
            return "Delete \(total) transaction(s)? \(transferLegs) of these are transfer legs — their paired legs will also be removed. This cannot be undone."
        }
        return "Delete \(total) transaction(s)? This cannot be undone."
    }

    private func bulkCategorize(_ category: BudgetCategory) {
        // Transfers are intentionally uncategorized — skip them so a
        // bulk pick doesn't accidentally tag both legs of a transfer
        // with a spending category and pollute analytics later.
        for tx in selectedLiveTransactions where !tx.isTransfer {
            tx.category = category
            tx.updatedAt = .now
        }
        selectedTransactions.removeAll()
    }

    private func bulkMarkReviewed() {
        for tx in selectedLiveTransactions {
            tx.isReviewed = true
            tx.updatedAt = .now
        }
        selectedTransactions.removeAll()
    }

    private func bulkDelete() {
        // Bulk-delete bug history (2026-04-17):
        // v1 — called TransferService.deletePair in-loop, which does
        //      context.fetch + BalanceService.recalculate (reads the
        //      `account.transactions` relationship). Both mid-loop context
        //      ops forced SwiftData to flush pending changes, invalidating
        //      Transaction refs we were still iterating. Result: "select
        //      6, only 2–3 delete."
        // v2 — moved to a snapshot→delete→save→recalc three-phase pattern
        //      but still called TransferService.pairedLeg (a context.fetch)
        //      in Phase 1. For a selection of non-transfer rows this is
        //      harmless, but subsequent reports ("select 3, only 1 deletes")
        //      suggested the @Query lookup was still unreliable under load.
        // v3 (current) — single explicit FetchDescriptor<Transaction> in
        //      Phase 1 using an IN-set predicate, matched against the
        //      selected UUIDs. The fetch doesn't depend on the @Query
        //      array's freshness, can't be mid-loop-invalidated, and gives
        //      us context-attached live refs in one round trip. Transfer
        //      legs are discovered from `transferGroupID` after the fetch
        //      (no mid-loop context ops), then both legs go into one flat
        //      delete list. Save once, recalc once. If save fails we log
        //      rather than swallow silently — makes future partial-delete
        //      reports actually debuggable.

        // Snapshot the selected UUIDs up-front so any concurrent UI
        // mutation of `selectedTransactions` during the deletion run
        // cannot shrink the working set.
        let ids = Array(selectedTransactions)
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)

        // Phase 1: fetch every selected transaction in ONE query. Using
        // the context directly (not the @Query `transactions` array)
        // avoids any staleness in the reactive query's state.
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { idSet.contains($0.id) }
        )
        let primary: [Transaction] = (try? modelContext.fetch(descriptor)) ?? []

        // For each transfer leg among the selection, its paired leg must
        // also go so we never leave a half-transfer orphan. Pair lookups
        // go through `TransferService.pairedLeg`, which does a `fetch`
        // — safe here because we're still in Phase 1 (no deletes issued
        // yet, so there's nothing pending for SwiftData to flush).
        //
        // #Predicate bodies must be single expressions, so we can't
        // compose the "transferGroupID ∈ groups && id ∉ selection" filter
        // as one fetch. Iterating primary and calling `pairedLeg` per
        // leg is both simpler and equivalent.
        var pairedLegs: [Transaction] = []
        for tx in primary where tx.isTransfer {
            if let pair = TransferService.pairedLeg(of: tx, in: modelContext),
               !idSet.contains(pair.id) {
                pairedLegs.append(pair)
            }
        }

        // Capture all accounts touched by the delete so we can recalc
        // balances after the save. Dedup by id.
        var accountsToRecalc: [UUID: Account] = [:]
        for tx in primary + pairedLegs {
            if let acc = tx.account { accountsToRecalc[acc.id] = acc }
        }

        // Phase 2: delete everything in one flat pass. No fetches, no
        // relationship reads, no recalcs — just context.delete(...).
        for tx in primary + pairedLegs {
            guard !tx.isDeleted, tx.modelContext != nil else { continue }
            TransactionDeletionService.delete(tx, context: modelContext)
        }

        // Phase 3: save atomically. If this throws we surface it in the
        // console — prior "try?" silently swallowed constraint errors and
        // made partial deletes impossible to diagnose.
        do {
            try modelContext.save()
        } catch {
            print("[bulkDelete] save failed: \(error)")
        }

        // Recalculate account balances AFTER the save commits so the
        // `account.transactions` relationship reflects post-delete truth.
        for (_, acc) in accountsToRecalc {
            BalanceService.recalculate(account: acc)
        }

        selectedTransactions.removeAll()
    }

    private func duplicateTransaction(_ transaction: Transaction) {
        let dupe = Transaction(
            date: .now,
            payee: transaction.payee,
            amount: transaction.amount,
            notes: transaction.notes,
            isIncome: transaction.isIncome,
            account: transaction.account,
            category: transaction.category
        )
        modelContext.insert(dupe)
        dupe.tags = transaction.tags
        if let account = transaction.account {
            BalanceService.recalculate(account: account)
        }
    }
}

enum TransactionSortOrder {
    case dateDesc, dateAsc, amountDesc, amountAsc
}

// MARK: - Transaction Row View

struct TransactionRowView: View {
    let transaction: Transaction
    let isSelected: Bool
    /// True whenever any row in the list is currently selected. Drives the
    /// "selection mode" affordance: once the user picks one row, every
    /// row's checkbox stays visible so adding more is a single click away.
    var hasAnySelection: Bool = false
    let categories: [BudgetCategory]
    var onSelect: () -> Void
    var onToggleSelect: (Bool) -> Void
    var onDelete: () -> Void
    var onDuplicate: () -> Void

    @State private var isHovered = false
    @AppStorage("tableDensity") private var tableDensity = "default"

    /// Vertical padding driven by the user's Settings → Appearance →
    /// Table Density preference. "compact" halves the padding for a
    /// denser list; "default" keeps the original spacious layout.
    private var rowVerticalPadding: CGFloat {
        tableDensity == "compact" ? 6 : CentmondTheme.Spacing.md
    }

    var body: some View {
        if transaction.isDeleted || transaction.modelContext == nil {
            EmptyView()
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            // Selection checkbox — hidden by default, revealed on hover or
            // when the list is already in selection mode. Clicking toggles
            // membership without opening the inspector so it stays out of
            // the way for the common "click to view details" flow.
            selectionCheckbox

            // Type indicator
            typeIndicator

            // Category icon
            categoryIcon

            // Payee + category name
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if transaction.isTransfer {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .help("Transfer")
                    }
                    Text(transaction.payee)
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .lineLimit(1)
                }

                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Text(transaction.category?.name ?? "Uncategorized")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(transaction.category != nil ? CentmondTheme.Colors.textSecondary : CentmondTheme.Colors.warning)

                    if let notes = transaction.notes, !notes.isEmpty {
                        Text("·")
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        Text(notes)
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .lineLimit(1)
                    }

                    if !transaction.tags.isEmpty {
                        Text("·")
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        ForEach(Array(transaction.tags.prefix(2))) { tag in
                            Text("#\(tag.name)")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                                .lineLimit(1)
                        }
                        if transaction.tags.count > 2 {
                            Text("+\(transaction.tags.count - 2)")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Account
            if let account = transaction.account {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: account.type.iconName)
                        .font(.system(size: 10))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Text(account.name)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    if let digits = account.lastFourDigits, !digits.isEmpty {
                        Text("•\(digits)")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(CentmondTheme.Colors.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
            }

            // Goal allocation chip — only renders if this transaction
            // funded one or more goals via income allocation.
            TransactionGoalChip(transactionID: transaction.id)

            // Status badge
            statusBadge

            // Amount
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatAmount)
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(transaction.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()

                if transaction.isIncome {
                    IncomeAllocationSubLabel(
                        transactionID: transaction.id,
                        totalAmount: transaction.amount
                    )
                }
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, rowVerticalPadding)
        .background(
            isSelected ? CentmondTheme.Colors.accentMuted :
            isHovered ? CentmondTheme.Colors.bgQuaternary : .clear
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(CentmondTheme.Colors.accent)
                    .frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CentmondTheme.Colors.strokeSubtle)
                .frame(height: 1)
                .padding(.leading, 72)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            if hovering { Haptics.tick() }
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
        .contextMenu {
            Button { onSelect() } label: {
                Label("View Details", systemImage: "eye")
            }
            Button { onToggleSelect(!isSelected) } label: {
                Label(isSelected ? "Deselect" : "Select", systemImage: isSelected ? "checkmark.circle.fill" : "circle")
            }
            Button { onDuplicate() } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Divider()
            Menu("Change Category") {
                Button("Uncategorized") {
                    transaction.category = nil
                }
                Divider()
                ForEach(categories) { category in
                    Button {
                        transaction.category = category
                    } label: {
                        Label(category.name, systemImage: category.icon)
                    }
                }
            }
            Divider()
            if !transaction.isReviewed {
                Button {
                    transaction.isReviewed = true
                } label: {
                    Label("Mark Reviewed", systemImage: "checkmark.circle")
                }
            }
            Button {
                transaction.status = transaction.status == .cleared ? .pending : .cleared
            } label: {
                Label(transaction.status == .cleared ? "Mark Pending" : "Mark Cleared", systemImage: "circle.inset.filled")
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var typeIndicator: some View {
        ZStack {
            Circle()
                .fill(transaction.isIncome ? CentmondTheme.Colors.positive.opacity(0.12) : CentmondTheme.Colors.negative.opacity(0.12))
                .frame(width: 32, height: 32)

            Image(systemName: transaction.isIncome ? "arrow.down" : "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(transaction.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
        }
    }

    /// Leading multi-select checkbox. Always has a reserved 20pt slot so
    /// the row layout doesn't jitter when the checkbox fades in on hover —
    /// earlier versions that conditionally added/removed the view caused
    /// the rest of the row (type icon, payee, amount column) to shift one
    /// spacing unit every time the user moved the mouse over the list.
    private var selectionCheckbox: some View {
        let shouldShow = isSelected || isHovered || hasAnySelection
        return Button {
            onToggleSelect(!isSelected)
        } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                .symbolRenderingMode(.hierarchical)
                .opacity(shouldShow ? 1 : 0)
                .animation(CentmondTheme.Motion.micro, value: shouldShow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 20)
        .help(isSelected ? "Deselect" : "Select for bulk action")
    }

    private var categoryIcon: some View {
        Group {
            if let category = transaction.category {
                Image(systemName: category.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: category.colorHex))
                    .frame(width: 28, height: 28)
                    .background(Color(hex: category.colorHex).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            } else {
                Image(systemName: "questionmark")
                    .font(.system(size: 14))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            }
        }
    }

    private var statusBadge: some View {
        Group {
            switch transaction.status {
            case .cleared:
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                    Text("Cleared")
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.positive)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(CentmondTheme.Colors.positive.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))

            case .pending:
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 8, weight: .bold))
                    Text("Pending")
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.warning)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(CentmondTheme.Colors.warning.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))

            case .reconciled:
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text("Reconciled")
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(CentmondTheme.Colors.accent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
            }
        }
    }

    private var formatAmount: String {
        CurrencyFormat.signed(transaction.amount, isIncome: transaction.isIncome)
    }
}
