import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Subscription.nextPaymentDate) private var subscriptions: [Subscription]

    @State private var showDeleteConfirmation = false
    @State private var subscriptionToDelete: Subscription?
    @State private var showCancelled = true

    private var activeSubscriptions: [Subscription] { subscriptions.filter { $0.status == .active } }
    private var pausedSubscriptions: [Subscription] { subscriptions.filter { $0.status == .paused } }
    private var cancelledSubscriptions: [Subscription] { subscriptions.filter { $0.status == .cancelled } }
    private var annualTotal: Decimal { activeSubscriptions.reduce(Decimal.zero) { $0 + $1.annualCost } }

    /// Active subscriptions that have a payment in the globally selected month.
    private var activeInSelectedMonth: [Subscription] {
        activeSubscriptions.filter {
            $0.billingCycle.occursInMonth(
                anchorDate: $0.nextPaymentDate,
                monthStart: router.selectedMonthStart,
                monthEnd: router.selectedMonthEnd
            )
        }
    }

    /// Actual cash out for the selected month (sum of per-payment amounts, not monthly-normalised).
    private var totalForSelectedMonth: Decimal {
        activeInSelectedMonth.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var selectedSubID: UUID? {
        if case .subscription(let id) = router.inspectorContext { return id }
        return nil
    }

    var body: some View {
        Group {
            if subscriptions.isEmpty {
                EmptyStateView(
                    icon: "arrow.triangle.2.circlepath",
                    heading: "No subscriptions tracked",
                    description: "Add your recurring subscriptions to keep track of what you're paying for.",
                    primaryAction: "Add Subscription",
                    onPrimaryAction: { router.showSheet(.newSubscription) }
                )
            } else {
                VStack(spacing: 0) {
                    summaryBar

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    if displayedSubscriptions.isEmpty {
                        VStack(spacing: CentmondTheme.Spacing.md) {
                            Text("All subscriptions are cancelled")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            Button("Show Cancelled") {
                                showCancelled = true
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        subscriptionTable
                    }
                }
            }
        }
        .alert("Delete Subscription", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { subscriptionToDelete = nil }
            Button("Delete", role: .destructive) {
                if let sub = subscriptionToDelete {
                    if case .subscription(let id) = router.inspectorContext, id == sub.id {
                        router.inspectorContext = .none
                    }
                    modelContext.delete(sub)
                }
                subscriptionToDelete = nil
            }
        } message: {
            Text("Delete \"\(subscriptionToDelete?.serviceName ?? "")\"? This cannot be undone.")
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: CentmondTheme.Spacing.xxxl) {
            summaryMetric(
                label: router.selectedMonth.formatted(.dateTime.month(.abbreviated).year()),
                value: CurrencyFormat.standard(totalForSelectedMonth)
            )
            summaryMetric(label: "Annual", value: CurrencyFormat.standard(annualTotal))
            summaryMetric(label: "Due", value: "\(activeInSelectedMonth.count)")

            if !pausedSubscriptions.isEmpty {
                summaryMetric(label: "Paused", value: "\(pausedSubscriptions.count)")
            }

            Spacer()

            if router.isCurrentMonth {
                let upcoming = activeInSelectedMonth.filter {
                    $0.nextPaymentDate <= Calendar.current.date(byAdding: .day, value: 7, to: .now)!
                }
                if !upcoming.isEmpty {
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CentmondTheme.Colors.warning)
                        Text("\(upcoming.count) due this week")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.warning)
                    }
                }
            }

            if !cancelledSubscriptions.isEmpty {
                Toggle("Show cancelled", isOn: $showCancelled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Button {
                router.showSheet(.newSubscription)
            } label: {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Add")
                        .font(CentmondTheme.Typography.captionMedium)
                }
                .foregroundStyle(CentmondTheme.Colors.accent)
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .padding(.vertical, CentmondTheme.Spacing.sm)
                .background(CentmondTheme.Colors.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
    }

    private func summaryMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(CentmondTheme.Typography.monoLarge)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .monospacedDigit()
        }
    }

    // MARK: - Table

    /// Subscriptions to show for the selected month:
    /// - Active: only those with a payment scheduled in that month
    /// - Paused: always shown as context
    /// - Cancelled: only if showCancelled toggle is on
    private var displayedSubscriptions: [Subscription] {
        let s = router.selectedMonthStart
        let e = router.selectedMonthEnd
        return subscriptions.filter { sub in
            switch sub.status {
            case .active:
                return sub.billingCycle.occursInMonth(anchorDate: sub.nextPaymentDate, monthStart: s, monthEnd: e)
            case .paused:
                return true
            case .cancelled:
                return showCancelled
            }
        }
    }

    private func projectedPaymentDate(for sub: Subscription) -> Date? {
        guard sub.status == .active else { return nil }
        return sub.billingCycle.projectedDate(
            anchorDate: sub.nextPaymentDate,
            monthStart: router.selectedMonthStart,
            monthEnd: router.selectedMonthEnd
        )
    }

    private var subscriptionTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tableHeader("Service", width: nil, alignment: .leading)
                tableHeader("Category", width: 120, alignment: .leading)
                tableHeader("Cycle", width: 100, alignment: .leading)
                tableHeader("Next Payment", width: 120, alignment: .leading)
                tableHeader("Amount", width: 100, alignment: .trailing)
                tableHeader("Annual", width: 100, alignment: .trailing)
                tableHeader("Status", width: 80, alignment: .center)
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .frame(height: 32)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedSubscriptions) { sub in
                        SubscriptionRow(
                            subscription: sub,
                            projectedPaymentDate: projectedPaymentDate(for: sub),
                            isSelected: selectedSubID == sub.id,
                            onSelect: { router.inspectSubscription(sub.id) },
                            onEdit: { router.showSheet(.editSubscription(sub)) },
                            onPause: { sub.status = .paused },
                            onResume: { sub.status = .active },
                            onCancel: { sub.status = .cancelled },
                            onDelete: {
                                subscriptionToDelete = sub
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

// MARK: - Subscription Row

struct SubscriptionRow: View {
    let subscription: Subscription
    var projectedPaymentDate: Date? = nil
    let isSelected: Bool
    var onSelect: () -> Void
    var onEdit: () -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    var onCancel: () -> Void
    var onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Service name
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Circle()
                    .fill(isSelected ? CentmondTheme.Colors.accent.opacity(0.3) : CentmondTheme.Colors.accent.opacity(0.2))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Text(String(subscription.serviceName.prefix(1)))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CentmondTheme.Colors.accent)
                    }

                Text(subscription.serviceName)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(subscription.status == .cancelled ? CentmondTheme.Colors.textTertiary : CentmondTheme.Colors.textPrimary)
                    .strikethrough(subscription.status == .cancelled)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(subscription.categoryName)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)

            Text(subscription.billingCycle.displayName)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .frame(width: 100, alignment: .leading)

            nextPaymentText
                .frame(width: 120, alignment: .leading)

            Text(CurrencyFormat.standard(subscription.amount))
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)

            Text(CurrencyFormat.standard(subscription.annualCost))
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)

            statusDot
                .frame(width: 80)
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .frame(height: 44)
        .background(
            isSelected ? CentmondTheme.Colors.accentMuted :
            isHovered ? CentmondTheme.Colors.bgQuaternary : .clear
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(CentmondTheme.Colors.accent).frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
        .contextMenu {
            Button { onSelect() } label: {
                Label("View Details", systemImage: "eye")
            }
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            if subscription.status == .active {
                Button { onPause() } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                Button { onCancel() } label: {
                    Label("Cancel Subscription", systemImage: "xmark.circle")
                }
            } else if subscription.status == .paused {
                Button { onResume() } label: {
                    Label("Resume", systemImage: "play.circle")
                }
                Button { onCancel() } label: {
                    Label("Cancel Subscription", systemImage: "xmark.circle")
                }
            } else {
                Button { onResume() } label: {
                    Label("Reactivate", systemImage: "arrow.uturn.backward")
                }
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var nextPaymentText: some View {
        if subscription.status == .cancelled {
            Text("—")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
        } else if subscription.status == .paused {
            Text("Paused")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.warning)
        } else {
            let displayDate = projectedPaymentDate ?? subscription.nextPaymentDate
            let isOverdue = displayDate < .now
            let daysUntil = Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: .now),
                to: Calendar.current.startOfDay(for: displayDate)
            ).day ?? 0
            VStack(alignment: .leading, spacing: 0) {
                Text(displayDate.formatted(.dateTime.month(.abbreviated).day()))
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(isOverdue ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textSecondary)
                if isOverdue {
                    Text("overdue")
                        .font(.system(size: 9))
                        .foregroundStyle(CentmondTheme.Colors.negative)
                } else if daysUntil <= 3 && daysUntil >= 0 {
                    Text("in \(daysUntil)d")
                        .font(.system(size: 9))
                        .foregroundStyle(CentmondTheme.Colors.warning)
                }
            }
        }
    }

    private var statusDot: some View {
        HStack(spacing: CentmondTheme.Spacing.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(subscription.status.displayName)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
    }

    private var statusColor: Color {
        switch subscription.status {
        case .active: CentmondTheme.Colors.positive
        case .paused: CentmondTheme.Colors.warning
        case .cancelled: CentmondTheme.Colors.negative
        }
    }
}
