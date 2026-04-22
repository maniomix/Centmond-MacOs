import SwiftUI
import Charts

struct MerchantLeaderboardBodyView: View {
    let leaderboard: MerchantLeaderboard

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Top merchants")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                ForEach(Array(leaderboard.rows.enumerated()), id: \.element.id) { idx, row in
                    merchantRow(row: row, rank: idx + 1)
                    if idx < leaderboard.rows.count - 1 {
                        Divider().background(CentmondTheme.Colors.strokeSubtle)
                    }
                }
            }
        }
    }

    private func merchantRow(row: MerchantLeaderboard.Row, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("#\(rank)")
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 32, alignment: .leading)

                Text(row.displayName)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text("\(row.transactionCount)×")
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 44, alignment: .trailing)

                Text("avg " + CurrencyFormat.compact(row.averageAmount))
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 110, alignment: .trailing)

                sparkline(row.sparkline)
                    .frame(width: 120, height: 28)

                Text(CurrencyFormat.compact(row.amount))
                    .font(CentmondTheme.Typography.mono).monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .frame(width: 110, alignment: .trailing)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(CentmondTheme.Colors.accent.opacity(0.1))
                        .frame(height: 3)
                    Capsule().fill(CentmondTheme.Colors.accent)
                        .frame(width: max(2, geo.size.width * CGFloat(row.percentOfTotal)), height: 3)
                }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 6)
    }

    private func sparkline(_ points: [Decimal]) -> some View {
        let data = points.enumerated().map { (idx, value) in
            (Double(idx), Double(truncating: value as NSDecimalNumber))
        }
        return Chart(data, id: \.0) { point in
            AreaMark(x: .value("i", point.0), y: .value("v", point.1))
                .foregroundStyle(CentmondTheme.Colors.accent.opacity(0.18))
                .interpolationMethod(.monotone)
            LineMark(x: .value("i", point.0), y: .value("v", point.1))
                .foregroundStyle(CentmondTheme.Colors.accent)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.4))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.background(Color.clear) }
    }
}
