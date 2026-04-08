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

            // Bulk action bar
            if selectedTransactions.count >= 2 {
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
                                categories: categories,
                                onSelect: {
                                    router.inspectTransaction(transaction.id)
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
                                        modelContext.delete(transaction)
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

            Button("Deselect All") {
                selectedTransactions.removeAll()
            }
            .buttonStyle(GhostButtonStyle())
            .help("Deselect all transactions")

            Spacer()

            Menu("Categorize") {
                ForEach(categories) { category in
                    Button {
                        for id in selectedTransactions {
                            if let tx = transactions.first(where: { $0.id == id }) {
                                tx.category = category
                                tx.updatedAt = .now
                            }
                        }
                        selectedTransactions.removeAll()
                    } label: {
                        Label(category.name, systemImage: category.icon)
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Assign category to selected")

            Button("Mark Reviewed") {
                for id in selectedTransactions {
                    if let tx = transactions.first(where: { $0.id == id }) {
                        tx.isReviewed = true
                        tx.updatedAt = .now
                    }
                }
                selectedTransactions.removeAll()
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Mark selected as reviewed")

            Button("Delete") {
                for id in selectedTransactions {
                    if let tx = transactions.first(where: { $0.id == id }) {
                        modelContext.delete(tx)
                    }
                }
                selectedTransactions.removeAll()
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Delete selected transactions")
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgTertiary)
        .overlay(alignment: .top) {
            Rectangle().fill(CentmondTheme.Colors.strokeDefault).frame(height: 1)
        }
    }

    // MARK: - Helpers


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
    let categories: [BudgetCategory]
    var onSelect: () -> Void
    var onToggleSelect: (Bool) -> Void
    var onDelete: () -> Void
    var onDuplicate: () -> Void

    @State private var isHovered = false

    var body: some View {
        if transaction.isDeleted || transaction.modelContext == nil {
            EmptyView()
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
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

            // Status badge
            statusBadge

            // Amount
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatAmount)
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(transaction.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()

                if transaction.isIncome {
                    Text("income")
                        .font(.system(size: 9))
                        .foregroundStyle(CentmondTheme.Colors.positive.opacity(0.7))
                }
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.md)
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
