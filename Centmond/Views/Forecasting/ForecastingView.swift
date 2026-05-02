import SwiftUI
import SwiftData
import Charts

struct ForecastingView: View {
    @Environment(AppRouter.self) private var router
    @Query private var transactions: [Transaction]
    @Query(sort: \RecurringTransaction.nextOccurrence) private var recurringItems: [RecurringTransaction]
    @Query private var subscriptions: [Subscription]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var goals: [Goal]

    @State private var forecastDays: Int = 30
    @State private var scenario = ForecastEngine.Scenario()
    @State private var simulatorOpen = false

    // MARK: - Snapshot cache
    //
    // The body referenced `horizon.summary.xxx` ~10 times per render, and
    // every reference re-ran ForecastEngine.build() (full simulator run).
    // Snapshot captures horizon + scenarioHorizon + the 4 monthly decimals
    // so body reads are O(1). Rebuilt only when @Query data, forecastDays,
    // or scenario changes.
    @State private var snapshot = ForecastSnapshot()

    struct ForecastSnapshot {
        var horizon: ForecastEngine.Horizon?
        var scenarioHorizon: ForecastEngine.Horizon?
        var monthlyIncome: Decimal = 0
        var monthlySpending: Decimal = 0
        var upcomingBills: Decimal = 0
        var expectedIncome: Decimal = 0
        var totalBalance: Decimal = 0
    }

    private let calendar = Calendar.current

    // MARK: - Computed Data

