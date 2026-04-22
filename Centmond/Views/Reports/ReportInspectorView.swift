import SwiftUI
import SwiftData

// Modern inspector: collapsible card sections, pill-based pickers,
// searchable multi-selects with inline chip tags for selected items,
// and a top summary bar with "Active filters: N · Reset" so the user
// always sees at a glance what the preview is showing.

struct ReportInspectorView: View {
    @Binding var definition: ReportDefinition

    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query private var transactions: [Transaction]

    @State private var expandedSections: Set<SectionID> = [.date, .grouping, .direction]
    @State private var cachedTopPayees: [String] = []
    @State private var lastTxCount: Int = -1

    enum SectionID: Hashable {
        case date, grouping, direction, accounts, categories, tags, payees, amount, toggles, comparison, display
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                activeFiltersBar
                section(.date, title: "Date", symbol: "calendar", badge: nil)         { dateContent }
                section(.grouping, title: "Group by", symbol: "square.grid.3x3", badge: nil) { groupingContent }
                section(.direction, title: "Direction", symbol: "arrow.left.arrow.right", badge: directionBadge) { directionContent }
                section(.accounts, title: "Accounts", symbol: "building.columns", badge: chipCount(definition.filter.accountIDs.count)) { accountsContent }
                section(.categories, title: "Categories", symbol: "tag", badge: chipCount(definition.filter.categoryIDs.count)) { categoriesContent }
                section(.tags, title: "Tags", symbol: "number", badge: chipCount(definition.filter.tagIDs.count))     { tagsContent }
                section(.payees, title: "Payees", symbol: "storefront", badge: chipCount(definition.filter.payees.count)) { payeesContent }
                section(.amount, title: "Amount range", symbol: "dollarsign.circle", badge: amountBadge) { amountContent }
                section(.toggles, title: "Include", symbol: "slider.horizontal.3", badge: togglesBadge)  { togglesContent }
                section(.comparison, title: "Compare to", symbol: "chart.line.uptrend.xyaxis", badge: comparisonBadge) { comparisonContent }
                section(.display, title: "Display", symbol: "eye", badge: nil) { displayContent }
            }
            .padding(CentmondTheme.Spacing.md)
        }
        .background(CentmondTheme.Colors.bgSecondary)
        .overlay(alignment: .trailing) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(width: 1)
        }
        .onAppear { refreshPayeesIfNeeded() }
        .onChange(of: transactions.count) { _, _ in refreshPayeesIfNeeded() }
    }

    private func refreshPayeesIfNeeded() {
        guard transactions.count != lastTxCount else { return }
        lastTxCount = transactions.count
        var counts: [String: Int] = [:]
        for tx in transactions { counts[tx.payee, default: 0] += 1 }
        cachedTopPayees = counts.sorted { $0.value > $1.value }.prefix(100).map(\.key)
    }

    // MARK: - Active filters bar

    private var activeFiltersBar: some View {
        let count = activeFilterCount
        return HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(count > 0 ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)

            Text(count == 0 ? "No filters applied" : "\(count) filter\(count == 1 ? "" : "s") active")
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            Spacer()

            if count > 0 {
                Button {
                    resetFilters()
                } label: {
                    Text("Reset")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .fill(CentmondTheme.Colors.bgTertiary)
        )
    }

    private var activeFilterCount: Int {
        var n = 0
        if !definition.filter.accountIDs.isEmpty  { n += 1 }
        if !definition.filter.categoryIDs.isEmpty { n += 1 }
        if !definition.filter.tagIDs.isEmpty      { n += 1 }
        if !definition.filter.payees.isEmpty      { n += 1 }
        if definition.filter.direction != .any    { n += 1 }
        if definition.filter.minAmount != nil     { n += 1 }
        if definition.filter.maxAmount != nil     { n += 1 }
        if definition.filter.includeTransfers     { n += 1 }
        if definition.filter.onlyReviewed         { n += 1 }
        return n
    }

    private func resetFilters() {
        definition.filter = ReportFilter()
    }

    // MARK: - Section chrome

    @ViewBuilder
    private func section<Content: View>(
        _ id: SectionID,
        title: String,
        symbol: String,
        badge: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = expandedSections.contains(id)
        let hasActive = badge != nil

        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(id)
            } label: {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hasActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
                        .frame(width: 18)

                    Text(title)
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    if let badge {
                        Text(badge)
                            .font(CentmondTheme.Typography.caption)
                            .monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(CentmondTheme.Colors.accentMuted)
                            .foregroundStyle(CentmondTheme.Colors.accent)
                            .clipShape(Capsule())
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .animation(CentmondTheme.Motion.micro, value: expanded)
                }
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .padding(.vertical, CentmondTheme.Spacing.sm + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                    content()
                }
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .padding(.bottom, CentmondTheme.Spacing.md)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .fill(CentmondTheme.Colors.bgTertiary.opacity(hasActive ? 0.8 : 0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .stroke(hasActive ? CentmondTheme.Colors.accent.opacity(0.35) : CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    private func toggle(_ id: SectionID) {
        if expandedSections.contains(id) { expandedSections.remove(id) }
        else                             { expandedSections.insert(id) }
    }

    private func chipCount(_ n: Int) -> String? {
        n == 0 ? nil : "\(n)"
    }

    // MARK: - Date

    @ViewBuilder
    private var dateContent: some View {
        let presets: [ReportDateRange.Preset] = [
            .mtd, .qtd, .ytd,
            .last30Days, .last90Days, .last365Days,
            .last3Months, .last6Months, .last12Months,
            .thisYear, .lastYear, .allTime
        ]

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(presets, id: \.self) { preset in
                presetChip(preset)
            }
        }

        if case .custom = definition.range {
            customDateFields
        } else {
            Button {
                let r = definition.range.resolve()
                definition.range = .custom(start: r.start, end: r.end)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Custom range")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background {
                    Capsule(style: .continuous)
                        .fill(CentmondTheme.Colors.bgSecondary)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(CentmondTheme.Colors.strokeSubtle, lineWidth: 0.5)
                        }
                }
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func presetChip(_ preset: ReportDateRange.Preset) -> some View {
        let active = isPresetActive(preset)
        return Button {
            definition.range = .preset(preset)
        } label: {
            Text(preset.shortLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background {
                    Capsule(style: .continuous)
                        .fill(active ? CentmondTheme.Colors.accent.opacity(0.14) : CentmondTheme.Colors.bgSecondary)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    active ? CentmondTheme.Colors.accent.opacity(0.35) : CentmondTheme.Colors.strokeSubtle,
                                    lineWidth: 0.5
                                )
                        }
                }
        }
        .buttonStyle(.plain)
        .help(preset.label)
    }

    @ViewBuilder
    private var customDateFields: some View {
        let binding = Binding<(Date, Date)>(
            get: {
                if case .custom(let s, let e) = definition.range { return (s, e) }
                let r = definition.range.resolve()
                return (r.start, r.end)
            },
            set: { definition.range = .custom(start: $0.0, end: $0.1) }
        )

        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            DatePicker("From", selection: Binding(get: { binding.wrappedValue.0 }, set: { binding.wrappedValue = ($0, binding.wrappedValue.1) }), displayedComponents: .date)
            DatePicker("To",   selection: Binding(get: { binding.wrappedValue.1 }, set: { binding.wrappedValue = (binding.wrappedValue.0, $0) }), displayedComponents: .date)
        }
        .font(CentmondTheme.Typography.body)
        .foregroundStyle(CentmondTheme.Colors.textSecondary)
    }

    private func isPresetActive(_ preset: ReportDateRange.Preset) -> Bool {
        if case .preset(let p) = definition.range { return p == preset }
        return false
    }

    // MARK: - Grouping

    @ViewBuilder
    private var groupingContent: some View {
        Picker("Group", selection: $definition.groupBy) {
            ForEach(ReportGroupBy.allCases, id: \.self) { g in
                Text(g.label).tag(g)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Direction

    private var directionBadge: String? {
        definition.filter.direction == .any ? nil : definition.filter.direction.label
    }

    @ViewBuilder
    private var directionContent: some View {
        HStack(spacing: 6) {
            directionPill(.any,     label: "All",      symbol: "circle.grid.2x2")
            directionPill(.income,  label: "Income",   symbol: "arrow.down.left.circle")
            directionPill(.expense, label: "Expense",  symbol: "arrow.up.right.circle")
        }
    }

    private func directionPill(_ d: ReportFilter.Direction, label: String, symbol: String) -> some View {
        let active = definition.filter.direction == d
        let accent: Color = {
            switch d {
            case .any:     return CentmondTheme.Colors.accent
            case .income:  return CentmondTheme.Colors.positive
            case .expense: return CentmondTheme.Colors.negative
            }
        }()

        return Button {
            definition.filter.direction = d
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(CentmondTheme.Typography.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(active ? accent.opacity(0.22) : CentmondTheme.Colors.bgSecondary)
            .foregroundStyle(active ? accent : CentmondTheme.Colors.textSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(active ? accent.opacity(0.4) : CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Accounts

    @ViewBuilder
    private var accountsContent: some View {
        MultiSelectList(
            items: accounts.map { MultiSelectItem(id: $0.id, title: $0.name, subtitle: $0.institutionName) },
            selection: Binding(
                get: { definition.filter.accountIDs },
                set: { definition.filter.accountIDs = $0 }
            ),
            searchable: accounts.count > 6,
            placeholder: "Search accounts"
        )
    }

    // MARK: - Categories

    @ViewBuilder
    private var categoriesContent: some View {
        MultiSelectList(
            items: categories.map {
                MultiSelectItem(id: $0.id, title: $0.name, subtitle: nil, colorHex: $0.colorHex)
            },
            selection: Binding(
                get: { definition.filter.categoryIDs },
                set: { definition.filter.categoryIDs = $0 }
            ),
            searchable: categories.count > 6,
            placeholder: "Search categories"
        )
    }

    // MARK: - Tags

    @ViewBuilder
    private var tagsContent: some View {
        if tags.isEmpty {
            emptyHint("No tags yet")
        } else {
            MultiSelectList(
                items: tags.map { MultiSelectItem(id: $0.id, title: $0.name, subtitle: nil, colorHex: $0.colorHex) },
                selection: Binding(
                    get: { definition.filter.tagIDs },
                    set: { definition.filter.tagIDs = $0 }
                ),
                searchable: tags.count > 8,
                placeholder: "Search tags"
            )
        }
    }

    // MARK: - Payees

    @ViewBuilder
    private var payeesContent: some View {
        if cachedTopPayees.isEmpty {
            emptyHint("No transactions yet")
        } else {
            PayeeMultiSelect(
                payees: cachedTopPayees,
                selection: Binding(
                    get: { definition.filter.payees },
                    set: { definition.filter.payees = $0 }
                )
            )
        }
    }

    // MARK: - Amount

    private var amountBadge: String? {
        let hasMin = definition.filter.minAmount != nil
        let hasMax = definition.filter.maxAmount != nil
        if !hasMin && !hasMax { return nil }
        return hasMin && hasMax ? "range" : (hasMin ? "min" : "max")
    }

    @ViewBuilder
    private var amountContent: some View {
        HStack(spacing: 8) {
            DeferredAmountField(
                placeholder: "Min",
                value: Binding(
                    get: { definition.filter.minAmount },
                    set: { definition.filter.minAmount = $0 }
                )
            )

            Text("—")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)

            DeferredAmountField(
                placeholder: "Max",
                value: Binding(
                    get: { definition.filter.maxAmount },
                    set: { definition.filter.maxAmount = $0 }
                )
            )
        }
    }

    // MARK: - Toggles

    private var togglesBadge: String? {
        var items: [String] = []
        if definition.filter.includeTransfers { items.append("transfers") }
        if definition.filter.onlyReviewed     { items.append("reviewed") }
        return items.isEmpty ? nil : items.joined(separator: ", ")
    }

    @ViewBuilder
    private var togglesContent: some View {
        Toggle("Include transfers", isOn: $definition.filter.includeTransfers)
        Toggle("Only reviewed",      isOn: $definition.filter.onlyReviewed)
    }

    // MARK: - Comparison

    private var comparisonBadge: String? {
        definition.comparison == .none ? nil : definition.comparison.label
    }

    @ViewBuilder
    private var comparisonContent: some View {
        VStack(spacing: 4) {
            ForEach(ReportComparisonMode.allCases, id: \.self) { mode in
                comparisonRow(mode)
            }
        }
    }

    private func comparisonRow(_ mode: ReportComparisonMode) -> some View {
        let active = definition.comparison == mode
        return Button {
            definition.comparison = mode
        } label: {
            HStack(spacing: 8) {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(active ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                Text(mode.label)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(active ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textSecondary)
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Display

    @ViewBuilder
    private var displayContent: some View {
        Stepper(value: $definition.display.topN, in: 3...50, step: 1) {
            HStack {
                Text("Top N")
                Spacer()
                Text("\(definition.display.topN)")
                    .font(CentmondTheme.Typography.mono)
                    .monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
        }
        Toggle("Show percentages", isOn: $definition.display.showPercentages)
        Toggle("Show transactions", isOn: $definition.display.showTransactions)
        Toggle("Include notes in export", isOn: $definition.display.includeNotes)
    }

    // MARK: - Shared helpers

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(CentmondTheme.Typography.caption)
            .foregroundStyle(CentmondTheme.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }
}

// MARK: - Multi-select checklist (UUID-keyed)

private struct MultiSelectItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    var subtitle: String? = nil
    var colorHex: String? = nil
}

private struct MultiSelectList: View {
    let items: [MultiSelectItem]
    @Binding var selection: Set<UUID>
    let searchable: Bool
    let placeholder: String

    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 6) {
            if !selection.isEmpty {
                FlowTagRow(
                    tags: selection.compactMap { id in items.first(where: { $0.id == id }) },
                    onRemove: { id in selection.remove(id) }
                )
            }

            if searchable {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.caption)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(CentmondTheme.Colors.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered, id: \.id) { item in
                        row(item)
                    }
                }
            }
            .frame(maxHeight: 180)

            if !selection.isEmpty {
                Button("Clear selection") { selection.removeAll() }
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var filtered: [MultiSelectItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        let q = query.lowercased()
        return items.filter {
            $0.title.lowercased().contains(q) ||
            ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    private func row(_ item: MultiSelectItem) -> some View {
        let selected = selection.contains(item.id)
        return Button {
            if selected { selection.remove(item.id) }
            else        { selection.insert(item.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)

                if let hex = item.colorHex, !hex.isEmpty {
                    Circle().fill(Color(hex: hex)).frame(width: 8, height: 8)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .lineLimit(1)
                    if let sub = item.subtitle {
                        Text(sub)
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(selected ? CentmondTheme.Colors.accentMuted.opacity(0.4) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Payee multi-select (string-keyed)

private struct PayeeMultiSelect: View {
    let payees: [String]
    @Binding var selection: Set<String>

    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 6) {
            if !selection.isEmpty {
                FlowTagRow(
                    tags: selection.map { MultiSelectItem(id: UUID(), title: $0) },
                    onRemove: { _ in },
                    customRemove: { title in selection.remove(title) }
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                TextField("Search payees", text: $query)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered, id: \.self) { payee in
                        payeeRow(payee)
                    }
                }
            }
            .frame(maxHeight: 180)

            if !selection.isEmpty {
                Button("Clear selection") { selection.removeAll() }
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var filtered: [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return payees }
        let q = query.lowercased()
        return payees.filter { $0.lowercased().contains(q) }
    }

    private func payeeRow(_ payee: String) -> some View {
        let selected = selection.contains(payee)
        return Button {
            if selected { selection.remove(payee) } else { selection.insert(payee) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                Text(payee)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(selected ? CentmondTheme.Colors.accentMuted.opacity(0.4) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chip row for selected items

private struct FlowTagRow: View {
    let tags: [MultiSelectItem]
    let onRemove: (UUID) -> Void
    var customRemove: ((String) -> Void)? = nil

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.id) { tag in
                Button {
                    if let custom = customRemove { custom(tag.title) }
                    else { onRemove(tag.id) }
                } label: {
                    HStack(spacing: 4) {
                        if let hex = tag.colorHex, !hex.isEmpty {
                            Circle().fill(Color(hex: hex)).frame(width: 6, height: 6)
                        }
                        Text(tag.title)
                            .font(CentmondTheme.Typography.caption)
                            .lineLimit(1)
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(CentmondTheme.Colors.accentMuted)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// Minimal flow layout: lays children left-to-right, wraps to the next
// row when width is exceeded. No dep on an external package.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 4) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Deferred amount field — commits on blur/submit, not per keystroke

private struct DeferredAmountField: View {
    let placeholder: String
    @Binding var value: Decimal?

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("$")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(CentmondTheme.Typography.mono)
                .monospacedDigit()
                .focused($focused)
                .onSubmit { commit() }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(focused ? CentmondTheme.Colors.accent.opacity(0.5) : CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
        .onAppear { syncFromModel() }
        .onChange(of: value) { _, _ in
            if !focused { syncFromModel() }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func syncFromModel() {
        text = value.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parsed: Decimal? = trimmed.isEmpty ? nil : Decimal(string: trimmed)
        if parsed != value { value = parsed }
        syncFromModel()
    }
}

// MARK: - Button style dispatcher

private struct AnyButtonStyle: ButtonStyle {
    private let _make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        self._make = { cfg in AnyView(style.makeBody(configuration: cfg)) }
    }
    func makeBody(configuration: Configuration) -> some View { _make(configuration) }
}
