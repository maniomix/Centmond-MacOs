import SwiftUI
import Charts

struct NetWorthBodyPreview: View {
    let payload: NetWorthBody

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
            chartCard
            snapshotsCard
        }
    }

    private var chartCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    netWorthTile
                    Spacer()
                    assetsLiabilitiesTiles
                }

                Chart(payload.snapshots) { p in
                    AreaMark(
                        x: .value("Date", p.date),
                        y: .value("Net worth", NSDecimalNumber(decimal: p.netWorth).doubleValue)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [CentmondTheme.Colors.accent.opacity(0.35), CentmondTheme.Colors.accent.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Net worth", NSDecimalNumber(decimal: p.netWorth).doubleValue)
                    )
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.4))
                        AxisValueLabel {
                            if let val = v.as(Double.self) {
                                Text(CurrencyFormat.abbreviated(val))
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 280)
            }
        }
    }

    private var netWorthTile: some View {
        let delta = payload.endingNetWorth - payload.startingNetWorth
        let d = Double(truncating: delta as NSDecimalNumber)

        return VStack(alignment: .leading, spacing: 2) {
            Text("NET WORTH")
                .font(CentmondTheme.Typography.captionMedium)
                .tracking(0.5)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(CurrencyFormat.compact(payload.endingNetWorth))
                .font(CentmondTheme.Typography.heading1)
                .monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            HStack(spacing: 4) {
                Image(systemName: d >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                Text(CurrencyFormat.compact(Decimal(abs(d))))
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
            }
            .foregroundStyle(d >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
        }
    }

    private var assetsLiabilitiesTiles: some View {
        HStack(spacing: CentmondTheme.Spacing.lg) {
            tile(label: "Assets",      value: payload.assetsEnd,      color: CentmondTheme.Colors.positive)
            tile(label: "Liabilities", value: payload.liabilitiesEnd, color: CentmondTheme.Colors.negative)
        }
    }

    private func tile(label: String, value: Decimal, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.captionMedium)
                .tracking(0.5)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(CurrencyFormat.compact(value))
                .font(CentmondTheme.Typography.heading3)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private var snapshotsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Snapshots")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                HStack {
                    Text("Date").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Assets").frame(width: 110, alignment: .trailing)
                    Text("Liabilities").frame(width: 110, alignment: .trailing)
                    Text("Net worth").frame(width: 120, alignment: .trailing)
                }
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                ForEach(payload.snapshots.reversed().prefix(20)) { p in
                    HStack {
                        Text(p.date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(CentmondTheme.Typography.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(CurrencyFormat.compact(p.assets))
                            .font(CentmondTheme.Typography.mono).monospacedDigit()
                            .foregroundStyle(CentmondTheme.Colors.positive)
                            .frame(width: 110, alignment: .trailing)
                        Text(CurrencyFormat.compact(p.liabilities))
                            .font(CentmondTheme.Typography.mono).monospacedDigit()
                            .foregroundStyle(CentmondTheme.Colors.negative)
                            .frame(width: 110, alignment: .trailing)
                        Text(CurrencyFormat.compact(p.netWorth))
                            .font(CentmondTheme.Typography.mono).monospacedDigit()
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .frame(width: 120, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    Divider().background(CentmondTheme.Colors.strokeSubtle)
                }

                if payload.snapshots.count > 20 {
                    Text("+ \(payload.snapshots.count - 20) earlier snapshots")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }
        }
    }
}
