import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Subscription.nextPaymentDate) private var subscriptions: [Subscription]

    @State private var showDeleteConfirmation = false
    @State private var subscriptionToDelete: Subscription?
    @State private var selectedTab: Tab = .active
    @State private var buckets = Buckets()

    enum Tab: String, CaseIterable, Identifiable {
        case active, trial, paused, cancelled
        var id: String { rawValue }
        var label: String {
            switch self {
            case .active: "Active"
            case .trial: "Trials"
            case .paused: "Paused"
            case .cancelled: "Cancelled"
            }
        }
        var statusFilter: SubscriptionStatus {
            switch self {
            case .active: .active
            case .trial: .trial
            case .paused: .paused
            case .cancelled: .cancelled
            }
        }
    }

    /// Single-pass bucketing so body renders don't run 6 rescans (4 tab
    /// counts + monthlyTotal + annualTotal) over the full subscription
    /// array. One scan, two reduces, consumed by all downstream props.
    private struct Buckets {
        var active: [Subscription] = []
        var trial: [Subscription] = []
        var paused: [Subscription] = []
        var cancelled: [Subscription] = []
        var monthlyTotal: Decimal = 0
        var annualTotal: Decimal = 0
    }

    /// Subset of `subscriptions` that are still attached to a
    /// SwiftData context. Cloud-prune deletes (when iOS removes a
    /// subscription) leave tombstoned instances in the @Query array
    /// for one frame; reading `.status` / `.amount` / etc. on them
    /// faults. Filter once here and use this everywhere downstream.
    private var liveSubscriptions: [Subscription] {
        subscriptions.filter { $0.modelContext != nil && !$0.isDeleted }
    }

    /// Recompute `buckets` from current `subscriptions`. Called from .onChange
    /// modifiers so body renders only ever read the cached struct — no rescans.
    private func recomputeBuckets() {
        var b = Buckets()
        for sub in liveSubscriptions {
            switch sub.status {
            case .active:
                b.active.append(sub)
                b.monthlyTotal += sub.monthlyCost
                b.annualTotal += sub.annualCost
            case .trial:
                b.trial.append(sub)
                b.monthlyTotal += sub.monthlyCost
                b.annualTotal += sub.annualCost
            case .paused:
                b.paused.append(sub)
            case .cancelled:
                b.cancelled.append(sub)
            }
        }
        buckets = b
    }

    private var activeSubscriptions: [Subscription] { buckets.active }
    private var trialSubscriptions: [Subscription] { buckets.trial }
    private var pausedSubscriptions: [Subscription] { buckets.paused }
    private var cancelledSubscriptions: [Subscription] { buckets.cancelled }
    private var billableSubscriptions: [Subscription] { buckets.active + buckets.trial }
    private var annualTotal: Decimal { buckets.annualTotal }
    private var monthlyTotal: Decimal { buckets.monthlyTotal }

    private func count(for tab: Tab) -> Int {
        switch tab {
        case .active: return buckets.active.count
        case .trial: return buckets.trial.count
        case .paused: return buckets.paused.count
        case .cancelled: return buckets.cancelled.count
        }
    }

    private var gridSubscriptions: [Subscription] {
        liveSubscriptions
            .filter { $0.status == selectedTab.statusFilter }
            .sorted { $0.nextPaymentDate < $1.nextPaymentDate }
    }

    private var next7Total: Decimal {
        SubscriptionForecast.projected(for: liveSubscriptions, next: 7)
    }

    private var next30Charges: [SubscriptionForecast.UpcomingCharge] {
        let to = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
        return SubscriptionForecast.upcomingCharges(for: liveSubscriptions, from: .now, to: to)
    }

    private var selectedSubID: UUID? {
        if case .subscription(let id) = router.inspectorContext { return id }
        return nil
    }

    var body: some View {
        Group {
            if liveSubscriptions.isEmpty {
                EmptyStateView(
                    icon: "arrow.triangle.2.circlepath",
                    heading: "No subscriptions tracked",
                    description: "Scan your transactions for recurring patterns, or add subscriptions manually.",
                    primaryAction: "Detect from transactions",
                    secondaryAction: "Add Manually",
                    onPrimaryAction: { router.showSheet(.detectedSubscriptions) },
                    onSecondaryAction: { router.showSheet(.newSubscription) }
                )
            } else {
                VStack(spacing: 0) {
                    SectionTutorialStrip(screen: .subscriptions)
                        .padding(.horizontal, CentmondTheme.Spacing.lg)
                        .padding(.top, CentmondTheme.Spacing.sm)
                    heroSummary

                    SubscriptionInsightsStrip(subscriptions: liveSubscriptions)

                    if !next30Charges.isEmpty {
                        Divider().background(CentmondTheme.Colors.strokeSubtle)
                        upcomingTimeline
                    }

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    tabsRow

                    subscriptionGrid
                }
            }
        }
        .onAppear {
            // Opportunistic retroactive link — covers legacy transactions
            // that missed their initial reconciliation pass (e.g. subs
            // created pre-P1 with empty merchantKey). Cheap no-op when
            // everything is already matched.
            SubscriptionReconciliationService.reconcileAll(in: modelContext)
            SubscriptionNotificationScheduler.rescheduleAll(context: modelContext)
            recomputeBuckets()
        }
        .onChange(of: subscriptions.count) { _, _ in recomputeBuckets() }
        // Map over `liveSubscriptions` only — reading .status or
        // .monthlyCost on a tombstoned instance during the prune-
        // delete frame faults. The .count tracker above still
        // catches the structural change first; these triggers are
        // for in-place edits where count is stable.
        .onChange(of: liveSubscriptions.map(\.status)) { _, _ in recomputeBuckets() }
        .onChange(of: liveSubscriptions.map(\.monthlyCost)) { _, _ in recomputeBuckets() }
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

    // MARK: - Hero Summary

    /// Hub header: three big stats (Monthly / Annual / Next 7d) + action
    /// cluster (Detect, Add). Replaces the old compact summary bar so the
    /// Subscriptions page reads like a first-class pillar instead of a
    /// settings list.
    private var heroSummary: some View {
        HStack(spacing: CentmondTheme.Spacing.xxxl) {
            heroStat(label: "Monthly", value: CurrencyFormat.standard(monthlyTotal))
            heroStat(label: "Annual",  value: CurrencyFormat.standard(annualTotal))
            heroStat(label: "Next 7d", value: CurrencyFormat.standard(next7Total),
                     tint: next7Total > 0 ? CentmondTheme.Colors.warning : nil)
            Spacer()

            Button {
                router.showSheet(.detectedSubscriptions)
            } label: {
                Label("Detect", systemImage: "wand.and.stars")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .help("Scan transactions for recurring patterns")

            Button {
                router.showSheet(.newSubscription)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(AccentChipButtonStyle())
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.xl)
        .background(CentmondTheme.Colors.bgSecondary)
    }

    private func heroStat(label: String, value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(CentmondTheme.Typography.monoDisplay)
                .foregroundStyle(tint ?? CentmondTheme.Colors.textPrimary)
                .monospacedDigit()
        }
    }

    // MARK: - Tabs

    /// Status tabs that replace the old month-filter pills. Tabs are what
    /// subscription-tracker apps actually let users slice by — having seven
    /// Netflix charges in "March 2026" was never the right lens.
    private var tabsRow: some View {
        HStack(spacing: CentmondTheme.Spacing.xs) {
            ForEach(Tab.allCases) { tab in
                tabChip(tab)
            }
            Spacer()
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgPrimary)
    }

    private func tabChip(_ tab: Tab) -> some View {
        let isOn = selectedTab == tab
        let c = count(for: tab)
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Text(tab.label)
                    .font(CentmondTheme.Typography.bodyMedium)
                Text("\(c)")
                    .font(CentmondTheme.Typography.overlineSemibold.monospacedDigit())
                    .foregroundStyle(isOn ? CentmondTheme.Colors.bgPrimary : CentmondTheme.Colors.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(isOn ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.bgQuaternary))
            }
            .foregroundStyle(isOn ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textTertiary)
            .padding(.horizontal, CentmondTheme.Spacing.md)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isOn ? CentmondTheme.Colors.bgTertiary : Color.clear)
            )
            .overlay(
                Capsule().stroke(isOn ? CentmondTheme.Colors.strokeDefault : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private var subscriptionGrid: some View {
        Group {
            if gridSubscriptions.isEmpty {
                emptyTabState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg),
                            GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg),
                            GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg)
                        ],
                        spacing: CentmondTheme.Spacing.lg
                    ) {
                        ForEach(gridSubscriptions) { sub in
                            SubscriptionCard(
                                subscription: sub,
                                isSelected: selectedSubID == sub.id,
                                onTap: { router.inspectSubscription(sub.id) }
                            )
                            .contextMenu { contextMenu(for: sub) }
                        }
                    }
                    .padding(.horizontal, CentmondTheme.Spacing.xxl)
                    .padding(.vertical, CentmondTheme.Spacing.lg)
                }
            }
        }
    }

    private var emptyTabState: some View {
        VStack(spacing: CentmondTheme.Spacing.md) {
            Text("Nothing to show in \(selectedTab.label)")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            if selectedTab != .active {
                Button("Go to Active") { selectedTab = .active }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func contextMenu(for sub: Subscription) -> some View {
        Button {
            router.inspectSubscription(sub.id)
        } label: {
            Label("View Details", systemImage: "eye")
        }
        Button {
            router.showSheet(.editSubscription(sub))
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        Divider()
        Button {
            SubscriptionService.markPaid(sub, in: modelContext)
            Haptics.impact()
        } label: {
            Label("Mark Paid", systemImage: "checkmark.circle")
        }
        Divider()
        if sub.status == .active || sub.status == .trial {
            Button {
                sub.status = .paused
                sub.updatedAt = .now
            } label: {
                Label("Pause", systemImage: "pause.circle")
            }
        }
        if sub.status == .paused {
            Button {
                sub.status = .active
                sub.updatedAt = .now
            } label: {
                Label("Resume", systemImage: "play.circle")
            }
        }
        if sub.status != .cancelled {
            Button {
                sub.status = .cancelled
                sub.updatedAt = .now
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        }
        Divider()
        Button(role: .destructive) {
            subscriptionToDelete = sub
            showDeleteConfirmation = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Upcoming Timeline

    /// Horizontally-scrolling strip showing the next 30 days of projected
    /// charges. Uses `SubscriptionForecast` which projects forward from each
    /// active subscription's `nextPaymentDate`, repeating occurrences if the
    /// cadence fits inside the window.
    private var upcomingTimeline: some View {
        let charges = Array(next30Charges.prefix(12))
        return VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: "calendar")
                    .font(CentmondTheme.Typography.captionSmall)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Text("NEXT 30 DAYS")
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)
                Spacer()
                Text(CurrencyFormat.standard(SubscriptionForecast.total(for: next30Charges)))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    ForEach(charges) { charge in
                        upcomingChargeCard(charge)
                    }
                }
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgPrimary)
    }

    private func upcomingChargeCard(_ charge: SubscriptionForecast.UpcomingCharge) -> some View {
        let daysOut = max(Calendar.current.dateComponents([.day], from: .now, to: charge.date).day ?? 0, 0)
        let dayLabel: String = {
            if daysOut == 0 { return "Today" }
            if daysOut == 1 { return "Tomorrow" }
            return charge.date.formatted(.dateTime.month(.abbreviated).day())
        }()
        let tint: Color = daysOut <= 2
            ? CentmondTheme.Colors.warning
            : (daysOut <= 7 ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(dayLabel)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(tint)
            }
            Text(charge.displayName)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .lineLimit(1)
            if charge.isTrialEnd {
                Text("Trial ends")
                    .font(CentmondTheme.Typography.overlineSemibold)
                    .foregroundStyle(CentmondTheme.Colors.accent)
            } else {
                Text(CurrencyFormat.standard(charge.amount))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
        }
        .frame(width: 120, alignment: .leading)
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                .fill(CentmondTheme.Colors.bgSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

}
