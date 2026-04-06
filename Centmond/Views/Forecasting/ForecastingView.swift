import SwiftUI
import SwiftData
import Charts

struct ForecastingView: View {
    @Environment(AppRouter.self) private var router
    @Query private var transactions: [Transaction]
    @Query(sort: \RecurringTransaction.nextOccurrence) private var recurringItems: [RecurringTransaction]
    @Query private var subscriptions: [Subscription]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var forecastDays: Int = 30

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

    private var monthlyIncome: Decimal {
        transactions
            .filter { $0.isIncome && $0.date >= startOfMonth && $0.date <= .now }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var monthlySpending: Decimal {
        transactions
            .filter { !$0.isIncome && $0.date >= startOfMonth && $0.date <= .now }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var upcomingBills: Decimal {
        let subTotal = subscriptions
            .filter { $0.status == .active && $0.nextPaymentDate > .now && $0.nextPaymentDate <= endOfMonth }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let recurringTotal = recurringItems
            .filter { $0.isActive && !$0.isIncome && $0.nextOccurrence > .now && $0.nextOccurrence <= endOfMonth }
            .reduce(Decimal.zero) { $0 + $1.amount }
        return subTotal + recurringTotal
    }

    private var expectedIncome: Decimal {
        recurringItems
            .filter { $0.isActive && $0.isIncome && $0.nextOccurrence > .now && $0.nextOccurrence <= endOfMonth }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var safeToSpend: Decimal {
        monthlyIncome + expectedIncome - monthlySpending - upcomingBills
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

    private var totalBalance: Decimal {
        accounts.filter { !$0.isArchived }.reduce(Decimal.zero) { $0 + $1.currentBalance }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: CentmondTheme.Spacing.xxl) {
                safeToSpendHero
                forecastChart
                upcomingObligations
            }
            .padding(CentmondTheme.Spacing.xxl)
        }
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

    private var forecastChart: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                HStack {
                    Text("Obligation Timeline")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    Picker("Days", selection: $forecastDays) {
                        Text("30D").tag(30)
                        Text("60D").tag(60)
                        Text("90D").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                let timeline = buildTimeline()

                if timeline.isEmpty {
                    HStack {
                        Spacer()
                        Text("No upcoming obligations in the next \(forecastDays) days")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .padding(.vertical, CentmondTheme.Spacing.xxl)
                        Spacer()
                    }
                    .transition(.opacity)
                } else {
                    // Running balance chart based on real obligations
                    let balancePoints = buildBalanceProjection(timeline: timeline)
                    Chart {
                        ForEach(balancePoints, id: \.dayOffset) { point in
                            AreaMark(
                                x: .value("Day", point.dayOffset),
                                y: .value("Balance", point.balance)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [CentmondTheme.Colors.accent.opacity(0.2), CentmondTheme.Colors.accent.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.stepEnd)

                            LineMark(
                                x: .value("Day", point.dayOffset),
                                y: .value("Balance", point.balance)
                            )
                            .foregroundStyle(CentmondTheme.Colors.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.stepEnd)
                        }

                        // Mark obligation days
                        ForEach(timeline, id: \.name) { item in
                            let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: item.date).day ?? 0
                            PointMark(
                                x: .value("Day", dayOffset),
                                y: .value("Balance", balanceAtDay(dayOffset, in: balancePoints))
                            )
                            .foregroundStyle(CentmondTheme.Colors.negative)
                            .symbolSize(30)
                        }

                        // Zero line
                        RuleMark(y: .value("Zero", 0))
                            .foregroundStyle(CentmondTheme.Colors.negative.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 0.5))
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisValueLabel {
                                if let val = value.as(Double.self) {
                                    Text(CurrencyFormat.abbreviated(val))
                                        .font(CentmondTheme.Typography.caption)
                                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                }
                            }
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.4))
                        }
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let day = value.as(Int.self) {
                                    Text("D+\(day)")
                                        .font(CentmondTheme.Typography.caption)
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                }
                            }
                        }
                    }
                    .chartPlotStyle { plot in
                        plot.clipped()
                    }
                    .frame(height: 280)
                    .animation(CentmondTheme.Motion.layout, value: forecastDays)
                    .transition(.opacity)

