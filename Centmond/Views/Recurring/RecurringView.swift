import SwiftUI
import SwiftData

struct RecurringView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringTransaction.nextOccurrence) private var items: [RecurringTransaction]
    @Query private var liveCategories: [BudgetCategory]

    private var liveCategoryIDs: Set<PersistentIdentifier> {
        Set(liveCategories.map(\.persistentModelID))
    }

    @State private var filterType: FilterType = .all
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: RecurringTransaction?
    @State private var showPaused = true
    @State private var pendingDetectedCount: Int = 0

    enum FilterType: String, CaseIterable {
        case all = "All"
        case income = "Income"
        case expense = "Expenses"
    }

    private var activeItems: [RecurringTransaction] { items.filter { $0.isActive } }
    private var pausedItems: [RecurringTransaction] { items.filter { !$0.isActive } }

    // MARK: - Month-aware filtering

    /// Active items that have an occurrence in the globally selected month.
    private var activeInSelectedMonth: [RecurringTransaction] {
        activeItems.filter {
            $0.frequency.occursInMonth(
                anchorDate: $0.nextOccurrence,
                monthStart: router.selectedMonthStart,
                monthEnd: router.selectedMonthEnd
            )
        }
    }

    private var filteredItems: [RecurringTransaction] {
        let s = router.selectedMonthStart, e = router.selectedMonthEnd
        var base: [RecurringTransaction]
        switch filterType {
        case .all:     base = showPaused ? items : activeItems
        case .income:  base = (showPaused ? items : activeItems).filter(\.isIncome)
        case .expense: base = (showPaused ? items : activeItems).filter { !$0.isIncome }
        }
        // Active items must occur in the selected month; paused always shown if enabled
        return base.filter { item in
            if !item.isActive { return showPaused }
            return item.frequency.occursInMonth(anchorDate: item.nextOccurrence, monthStart: s, monthEnd: e)
        }
    }

    /// Actual income cash-in for the selected month.
    private var incomeForSelectedMonth: Decimal {
        activeInSelectedMonth.filter(\.isIncome).reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// Actual expense cash-out for the selected month.
    private var expensesForSelectedMonth: Decimal {
        activeInSelectedMonth.filter { !$0.isIncome }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// Normalised monthly equivalent — used in the table "Monthly" column for reference.
    private func monthlyAmount(_ item: RecurringTransaction) -> Decimal {
        switch item.frequency {
        case .weekly:    item.amount * 52 / 12
        case .biweekly:  item.amount * 26 / 12
        case .monthly:   item.amount
        case .quarterly: item.amount / 3
        case .annual:    item.amount / 12
        }
    }

    @MainActor
    private func refreshPendingDetectedCount() {
        let detected = RecurringDetector.detect(context: modelContext)
        pendingDetectedCount = detected.filter { $0.confidence < RecurringDetector.effectiveAutoConfirmThreshold }.count
    }

    private func projectedOccurrence(for item: RecurringTransaction) -> Date? {
        guard item.isActive else { return nil }
        return item.frequency.projectedDate(
            anchorDate: item.nextOccurrence,
            monthStart: router.selectedMonthStart,
            monthEnd: router.selectedMonthEnd
        )
    }

    var body: some View {
        Group {
            if items.isEmpty {
                EmptyStateView(
                    icon: "repeat",
                    heading: "No recurring transactions",
                    description: "Add recurring income and expenses to track regular cash flow like rent, salary, and utilities.",
                    primaryAction: "Add Recurring",
                    onPrimaryAction: { router.showSheet(.newRecurring) }
                )
            } else {
                VStack(spacing: 0) {
                    summaryBar

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    ScrollView {
                        VStack(spacing: 0) {
                            RecurringForecastStrip(
                                templates: items,
                                onSelectTemplate: { template in
                                    router.showSheet(.editRecurring(template))
                                }
                            )

                            templatesSection
                        }
                    }
                }
            }
        }
        .onAppear { refreshPendingDetectedCount() }
        .onChange(of: items.count) { _, _ in refreshPendingDetectedCount() }
        .onChange(of: router.activeSheet?.id) { _, new in
            // After the detected-recurring sheet closes the user may have
            // confirmed or dismissed entries; refresh the chip count.
            if new == nil { refreshPendingDetectedCount() }
        }
        .alert("Delete Recurring Item", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { itemToDelete = nil }
            Button("Delete", role: .destructive) {
                if let item = itemToDelete {
                    modelContext.delete(item)
                }
                itemToDelete = nil
            }
        } message: {
            Text("Delete \"\(itemToDelete?.name ?? "")\"? This cannot be undone.")
        }
    }

    // MARK: - Summary

    private var summaryBar: some View {
        HStack(spacing: CentmondTheme.Spacing.xxxl) {
            summaryMetric(
                label: "Income",
                value: CurrencyFormat.compact(incomeForSelectedMonth),
                color: CentmondTheme.Colors.positive
            )
            summaryMetric(
                label: "Expenses",
                value: CurrencyFormat.compact(expensesForSelectedMonth),
                color: CentmondTheme.Colors.negative
            )

            let net = incomeForSelectedMonth - expensesForSelectedMonth
            summaryMetric(
                label: "Net",
                value: CurrencyFormat.compact(net),
                color: net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative
            )

            summaryMetric(
                label: "Due",
                value: "\(activeInSelectedMonth.count)",
                color: CentmondTheme.Colors.textSecondary
            )

            Spacer()

            Picker("", selection: $filterType) {
                ForEach(FilterType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            if !pausedItems.isEmpty {
                Toggle("Show paused", isOn: $showPaused)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            if router.isCurrentMonth {
                let upcomingWeek = activeInSelectedMonth.filter {
                    $0.nextOccurrence <= Calendar.current.date(byAdding: .day, value: 7, to: .now)!
                    && $0.nextOccurrence >= Calendar.current.startOfDay(for: .now)
                }
                if !upcomingWeek.isEmpty {
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CentmondTheme.Colors.warning)
                        Text("\(upcomingWeek.count) due this week")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.warning)
                    }
                }
            }

            // Automation status pill — replaces the old "Run Due" button.
            // The scheduler ticks on launch, scene-active transitions, and
            // every midnight, so there is nothing for the user to push.
            HStack(spacing: CentmondTheme.Spacing.xs) {
                Image(systemName: "bolt.badge.automatic.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(CentmondTheme.Colors.positive)
                Text("Auto")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(CentmondTheme.Colors.positive.opacity(0.10))
            .clipShape(Capsule())
            .help("Recurring transactions materialize automatically. Edit a template to change its schedule.")

            // Lower-confidence detection results — auto-confirmed templates
            // were already minted by the scheduler; this chip surfaces only
            // the items that need a human yes/no.
            if pendingDetectedCount > 0 {
                Button {
                    router.showSheet(.detectedRecurring)
                } label: {
                    Label("\(pendingDetectedCount) detected", systemImage: "wand.and.stars")
                }
                .buttonStyle(SecondaryChipButtonStyle())
                .help("Review patterns the detector found but isn't confident enough to add automatically")
            }

            Button {
                router.showSheet(.newRecurring)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(AccentChipButtonStyle())
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
    }

    private func summaryMetric(label: String, value: String, color: Color) -> some View {
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

    // MARK: - Table

    /// Templates list, demoted below the forecast strip and rendered
    /// inside the parent ScrollView (no nested scroll). Header doubles
    /// as the section title + template count.
    private var templatesSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Text("TEMPLATES")
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)
                Text("\(items.count)")
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                Spacer()
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.top, CentmondTheme.Spacing.lg)
            .padding(.bottom, CentmondTheme.Spacing.sm)

            HStack(spacing: 0) {
                tableHeader("Name", width: nil, alignment: .leading)
                tableHeader("Type", width: 80, alignment: .center)
                tableHeader("Frequency", width: 100, alignment: .leading)
                tableHeader("Next Due", width: 120, alignment: .leading)
                tableHeader("Amount", width: 100, alignment: .trailing)
                tableHeader("Monthly", width: 90, alignment: .trailing)
                tableHeader("Status", width: 80, alignment: .center)
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .frame(height: 32)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
            }

            if filteredItems.isEmpty {
                VStack(spacing: CentmondTheme.Spacing.md) {
                    Text("No matching templates")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    if !showPaused {
                        Button("Show Paused") { showPaused = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, CentmondTheme.Spacing.xxxl)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredItems) { item in
                        RecurringRow(
                            item: item,
                            monthlyAmount: monthlyAmount(item),
                            projectedOccurrence: projectedOccurrence(for: item),
                            liveCategoryIDs: liveCategoryIDs,
                            onToggleActive: { item.isActive.toggle() },
                            onEdit: { router.showSheet(.editRecurring(item)) },
                            onDelete: {
                                itemToDelete = item
                                showDeleteConfirmation = true
                            }
                        )
                    }
                }
            }
        }
    }

    private func tableHeader(_ title: String, width: CGFloat?, alignment: Alignment) -> some View {
        Group {
            if let width {
                Text(title.uppercased())
                    .frame(width: width, alignment: alignment)
            } else {
                Text(title.uppercased())
                    .frame(maxWidth: .infinity, alignment: alignment)
            }
        }
        .font(CentmondTheme.Typography.captionMedium)
        .foregroundStyle(CentmondTheme.Colors.textTertiary)
        .tracking(0.3)
    }
}

// MARK: - Row

struct RecurringRow: View {
    let item: RecurringTransaction
    let monthlyAmount: Decimal
    var projectedOccurrence: Date? = nil
    var liveCategoryIDs: Set<PersistentIdentifier> = []
    var onToggleActive: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var isHovered = false

    private var displayDate: Date { projectedOccurrence ?? item.nextOccurrence }

    private var isOverdue: Bool {
        item.isActive && displayDate < Calendar.current.startOfDay(for: .now)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Name
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: item.isIncome ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(item.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)

                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name)
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(item.isActive ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textTertiary)
                        .lineLimit(1)

                    if let cat = item.category, liveCategoryIDs.contains(cat.persistentModelID) {
                        Text(cat.name)
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Type
            Text(item.isIncome ? "Income" : "Expense")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(item.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((item.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
                .frame(width: 80)

            // Frequency
            Text(item.frequency.displayName)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .frame(width: 100, alignment: .leading)

            // Next due
            VStack(alignment: .leading, spacing: 0) {
                if !item.isActive {
                    Text("Paused")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                } else {
                    Text(displayDate.formatted(.dateTime.month(.abbreviated).day()))
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(isOverdue ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textSecondary)
                    if isOverdue {
                        Text("overdue")
                            .font(.system(size: 9))
                            .foregroundStyle(CentmondTheme.Colors.negative)
                    }
                }
            }
            .frame(width: 120, alignment: .leading)

            // Amount
            Text(CurrencyFormat.compact(item.amount))
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(item.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)

            // Monthly equivalent
            Text(CurrencyFormat.compact(monthlyAmount))
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)

            // Status
            HStack(spacing: CentmondTheme.Spacing.xs) {
                Circle()
                    .fill(item.isActive ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textTertiary)
                    .frame(width: 6, height: 6)
                Text(item.isActive ? "Active" : "Paused")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .frame(width: 80)
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .frame(height: 48)
        .background(isHovered ? CentmondTheme.Colors.bgQuaternary : .clear)
        .onHover { hovering in
            if hovering { Haptics.tick() }
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button { onToggleActive() } label: {
                Label(item.isActive ? "Pause" : "Resume", systemImage: item.isActive ? "pause.circle" : "play.circle")
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
