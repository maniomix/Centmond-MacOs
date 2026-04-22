import SwiftUI
import Charts

// Grouped income/expense bars + net line overlay; hovering reveals a
// floating tooltip and highlights the matching row in the table below.
// Follows the "hover state on the chart sub-view, never on the parent"
// rule so a big detail screen doesn't re-render at 60Hz.

struct PeriodSeriesBodyView: View {
    let series: PeriodSeries
    let groupByLabel: String

    @State private var hoveredBucketID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
            PeriodSeriesChartSurface(
                series: series,
                hoveredBucketID: $hoveredBucketID
            )

            periodTable
        }
    }

    // MARK: - Table

    private var periodTable: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text("By \(groupByLabel.lowercased())")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    if let sr = series.totals.savingsRate {
                        Text("Savings rate \(Int(sr * 100))%")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(sr >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                    }
                }

                header
                Divider().background(CentmondTheme.Colors.strokeSubtle)

                ForEach(series.buckets) { bucket in
                    row(for: bucket, highlighted: bucket.id == hoveredBucketID)
                    Divider().background(CentmondTheme.Colors.strokeSubtle)
                }

                totalsRow
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Period").frame(maxWidth: .infinity, alignment: .leading)
            Text("Income").frame(width: 110, alignment: .trailing)
            Text("Expense").frame(width: 110, alignment: .trailing)
            Text("Net").frame(width: 110, alignment: .trailing)
            Text("Tx").frame(width: 50, alignment: .trailing)
        }
        .font(CentmondTheme.Typography.captionMedium)
        .foregroundStyle(CentmondTheme.Colors.textTertiary)
        .padding(.vertical, 4)
    }

    private func row(for bucket: PeriodSeries.Bucket, highlighted: Bool) -> some View {
        HStack {
            Text(bucket.label)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(CurrencyFormat.compact(bucket.income))
                .font(CentmondTheme.Typography.mono).monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.positive)
                .frame(width: 110, alignment: .trailing)
            Text(CurrencyFormat.compact(bucket.expense))
                .font(CentmondTheme.Typography.mono).monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.negative)
                .frame(width: 110, alignment: .trailing)
            Text(CurrencyFormat.compact(bucket.net))
                .font(CentmondTheme.Typography.mono).monospacedDigit()
                .foregroundStyle(bucket.net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                .frame(width: 110, alignment: .trailing)
            Text("\(bucket.transactionCount)")
                .font(CentmondTheme.Typography.mono).monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(highlighted ? CentmondTheme.Colors.accentMuted.opacity(0.6) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .animation(CentmondTheme.Motion.micro, value: highlighted)
    }

    private var totalsRow: some View {
        HStack {
            Text("Total")
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(CurrencyFormat.compact(series.totals.income))
                .font(CentmondTheme.Typography.mono).monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.positive)
                .frame(width: 110, alignment: .trailing)
            Text(CurrencyFormat.compact(series.totals.expense))
                .font(CentmondTheme.Typography.mono).monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.negative)
                .frame(width: 110, alignment: .trailing)
            Text(CurrencyFormat.compact(series.totals.net))
                .font(CentmondTheme.Typography.mono).monospacedDigit()
                .foregroundStyle(series.totals.net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                .frame(width: 110, alignment: .trailing)
            Text("")
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 6).padding(.horizontal, 4)
        .background(CentmondTheme.Colors.bgTertiary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// Hover-state scope must live inside the chart sub-view so the parent
// detail screen doesn't re-render at cursor speed.
private struct PeriodSeriesChartSurface: View {
    let series: PeriodSeries
    @Binding var hoveredBucketID: String?

    @State private var hoverLocation: CGPoint?

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    headerTile(label: "Income",   value: series.totals.income,  color: CentmondTheme.Colors.positive)
                    headerTile(label: "Expenses", value: series.totals.expense, color: CentmondTheme.Colors.negative)
                    headerTile(label: "Net",      value: series.totals.net,     color: series.totals.net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                }

                Chart {
                    ForEach(series.buckets) { b in
                        BarMark(
                            x: .value("Period", b.label),
                            y: .value("Income", NSDecimalNumber(decimal: b.income).doubleValue)
                        )
                        .foregroundStyle(CentmondTheme.Colors.positive.gradient)
                        .position(by: .value("Type", "Income"))
                        .cornerRadius(3)

                        BarMark(
                            x: .value("Period", b.label),
                            y: .value("Expense", NSDecimalNumber(decimal: b.expense).doubleValue)
                        )
                        .foregroundStyle(CentmondTheme.Colors.negative.gradient)
                        .position(by: .value("Type", "Expense"))
                        .cornerRadius(3)

                        LineMark(
                            x: .value("Period", b.label),
                            y: .value("Net", NSDecimalNumber(decimal: b.net).doubleValue)
                        )
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .symbol(.circle)
                        .symbolSize(40)
                    }

                    if let id = hoveredBucketID, let b = series.buckets.first(where: { $0.id == id }) {
                        RuleMark(x: .value("Period", b.label))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartForegroundStyleScale([
                    "Income": CentmondTheme.Colors.positive,
                    "Expense": CentmondTheme.Colors.negative
                ])
                .chartYAxis { axisY }
                .chartXAxis { axisX }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let plotFrame = geo[proxy.plotFrame!]

                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    let insetX = loc.x - plotFrame.minX
                                    guard plotFrame.contains(loc),
                                          let label: String = proxy.value(atX: insetX) else {
                                        if hoveredBucketID != nil { hoveredBucketID = nil }
                                        return
                                    }
                                    let match = series.buckets.first(where: { $0.label == label })
                                    let newID = match?.id
                                    if hoveredBucketID != newID { hoveredBucketID = newID }
                                    hoverLocation = loc
                                case .ended:
                                    if hoveredBucketID != nil { hoveredBucketID = nil }
                                    hoverLocation = nil
                                }
                            }

                        if let id = hoveredBucketID,
                           let b = series.buckets.first(where: { $0.id == id }),
                           let loc = hoverLocation {
                            tooltip(for: b)
                                .position(
                                    x: min(max(loc.x, 80), geo.size.width - 80),
                                    y: max(32, loc.y - 54)
                                )
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(height: 300)
            }
        }
    }

    private var axisY: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.4))
            AxisValueLabel {
                if let v = value.as(Double.self) {
                    Text(CurrencyFormat.abbreviated(v))
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }
        }
    }

    private var axisX: some AxisContent {
        AxisMarks { _ in
            AxisValueLabel()
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
    }

    private func headerTile(label: String, value: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.captionMedium)
                .tracking(0.5)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(CurrencyFormat.compact(value))
                .font(CentmondTheme.Typography.heading2)
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tooltip(for bucket: PeriodSeries.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bucket.label)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            HStack(spacing: 6) {
                Circle().fill(CentmondTheme.Colors.positive).frame(width: 6, height: 6)
                Text(CurrencyFormat.compact(bucket.income))
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
            }
            HStack(spacing: 6) {
                Circle().fill(CentmondTheme.Colors.negative).frame(width: 6, height: 6)
                Text(CurrencyFormat.compact(bucket.expense))
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
            }
            Text("Net " + CurrencyFormat.compact(bucket.net))
                .font(CentmondTheme.Typography.caption).monospacedDigit()
                .foregroundStyle(bucket.net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}