                    Text("Projection based on current balance (\(CurrencyFormat.compact(totalBalance))) minus known upcoming obligations. Does not predict variable spending.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
        }
    }

    // MARK: - Upcoming Obligations

    private var upcomingObligations: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text("Upcoming Obligations")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    let total = buildTimeline().reduce(Decimal.zero) { $0 + $1.amount }
                    if total > 0 {
                        Text("Total: \(CurrencyFormat.compact(total))")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.negative)
                            .monospacedDigit()
                    }
                }

                let allUpcoming = buildTimeline()

                if allUpcoming.isEmpty {
                    Text("No upcoming obligations in the next \(forecastDays) days")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .padding(.vertical, CentmondTheme.Spacing.lg)
                } else {
                    // Group by week
                    let weeks = groupByWeek(allUpcoming)
                    ForEach(weeks, id: \.label) { week in
                        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                            HStack {
                                Text(week.label)
                                    .font(CentmondTheme.Typography.captionMedium)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .textCase(.uppercase)

                                Spacer()

                                Text(CurrencyFormat.compact(week.items.reduce(Decimal.zero) { $0 + $1.amount }))
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .monospacedDigit()
                            }

                            ForEach(week.items, id: \.name) { item in
                                HStack {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 14))
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                        .frame(width: 24)

                                    Text(item.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                        .font(CentmondTheme.Typography.body)
                                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                                        .frame(width: 100, alignment: .leading)

                                    Text(item.name)
                                        .font(CentmondTheme.Typography.bodyMedium)
                                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                                    Text(item.source)
                                        .font(CentmondTheme.Typography.caption)
                                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(CentmondTheme.Colors.bgTertiary)
                                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))

                                    Spacer()

                                    Text(CurrencyFormat.compact(item.amount))
                                        .font(CentmondTheme.Typography.mono)
                                        .foregroundStyle(CentmondTheme.Colors.negative)
                                        .monospacedDigit()
                                }
                                .padding(.vertical, CentmondTheme.Spacing.xs)
                            }
                        }

                        if week.label != weeks.last?.label {
                            Divider().background(CentmondTheme.Colors.strokeSubtle)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data Building

    private struct UpcomingItem {
        let name: String
        let amount: Decimal
        let date: Date
        let icon: String
        let source: String // "Subscription" or "Recurring"
    }

    private func buildTimeline() -> [UpcomingItem] {
        let endDate = calendar.date(byAdding: .day, value: forecastDays, to: .now)!
        var items: [UpcomingItem] = []

        for sub in subscriptions where sub.status == .active && sub.nextPaymentDate > .now && sub.nextPaymentDate <= endDate {
            items.append(UpcomingItem(name: sub.serviceName, amount: sub.amount, date: sub.nextPaymentDate, icon: "arrow.triangle.2.circlepath", source: "Subscription"))
        }

        for rec in recurringItems where rec.isActive && !rec.isIncome && rec.nextOccurrence > .now && rec.nextOccurrence <= endDate {
            items.append(UpcomingItem(name: rec.name, amount: rec.amount, date: rec.nextOccurrence, icon: "repeat", source: "Recurring"))
        }

        return items.sorted { $0.date < $1.date }
    }

    private struct WeekGroup {
        let label: String
        let items: [UpcomingItem]
    }

    private func groupByWeek(_ items: [UpcomingItem]) -> [WeekGroup] {
        var groups: [(label: String, items: [UpcomingItem])] = []
        let today = calendar.startOfDay(for: .now)

        for item in items {
            let daysAway = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: item.date)).day ?? 0
            let label: String
            if daysAway <= 7 { label = "This Week" }
            else if daysAway <= 14 { label = "Next Week" }
            else if daysAway <= 30 { label = "This Month" }
            else { label = "Later" }

            if let idx = groups.firstIndex(where: { $0.label == label }) {
                groups[idx].items.append(item)
            } else {
                groups.append((label: label, items: [item]))
            }
        }

        return groups.map { WeekGroup(label: $0.label, items: $0.items) }
    }

    private struct BalancePoint {
        let dayOffset: Int
        let balance: Double
    }

    private func buildBalanceProjection(timeline: [UpcomingItem]) -> [BalancePoint] {
        let startBalance = Double(truncating: totalBalance as NSDecimalNumber)
        var points: [BalancePoint] = [BalancePoint(dayOffset: 0, balance: startBalance)]
        var currentBalance = startBalance
        let today = calendar.startOfDay(for: .now)

        // Build obligation events by day offset
        var eventsByDay: [Int: Double] = [:]
        for item in timeline {
            let dayOffset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: item.date)).day ?? 0
            eventsByDay[dayOffset, default: 0] += Double(truncating: item.amount as NSDecimalNumber)
        }

        for day in 1...forecastDays {
            if let cost = eventsByDay[day] {
                currentBalance -= cost
            }
            points.append(BalancePoint(dayOffset: day, balance: currentBalance))
        }

        return points
    }

    private func balanceAtDay(_ day: Int, in points: [BalancePoint]) -> Double {
        points.first(where: { $0.dayOffset == day })?.balance ?? 0
    }

    // MARK: - Helpers


}
