import SwiftUI
import SwiftData
import Charts

/// 30-day forward look at every active recurring transaction. Income
/// renders as positive bars, expense as negative — same convention as
/// the Dashboard's Cash Flow chart so the user reads them the same way.
/// Tap a bar to edit the underlying template.
///
/// Hover/tap state is owned by this struct (not the parent view) per
/// the project-wide rule that interactive chart state on a parent
/// re-renders the parent at 60Hz and pegs CPU.
struct RecurringForecastStrip: View {
    let templates: [RecurringTransaction]
    let onSelectTemplate: (RecurringTransaction) -> Void

    private let horizonDays: Int = 30

    @State private var hoveredDay: Date?

    private var entries: [ForecastDay] {
        Self.computeForecast(
            templates: templates.filter(\.isActive),
            from: Calendar.current.startOfDay(for: .now),
            days: horizonDays
        )
    }

    private var totalIncome: Decimal { entries.reduce(0) { $0 + $1.income } }
    private var totalExpense: Decimal { entries.reduce(0) { $0 + $1.expense } }
    private var net: Decimal { totalIncome - totalExpense }

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            header

            if entries.isEmpty || (totalIncome == 0 && totalExpense == 0) {
                emptyState
            } else {
                chart
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: CentmondTheme.Spacing.xxxl) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT \(horizonDays) DAYS")
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)
                Text("Forecast")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }

            forecastMetric("In",  CurrencyFormat.compact(totalIncome),  CentmondTheme.Colors.positive)
            forecastMetric("Out", CurrencyFormat.compact(totalExpense), CentmondTheme.Colors.negative)
            forecastMetric("Net", CurrencyFormat.compact(net),
                           net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)

            Spacer()

            if let h = hoveredDay, let entry = entries.first(where: { Calendar.current.isDate($0.day, inSameDayAs: h) }) {
                hoverDetail(entry)
                    .transition(.opacity)
            }
        }
    }

    private func forecastMetric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    private func hoverDetail(_ entry: ForecastDay) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(entry.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            HStack(spacing: 6) {
                ForEach(entry.items.prefix(3)) { item in
                    Text(item.templateName)
                        .font(CentmondTheme.Typography.overlineRegular)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
                if entry.items.count > 3 {
                    Text("+\(entry.items.count - 3)")
                        .font(CentmondTheme.Typography.overlineRegular)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart(entries) { day in
            if day.income > 0 {
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Income", NSDecimalNumber(decimal: day.income).doubleValue)
                )
                .foregroundStyle(CentmondTheme.Colors.positive.opacity(0.85))
                .cornerRadius(2)
            }
            if day.expense > 0 {
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Expense", -NSDecimalNumber(decimal: day.expense).doubleValue)
                )
                .foregroundStyle(CentmondTheme.Colors.negative.opacity(0.85))
                .cornerRadius(2)
            }
        }
        .frame(height: 140)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 5)) { value in
                AxisGridLine().foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.3))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.25))
                AxisValueLabel()
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrameKey = proxy.plotFrame else { return }
                            let plotFrame = geometry[plotFrameKey]
                            let xInPlot = location.x - plotFrame.origin.x
                            guard xInPlot >= 0, xInPlot <= plotFrame.width,
                                  let date: Date = proxy.value(atX: xInPlot) else { return }
                            let target = Calendar.current.startOfDay(for: date)
                            if let match = entries.first(where: { Calendar.current.isDate($0.day, inSameDayAs: target) }) {
                                if hoveredDay != match.day {
                                    hoveredDay = match.day
                                }
                            }
                        case .ended:
                            hoveredDay = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let plotFrameKey = proxy.plotFrame else { return }
                        let plotFrame = geometry[plotFrameKey]
                        let xInPlot = location.x - plotFrame.origin.x
                        guard xInPlot >= 0, xInPlot <= plotFrame.width,
                              let date: Date = proxy.value(atX: xInPlot) else { return }
                        let target = Calendar.current.startOfDay(for: date)
                        if let match = entries.first(where: { Calendar.current.isDate($0.day, inSameDayAs: target) }),
                           let first = match.items.first?.template {
                            onSelectTemplate(first)
                            Haptics.tap()
                        }
                    }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text("No occurrences in the next \(horizonDays) days.")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 140)
    }

    // MARK: - Forecast computation (pure)

    struct ForecastItem: Identifiable {
        let id = UUID()
        let template: RecurringTransaction
        let templateName: String
        let amount: Decimal
        let isIncome: Bool
    }

    struct ForecastDay: Identifiable {
        let id: Date
        let day: Date
        let items: [ForecastItem]

        var income: Decimal {
            items.filter(\.isIncome).reduce(0) { $0 + $1.amount }
        }
        var expense: Decimal {
            items.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
        }
    }

    /// Walk every template forward from today by its frequency until we
    /// pass the horizon. Bucket occurrences by day. Cap iterations per
    /// template at `horizonDays * 2` so a misconfigured template can't
    /// loop forever.
    static func computeForecast(
        templates: [RecurringTransaction],
        from start: Date,
        days: Int
    ) -> [ForecastDay] {
        let cal = Calendar.current
        guard let end = cal.date(byAdding: .day, value: days, to: start) else { return [] }

        var buckets: [Date: [ForecastItem]] = [:]
        let perTemplateCap = days * 2

        for template in templates {
            var cursor = template.nextOccurrence
            // Catch up if nextOccurrence is behind today (e.g. scheduler
            // hasn't ticked yet this session) so the strip shows what's
            // about to happen, not what already lapsed.
            var safety = 0
            while cursor < start && safety < perTemplateCap {
                cursor = template.frequency.nextDate(after: cursor)
                safety += 1
            }
            var iterations = 0
            while cursor <= end && iterations < perTemplateCap {
                let bucket = cal.startOfDay(for: cursor)
                buckets[bucket, default: []].append(
                    ForecastItem(
                        template: template,
                        templateName: template.name,
                        amount: template.amount,
                        isIncome: template.isIncome
                    )
                )
                cursor = template.frequency.nextDate(after: cursor)
                iterations += 1
            }
        }

        return buckets
            .map { ForecastDay(id: $0.key, day: $0.key, items: $0.value) }
            .sorted { $0.day < $1.day }
    }
}
