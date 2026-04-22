import SwiftUI
import Charts

struct SubscriptionRosterBodyView: View {
    let roster: SubscriptionRoster

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
            summaryCard
            rosterCard
        }
    }

    private var summaryCard: some View {
        CardContainer {
            HStack(alignment: .top, spacing: CentmondTheme.Spacing.xxl) {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                    metric(label: "Monthly outlay",   value: roster.totalMonthly, color: CentmondTheme.Colors.textPrimary)
                    metric(label: "Annualized",       value: roster.totalAnnual,  color: CentmondTheme.Colors.accent)

                    HStack(spacing: CentmondTheme.Spacing.lg) {
                        pill(label: "Active",    count: roster.activeCount,    color: CentmondTheme.Colors.positive)
                        pill(label: "Paused",    count: roster.pausedCount,    color: CentmondTheme.Colors.warning)
                        pill(label: "Cancelled", count: roster.cancelledCount, color: CentmondTheme.Colors.textTertiary)
                    }
                }

                Chart(roster.rows.prefix(10)) { row in
                    BarMark(
                        x: .value("Monthly", NSDecimalNumber(decimal: row.monthlyCost).doubleValue),
                        y: .value("Service", row.serviceName)
                    )
                    .foregroundStyle(CentmondTheme.Colors.accent.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks { v in
                        AxisValueLabel {
                            if let val = v.as(Double.self) {
                                Text(CurrencyFormat.abbreviated(val))
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    }
                }
                .frame(height: 240)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func metric(label: String, value: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.captionMedium)
                .tracking(0.5)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(CurrencyFormat.compact(value))
                .font(CentmondTheme.Typography.heading1)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private func pill(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(CentmondTheme.Typography.bodyMedium)
                .monospacedDigit()
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
    }

    private var rosterCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Subscriptions")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                ForEach(roster.rows) { row in
                    subscriptionRow(row)
                    Divider().background(CentmondTheme.Colors.strokeSubtle)
                }
            }
        }
    }

    private func subscriptionRow(_ row: SubscriptionRoster.Row) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.serviceName)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(row.categoryName)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            Spacer()

            if row.isTrial {
                statusChip(label: "Trial", color: CentmondTheme.Colors.accent)
            }
            statusChip(label: row.statusLabel, color: statusColor(row.statusLabel))

            if let next = row.nextPaymentDate {
                Text(next.formatted(.dateTime.month(.abbreviated).day()))
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 64, alignment: .trailing)
            }

            Text(CurrencyFormat.compact(row.monthlyCost))
                .font(CentmondTheme.Typography.mono).monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .frame(width: 90, alignment: .trailing)

            Text(CurrencyFormat.compact(row.annualCost) + "/yr")
                .font(CentmondTheme.Typography.caption).monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    private func statusChip(label: String, color: Color) -> some View {
        Text(label)
            .font(CentmondTheme.Typography.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func statusColor(_ label: String) -> Color {
        switch label.lowercased() {
        case "active":   return CentmondTheme.Colors.positive
        case "trial":    return CentmondTheme.Colors.accent
        case "paused":   return CentmondTheme.Colors.warning
        case "cancelled": return CentmondTheme.Colors.textTertiary
        default:         return CentmondTheme.Colors.textSecondary
        }
    }
}