    private var startOfMonth: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: .now))!
    }
    private var endOfMonth: Date {
        calendar.date(byAdding: DateComponents(month: 1, day: -1), to: startOfMonth)!
    }
    private var daysLeftInMonth: Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: endOfMonth).day ?? 0)
    }

    private var monthlyIncome: Decimal { snapshot.monthlyIncome }
    private var monthlySpending: Decimal { snapshot.monthlySpending }
    private var upcomingBills: Decimal { snapshot.upcomingBills }
    private var expectedIncome: Decimal { snapshot.expectedIncome }

    private var safeToSpend: Decimal {
        snapshot.monthlyIncome + snapshot.expectedIncome - snapshot.monthlySpending - snapshot.upcomingBills
    }

    private var safeToSpendColor: Color {
        if safeToSpend < 0 { return CentmondTheme.Colors.negative }
        if monthlyIncome <= 0 { return CentmondTheme.Colors.warning }
        let ratio = Double(truncating: (safeToSpend / monthlyIncome) as NSDecimalNumber)
        if ratio > 0.2 { return CentmondTheme.Colors.positive }
        if ratio > 0.05 { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.negative
    }

    private var dailyBudget: Decimal {
        daysLeftInMonth > 0 ? safeToSpend / Decimal(daysLeftInMonth) : 0
    }

    private var totalBalance: Decimal { snapshot.totalBalance }

    private func rebuildSnapshot() {
        let now = Date.now
        let som = startOfMonth
        let eom = endOfMonth

        var mIncome: Decimal = 0
        var mSpending: Decimal = 0
        for tx in transactions where tx.date >= som && tx.date <= now {
            if BalanceService.isSpendingIncome(tx) { mIncome += tx.amount }
            else if BalanceService.isSpendingExpense(tx) { mSpending += tx.amount }
        }

        var bills: Decimal = 0
        for sub in subscriptions where sub.status == .active && sub.nextPaymentDate > now && sub.nextPaymentDate <= eom {
            bills += sub.amount
        }
        var recurringBills: Decimal = 0
        var expected: Decimal = 0
        for r in recurringItems where r.isActive && r.nextOccurrence > now && r.nextOccurrence <= eom {
            if r.isIncome { expected += r.amount } else { recurringBills += r.amount }
        }
        let balance = accounts
            .filter { !$0.isArchived && !$0.isClosed && $0.includeInNetWorth }
            .reduce(Decimal.zero) { $0 + $1.currentBalance }

        let inputs = ForecastEngine.Inputs(
            startingBalance: balance,
            subscriptions: subscriptions,
            recurring: recurringItems,
            goals: goals,
            history: transactions
        )
        let built = ForecastEngine.build(inputs, horizonDays: forecastDays)
        let scen = scenario.isIdentity ? nil : ForecastEngine.build(inputs, horizonDays: forecastDays, scenario: scenario)

        var next = ForecastSnapshot()
        next.monthlyIncome = mIncome
        next.monthlySpending = mSpending
        next.upcomingBills = bills + recurringBills
        next.expectedIncome = expected
        next.totalBalance = balance
        next.horizon = built
        next.scenarioHorizon = scen
        snapshot = next
    }

    var body: some View {
        ScrollView {
            VStack(spacing: CentmondTheme.Spacing.xxl) {
                SectionTutorialStrip(screen: .forecasting)
                riskStrip
                safeToSpendHero
                monthlyBreakdownScroller
                forecastChart
                simulatorPanel
                upcomingObligations
            }
            .padding(CentmondTheme.Spacing.xxl)
        }
        // .task (not .onAppear) so tab-switch paints first, then work runs
        .task { rebuildSnapshot() }
        // Collapsed from 7 modifiers. Same fix as DashboardView/BudgetView:
        // each `.map(\.amount)` allocated a [Decimal] of every row on every
        // body render. Single Equatable struct + per-query reduces drops the
        // allocations and replaces array equality with O(1) struct equality.
        // ForecastEngine.build is unchanged — gating happens here so it only
        // re-runs when its inputs would actually produce a different result.
        .onChange(of: forecastChangeKey) { _, _ in rebuildSnapshot() }
    }

    private struct ForecastChangeKey: Equatable {
        var txCount: Int
        var txAmountSum: Decimal
        var subCount: Int
        var subAmountSum: Decimal
        var recurringCount: Int
        var recurringAmountSum: Decimal
        var accountCount: Int
        var accountBalanceSum: Decimal
        var goalCount: Int
        var forecastDays: Int
        var scenario: ForecastEngine.Scenario
    }

    private var forecastChangeKey: ForecastChangeKey {
        ForecastChangeKey(
            txCount: transactions.count,
            txAmountSum: transactions.reduce(Decimal.zero) { $0 + $1.amount },
            subCount: subscriptions.count,
            subAmountSum: subscriptions.reduce(Decimal.zero) { $0 + $1.amount },
            recurringCount: recurringItems.count,
            recurringAmountSum: recurringItems.reduce(Decimal.zero) { $0 + $1.amount },
            accountCount: accounts.count,
            accountBalanceSum: accounts.reduce(Decimal.zero) { $0 + $1.currentBalance },
            goalCount: goals.count,
            forecastDays: forecastDays,
            scenario: scenario
        )
    }

    // MARK: - Monthly Breakdown Cards

    private var monthlyBreakdownScroller: some View {
        let months = horizon.monthlyBreakdown()
        return VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack {
                Text("Month by Month")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Spacer()
                Text("\(months.count) month\(months.count == 1 ? "" : "s") in view")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
                    ForEach(months) { month in
                        MonthBreakdownCard(month: month)
                            .frame(width: 260)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Risk & Runway strip

    private var riskStrip: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            stripCard(
                label: "SAFE TO SPEND",
                value: CurrencyFormat.compact(safeToSpend),
                caption: "\(daysLeftInMonth) days left",
                color: safeToSpendColor,
                icon: "wallet.pass"
            )
            stripCard(
                label: "RUNWAY",
                value: runwayDisplay,
                caption: runwayCaption,
                color: runwayColor,
                icon: "hourglass"
            )
            stripCard(
                label: "LOWEST POINT",
                value: CurrencyFormat.compact(horizon.summary.lowestExpectedBalance),
                caption: horizon.summary.lowestExpectedBalanceDate.formatted(.dateTime.month(.abbreviated).day()),
                color: horizon.summary.lowestExpectedBalance < 0 ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textPrimary,
                icon: "arrow.down.to.line"
            )
            stripCard(
                label: "OUTLOOK",
                value: outlookLabel,
                caption: outlookCaption,
                color: outlookColor,
                icon: outlookIcon
            )
        }
    }

    private func stripCard(label: String, value: String, caption: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .font(CentmondTheme.Typography.captionSmall)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                Text(label)
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .tracking(0.5)
            }
            Text(value)
                .font(CentmondTheme.Typography.monoLarge)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .lineLimit(1)
        }
        .padding(CentmondTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    // Runway: if balance eventually dips below zero inside the horizon,
    // report the distance in days. Otherwise compute "days until zero at
    // today's average burn rate" — gives a meaningful number even when
    // obligations are sparse but discretionary spend is continuous.
    private var runwayDays: Int? {
        if let neg = horizon.summary.firstExpectedNegativeDate {
            return calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: neg).day
        }
        let avgBurn = (horizon.summary.totalProjectedObligations + horizon.summary.totalProjectedDiscretionary)
            - horizon.summary.totalProjectedIncome
        let burnPerDay = Double(truncating: avgBurn as NSDecimalNumber) / Double(max(1, horizon.summary.horizonDays))
        guard burnPerDay > 0 else { return nil }
        let start = Double(truncating: horizon.summary.startingBalance as NSDecimalNumber)
        guard start > 0 else { return 0 }
        return Int(start / burnPerDay)
    }

    private var runwayDisplay: String {
        guard let d = runwayDays else { return "∞" }
        if d <= 0 { return "0d" }
        if d >= 365 { return "1y+" }
        return "\(d)d"
    }

    private var runwayCaption: String {
        if horizon.summary.firstExpectedNegativeDate != nil { return "until overdraft" }
        if runwayDays == nil { return "income ≥ burn" }
        return "at current burn"
    }

    private var runwayColor: Color {
        guard let d = runwayDays else { return CentmondTheme.Colors.positive }
        if d < 14 { return CentmondTheme.Colors.negative }
        if d < 45 { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.textPrimary
    }

    private var outlookLabel: String {
        if horizon.summary.firstExpectedNegativeDate != nil { return "At risk" }
        if horizon.summary.firstAtRiskDate != nil { return "Tight" }
        return "On track"
    }

    private var outlookCaption: String {
        if let d = horizon.summary.firstAtRiskDate {
            return "tight around \(d.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return "cone stays positive"
    }

    private var outlookColor: Color {
        if horizon.summary.firstExpectedNegativeDate != nil { return CentmondTheme.Colors.negative }
        if horizon.summary.firstAtRiskDate != nil { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.positive
    }

    private var outlookIcon: String {
        if horizon.summary.firstExpectedNegativeDate != nil { return "exclamationmark.triangle" }
        if horizon.summary.firstAtRiskDate != nil { return "exclamationmark.circle" }
        return "checkmark.seal"
    }

    // MARK: - Safe to Spend Hero

    private var safeToSpendHero: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            // Main number
            VStack(spacing: CentmondTheme.Spacing.sm) {
                Text("SAFE TO SPEND")
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(1)

                Text(CurrencyFormat.compact(safeToSpend))
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .foregroundStyle(safeToSpendColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: safeToSpend)

                Text("remaining this month (\(daysLeftInMonth) days left)")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }

            // Daily budget callout
            if safeToSpend > 0 && daysLeftInMonth > 0 {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(CentmondTheme.Colors.accent)
                    Text("Daily budget: \(CurrencyFormat.compact(dailyBudget))/day")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.vertical, CentmondTheme.Spacing.sm)
                .background(CentmondTheme.Colors.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Breakdown row
            HStack(spacing: CentmondTheme.Spacing.xxxl) {
                miniStat(label: "Income Received", value: CurrencyFormat.compact(monthlyIncome), color: CentmondTheme.Colors.positive)
                miniStat(label: "Spent So Far", value: CurrencyFormat.compact(monthlySpending), color: CentmondTheme.Colors.negative)
                miniStat(label: "Upcoming Bills", value: CurrencyFormat.compact(upcomingBills), color: CentmondTheme.Colors.warning)
                if expectedIncome > 0 {
                    miniStat(label: "Expected Income", value: CurrencyFormat.compact(expectedIncome), color: CentmondTheme.Colors.positive.opacity(0.6))
                }
            }
            .padding(.top, CentmondTheme.Spacing.xs)

            // Explanation
            VStack(spacing: 2) {
                Text("= Income Received\(expectedIncome > 0 ? " + Expected Income" : "") \u{2212} Spent \u{2212} Upcoming Bills")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                if expectedIncome > 0 {
                    Text("Expected income is based on recurring income items due before month-end")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
        }
        .padding(CentmondTheme.Spacing.xxl)
        .frame(maxWidth: .infinity)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    private func miniStat(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(CentmondTheme.Typography.monoLarge)
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(CentmondTheme.Motion.numeric, value: value)
        }
    }

    // MARK: - Forecast Chart

    private var horizon: ForecastEngine.Horizon {
        snapshot.horizon ?? ForecastEngine.build(
            ForecastEngine.Inputs(
                startingBalance: snapshot.totalBalance,
                subscriptions: subscriptions,
                recurring: recurringItems,
                goals: goals,
                history: transactions
            ),
            horizonDays: forecastDays
        )
    }

    private var scenarioHorizon: ForecastEngine.Horizon? { snapshot.scenarioHorizon }

    private var forecastChart: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Runway")
                            .font(CentmondTheme.Typography.heading3)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Text("Projected balance with confidence band")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }

                    Spacer()

                    Picker("Days", selection: $forecastDays) {
                        Text("30D").tag(30)
                        Text("60D").tag(60)
                        Text("90D").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                ForecastRunwayChartSurface(horizon: horizon, scenarioHorizon: scenarioHorizon)
                    .frame(height: 320)
                    .animation(CentmondTheme.Motion.layout, value: forecastDays)

                runwayLegend
            }
        }
    }

    private var runwayLegend: some View {
        HStack(spacing: CentmondTheme.Spacing.lg) {
            legendSwatch(color: CentmondTheme.Colors.accent, label: "Expected")
            legendSwatch(color: CentmondTheme.Colors.accent.opacity(0.25), label: "Typical range")
            legendSwatch(color: CentmondTheme.Colors.negative, label: "Bill / sub")
            legendSwatch(color: CentmondTheme.Colors.positive, label: "Income")
            legendSwatch(color: CentmondTheme.Colors.warning, label: "Goal")
            Spacer()
        }
        .font(CentmondTheme.Typography.caption)
        .foregroundStyle(CentmondTheme.Colors.textTertiary)
    }

    private func legendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    // MARK: - What-If Simulator

    private var simulatorPanel: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(CentmondTheme.Colors.accent)
                    Text("What-If Simulator")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    if let delta = scenarioEndDelta {
                        HStack(spacing: 4) {
                            Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(CentmondTheme.Typography.overlineSemibold)
                            Text(CurrencyFormat.compact(delta))
                                .monospacedDigit()
                        }
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(delta >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background((delta >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative).opacity(0.12))
                        .clipShape(Capsule())
                    }
                    Button {
                        scenario = ForecastEngine.Scenario()
                    } label: {
                        Text("Reset")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(scenario.isIdentity ? CentmondTheme.Colors.textQuaternary : CentmondTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(scenario.isIdentity)
                }

                Text("Toggle changes and watch the ghost line show your baseline vs the new path.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)

                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                    if subscriptions.contains(where: { $0.status == .active }) {
                        scenarioToggle(
                            title: "Cancel all subscriptions",
                            isOn: Binding(
                                get: { scenario.skippedSubscriptionIDs == Set(subscriptions.map(\.id)) && !subscriptions.isEmpty },
                                set: { newValue in
                                    scenario.skippedSubscriptionIDs = newValue ? Set(subscriptions.map(\.id)) : []
                                }
                            )
                        )
                    }
                    if goals.contains(where: { $0.status == .active && ($0.monthlyContribution ?? 0) > 0 }) {
                        scenarioToggle(
                            title: "Pause all goal contributions",
                            isOn: Binding(
                                get: { scenario.skippedGoalIDs == Set(goals.map(\.id)) && !goals.isEmpty },
                                set: { newValue in
                                    scenario.skippedGoalIDs = newValue ? Set(goals.map(\.id)) : []
                                }
                            )
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Typical spend")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            Spacer()
                            Text("\(Int(scenario.spendMultiplier * 100))%")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                                .monospacedDigit()
                        }
                        Slider(value: $scenario.spendMultiplier, in: 0.5...1.5, step: 0.05)
                            .tint(CentmondTheme.Colors.accent)
                        HStack {
                            Text("50%")
                            Spacer()
                            Text("100%")
                            Spacer()
                            Text("150%")
                        }
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                }
            }
        }
    }

    private func scenarioToggle(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(CentmondTheme.Colors.accent)
    }

    private var scenarioEndDelta: Decimal? {
        guard let scenarioHorizon else { return nil }
        return scenarioHorizon.summary.endingExpectedBalance - horizon.summary.endingExpectedBalance
    }

    // MARK: - Event Timeline

    @State private var timelineFilter: TimelineFilter = .all

    enum TimelineFilter: String, CaseIterable, Identifiable {
        case all, bills, subs, income, goals
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:    return "All"
            case .bills:  return "Bills"
            case .subs:   return "Subs"
            case .income: return "Income"
            case .goals:  return "Goals"
            }
        }
        func matches(_ kind: ForecastEngine.EventKind) -> Bool {
            switch (self, kind) {
            case (.all, _): return true
            case (.bills, .recurringBill): return true
            case (.subs, .subscription): return true
            case (.income, .recurringIncome): return true
            case (.goals, .goalContribution): return true
            default: return false
            }
        }
    }

    private var upcomingObligations: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text("Event Timeline")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    let visible = visibleEvents()
                    let outflow = visible.filter { $0.delta < 0 }.reduce(Decimal.zero) { $0 - $1.delta }
                    if outflow > 0 {
                        Text("Out: \(CurrencyFormat.compact(outflow))")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.negative)
                            .monospacedDigit()
                    }
                }

                filterChips

                let groups = weeklyGroups(visibleEvents())

                if groups.isEmpty {
                    Text("No events in the next \(forecastDays) days for this filter")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .padding(.vertical, CentmondTheme.Spacing.lg)
                } else {
                    ForEach(groups, id: \.label) { group in
                        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                            HStack {
                                Text(group.label)
                                    .font(CentmondTheme.Typography.captionMedium)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .textCase(.uppercase)
                                Spacer()
                                let net = group.events.reduce(Decimal.zero) { $0 + $1.delta }
                                Text(CurrencyFormat.compact(net))
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textTertiary)
                                    .monospacedDigit()
                            }

                            ForEach(group.events) { event in
                                eventRow(event)
                            }
                        }
                        if group.label != groups.last?.label {
                            Divider().background(CentmondTheme.Colors.strokeSubtle)
                        }
                    }
                }
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: CentmondTheme.Spacing.xs) {
            ForEach(TimelineFilter.allCases) { filter in
                let active = filter == timelineFilter
                Button {
                    timelineFilter = filter
                } label: {
                    Text(filter.label)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(active ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(active ? CentmondTheme.Colors.accent.opacity(0.15) : CentmondTheme.Colors.bgTertiary)
                        .overlay(
                            Capsule().stroke(active ? CentmondTheme.Colors.accent.opacity(0.5) : CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func eventRow(_ event: ForecastEngine.Event) -> some View {
        let kindColor = eventColor(event.kind)
        return HStack(spacing: CentmondTheme.Spacing.sm) {
            ZStack {
                Circle().fill(kindColor.opacity(0.12)).frame(width: 28, height: 28)
                Image(systemName: event.iconSymbol)
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(kindColor)
            }

            Text(event.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .frame(width: 96, alignment: .leading)

            Text(event.name)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .lineLimit(1)

            Text(kindLabel(event.kind))
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(kindColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(kindColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))

            Spacer()

            Text(CurrencyFormat.compact(event.delta))
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(event.delta > 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                .monospacedDigit()
        }
        .padding(.vertical, CentmondTheme.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            openEventSource(event)
        }
    }

    private func eventColor(_ kind: ForecastEngine.EventKind) -> Color {
        switch kind {
        case .subscription, .recurringBill: return CentmondTheme.Colors.negative
        case .recurringIncome:              return CentmondTheme.Colors.positive
        case .goalContribution:             return CentmondTheme.Colors.warning
        }
    }

    private func kindLabel(_ kind: ForecastEngine.EventKind) -> String {
        switch kind {
        case .subscription:     return "Subscription"
        case .recurringBill:    return "Bill"
        case .recurringIncome:  return "Income"
        case .goalContribution: return "Goal"
        }
    }

    private func openEventSource(_ event: ForecastEngine.Event) {
        guard let id = event.sourceID else { return }
        switch event.kind {
        case .subscription:
            if let sub = subscriptions.first(where: { $0.id == id }) {
                router.showSheet(.editSubscription(sub))
            }
        case .recurringBill, .recurringIncome:
            if let rec = recurringItems.first(where: { $0.id == id }) {
                router.showSheet(.editRecurring(rec))
            }
        case .goalContribution:
            if let goal = goals.first(where: { $0.id == id }) {
                router.showSheet(.editGoal(goal))
            }
        }
    }

    private func visibleEvents() -> [ForecastEngine.Event] {
        horizon.days.flatMap { $0.events }
            .filter { timelineFilter.matches($0.kind) }
            .sorted { $0.date < $1.date }
    }

    private struct EventGroup {
        let label: String
        let events: [ForecastEngine.Event]
    }

    private func weeklyGroups(_ events: [ForecastEngine.Event]) -> [EventGroup] {
        var groups: [(label: String, events: [ForecastEngine.Event])] = []
        let today = calendar.startOfDay(for: .now)
        for event in events {
            let daysAway = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: event.date)).day ?? 0
            let label: String
            if daysAway <= 7 { label = "This Week" }
            else if daysAway <= 14 { label = "Next Week" }
            else if daysAway <= 30 { label = "This Month" }
            else { label = "Later" }
            if let i = groups.firstIndex(where: { $0.label == label }) {
                groups[i].events.append(event)
            } else {
                groups.append((label, [event]))
            }
        }
        return groups.map { EventGroup(label: $0.label, events: $0.events) }
    }

    // MARK: - Helpers


}

// MARK: - Month breakdown card

private struct MonthBreakdownCard: View {
    let month: ForecastEngine.MonthSummary

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(month.monthStart.formatted(.dateTime.month(.wide)))
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(month.monthStart.formatted(.dateTime.year()))
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Spacer()
                riskChip
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            VStack(alignment: .leading, spacing: 6) {
                row(label: "Income",       value: month.income,       color: CentmondTheme.Colors.positive, sign: "+")
                row(label: "Bills",        value: month.obligations,  color: CentmondTheme.Colors.negative, sign: "−")
                row(label: "Typical spend",value: month.discretionary,color: CentmondTheme.Colors.negative.opacity(0.75), sign: "−")
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NET")
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .tracking(0.5)
                    Text(CurrencyFormat.compact(month.net))
                        .font(CentmondTheme.Typography.monoLarge)
                        .foregroundStyle(month.net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("END BALANCE")
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .tracking(0.5)
                    Text(CurrencyFormat.compact(month.endingBalance))
                        .font(CentmondTheme.Typography.monoLarge)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }
            }

            // Always render a fixed-height "Biggest" footer row — even when
            // there's no standout event — so sibling cards in the horizontal
            // scroller all end at the same vertical baseline. Previously
            // this block was conditional, which made cards with a biggest
            // event visibly taller than ones without (e.g. April vs May).
            HStack(spacing: 6) {
                if let big = month.biggestEvent {
                    Image(systemName: big.iconSymbol)
                        .font(CentmondTheme.Typography.captionSmall)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Text("Biggest: \(big.name)")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(CurrencyFormat.compact(big.delta))
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                        .monospacedDigit()
                } else {
                    Image(systemName: "minus.circle")
                        .font(CentmondTheme.Typography.captionSmall)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    Text("No standout expense")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .frame(height: 20)
            .padding(.top, 2)
        }
        .padding(CentmondTheme.Spacing.lg)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .stroke(riskStrokeColor, lineWidth: 1)
        )
    }

    private var riskChip: some View {
        let (label, color): (String, Color) = {
            switch month.risk {
            case .healthy:   return ("On track", CentmondTheme.Colors.positive)
            case .tight:     return ("Tight",     CentmondTheme.Colors.warning)
            case .overdraft: return ("At risk",   CentmondTheme.Colors.negative)
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    private var riskStrokeColor: Color {
        switch month.risk {
        case .healthy:   return CentmondTheme.Colors.strokeSubtle
        case .tight:     return CentmondTheme.Colors.warning.opacity(0.35)
        case .overdraft: return CentmondTheme.Colors.negative.opacity(0.5)
        }
    }

    private func row(label: String, value: Decimal, color: Color, sign: String) -> some View {
        HStack {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Spacer()
            Text("\(sign)\(CurrencyFormat.compact(value))")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }
}

// MARK: - Runway chart surface (owns hover state per feedback_hover_state_scope.md)

private struct ForecastRunwayChartSurface: View {
    let horizon: ForecastEngine.Horizon
    let scenarioHorizon: ForecastEngine.Horizon?

    @State private var hoveredOffset: Int?
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        Chart {
            // --- Confidence band (discretionary σ) ---
            ForEach(horizon.days, id: \.dayOffset) { day in
                AreaMark(
                    x: .value("Day", day.dayOffset),
                    yStart: .value("Low",  double(day.lowBalance)),
                    yEnd:   .value("High", double(day.highBalance))
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [CentmondTheme.Colors.accent.opacity(0.22),
                                 CentmondTheme.Colors.accent.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
            }

            // --- Expected balance line (ghost when scenario is active) ---
            ForEach(horizon.days, id: \.dayOffset) { day in
                LineMark(
                    x: .value("Day", day.dayOffset),
                    y: .value("Balance", double(day.expectedBalance)),
                    series: .value("Series", "baseline")
                )
                .foregroundStyle(CentmondTheme.Colors.accent.opacity(scenarioHorizon == nil ? 1.0 : 0.4))
                .lineStyle(
                    scenarioHorizon == nil
                        ? StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round)
                        : StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 4])
                )
                .interpolationMethod(.monotone)
            }

            // --- Scenario line (vivid overlay) ---
            if let s = scenarioHorizon {
                ForEach(s.days, id: \.dayOffset) { day in
                    LineMark(
                        x: .value("Day", day.dayOffset),
                        y: .value("Balance", double(day.expectedBalance)),
                        series: .value("Series", "scenario")
                    )
                    .foregroundStyle(CentmondTheme.Colors.positive)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }
            }

            // --- Zero line ---
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(CentmondTheme.Colors.negative.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // --- Event dots on the expected line ---
            ForEach(eventMarks, id: \.id) { ev in
                PointMark(
                    x: .value("Day", ev.dayOffset),
                    y: .value("Balance", ev.y)
                )
                .foregroundStyle(ev.color)
                .symbolSize(42)
            }

            // --- Lowest-point marker ---
            if horizon.summary.lowestExpectedBalance < horizon.summary.startingBalance {
                let low = horizon.summary.lowestExpectedBalance
                let dayOffset = Calendar.current.dateComponents(
                    [.day],
                    from: Calendar.current.startOfDay(for: horizon.days.first?.date ?? .now),
                    to: Calendar.current.startOfDay(for: horizon.summary.lowestExpectedBalanceDate)
                ).day ?? 0
                PointMark(
                    x: .value("Day", dayOffset),
                    y: .value("Balance", double(low))
                )
                .foregroundStyle(CentmondTheme.Colors.warning)
                .symbolSize(80)
                .symbol(.diamond)
                .annotation(position: .bottom, alignment: .center, spacing: 4) {
                    Text("low · \(CurrencyFormat.compact(low))")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.warning)
                }
            }

            // --- Hover vertical line ---
            // Note: NO hover PointMark here. Stacking an accent dot on
            // top of an event dot (red/green/orange) creates a z-fight
            // that flickers every hover frame. The RuleMark alone gives
            // enough visual feedback, and event dots keep their color.
            if let offset = hoveredOffset {
                RuleMark(x: .value("Day", offset))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(CurrencyFormat.abbreviated(v))
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.4))
            }
        }
        .chartXAxis {
            AxisMarks(values: xAxisValues) { value in
                AxisValueLabel {
                    if let d = value.as(Int.self) {
                        Text(xLabel(for: d))
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.25))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                guard let plotFrameAnchor = proxy.plotFrame else {
                                    if hoveredOffset != nil { hoveredOffset = nil }
                                    return
                                }
                                let plot = geo[plotFrameAnchor]
                                let xInPlot = loc.x - plot.origin.x
                                guard xInPlot >= 0, xInPlot <= plot.width else {
                                    if hoveredOffset != nil { hoveredOffset = nil }
                                    return
                                }
                                guard let day: Int = proxy.value(atX: xInPlot) else { return }
                                let clamped = min(max(day, 0), horizon.summary.horizonDays)
                                if hoveredOffset != clamped {
                                    hoveredOffset = clamped
                                }
                                // Cursor position updates every frame so
                                // the tooltip can track the mouse. Only
                                // `hoveredOffset` goes through change-
                                // detection — this one is visual only.
                                hoverLocation = loc
                            case .ended:
                                if hoveredOffset != nil { hoveredOffset = nil }
                            }
                        }

                    // Tooltip follows the cursor, clamped inside the
                    // chart overlay so it never clips off the side.
                    if hoveredOffset != nil {
                        hoverTooltip
                            .fixedSize()
                            .background(
                                GeometryReader { tipGeo in
                                    Color.clear.preference(
                                        key: TooltipSizeKey.self,
                                        value: tipGeo.size
                                    )
                                }
                            )
                            .offset(
                                x: clampedTooltipX(
                                    cursorX: hoverLocation.x,
                                    containerWidth: geo.size.width,
                                    tipWidth: tooltipSize.width
                                ),
                                y: clampedTooltipY(
                                    cursorY: hoverLocation.y,
                                    containerHeight: geo.size.height,
                                    tipHeight: tooltipSize.height
                                )
                            )
                            .allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(TooltipSizeKey.self) { tooltipSize = $0 }
            }
        }
        .chartPlotStyle { plot in plot.clipped() }
    }

    @State private var tooltipSize: CGSize = .zero

    private func clampedTooltipX(cursorX: CGFloat, containerWidth: CGFloat, tipWidth: CGFloat) -> CGFloat {
        // Prefer placing the tooltip 14pt right of the cursor. If that
        // would overflow the right edge, flip to the left side.
        let preferred = cursorX + 14
        if preferred + tipWidth > containerWidth {
            return max(0, cursorX - tipWidth - 14)
        }
        return preferred
    }

    private func clampedTooltipY(cursorY: CGFloat, containerHeight: CGFloat, tipHeight: CGFloat) -> CGFloat {
        // Float slightly above the cursor; clamp to chart bounds.
        let preferred = cursorY - tipHeight - 12
        if preferred < 0 { return cursorY + 14 }
        return min(preferred, containerHeight - tipHeight)
    }

    // MARK: - Derived marks

    private struct EventMark: Identifiable {
        let id = UUID()
        let dayOffset: Int
        let y: Double
        let color: Color
    }

    private var eventMarks: [EventMark] {
        horizon.days.flatMap { day -> [EventMark] in
            day.events.map { event in
                EventMark(
                    dayOffset: day.dayOffset,
                    y: double(day.expectedBalance),
                    color: color(for: event.kind)
                )
            }
        }
    }

    private func color(for kind: ForecastEngine.EventKind) -> Color {
        switch kind {
        case .subscription:      return CentmondTheme.Colors.negative
        case .recurringBill:     return CentmondTheme.Colors.negative
        case .recurringIncome:   return CentmondTheme.Colors.positive
        case .goalContribution:  return CentmondTheme.Colors.warning
        }
    }

    private func dayAt(_ offset: Int) -> ForecastEngine.Day? {
        horizon.days.first(where: { $0.dayOffset == offset })
    }

    // MARK: - Axis helpers

    private var xAxisValues: [Int] {
        let horizon = self.horizon.summary.horizonDays
        let step: Int
        switch horizon {
        case ..<31:  step = 7
        case ..<61:  step = 14
        default:     step = 30
        }
        return stride(from: 0, through: horizon, by: step).map { $0 }
    }

    private func xLabel(for offset: Int) -> String {
        guard let day = dayAt(offset) else { return "D+\(offset)" }
        return day.date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Tooltip

    @ViewBuilder
    private var hoverTooltip: some View {
        // Caller gates on `hoveredOffset != nil`, so the unwrap is safe.
        // Returning the inner VStack directly (no outer Group/transition)
        // avoids SwiftUI animating opacity on every hover-driven content
        // change, which previously added visible flicker.
        if let offset = hoveredOffset, let day = dayAt(offset) {
            VStack(alignment: .leading, spacing: 6) {
                Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                HStack(spacing: 12) {
                    tooltipStat("Expected", CurrencyFormat.compact(day.expectedBalance), CentmondTheme.Colors.accent)
                    tooltipStat("Range", "\(CurrencyFormat.abbreviated(double(day.lowBalance)))–\(CurrencyFormat.abbreviated(double(day.highBalance)))", CentmondTheme.Colors.textTertiary)
                }
                if !day.events.isEmpty {
                    Divider().background(CentmondTheme.Colors.strokeSubtle)
                    ForEach(day.events.prefix(3)) { ev in
                        HStack(spacing: 6) {
                            Circle().fill(color(for: ev.kind)).frame(width: 6, height: 6)
                            Text(ev.name)
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            Spacer(minLength: 8)
                            Text(CurrencyFormat.compact(ev.delta))
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(ev.delta > 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                                .monospacedDigit()
                        }
                    }
                    if day.events.count > 3 {
                        Text("+ \(day.events.count - 3) more")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                }
            }
            .padding(10)
            .background(CentmondTheme.Colors.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm)
                    .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
            .centmondShadow(2)
        }
    }

    private struct TooltipSizeKey: PreferenceKey {
        static let defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            value = nextValue()
        }
    }

    private func tooltipStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .tracking(0.5)
            Text(value)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    private func double(_ d: Decimal) -> Double {
        (d as NSDecimalNumber).doubleValue
    }
}
