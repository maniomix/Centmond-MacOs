import SwiftUI

struct RecurringRosterBodyView: View {
    let roster: RecurringRoster

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                summaryStrip

                HStack(alignment: .top, spacing: CentmondTheme.Spacing.xxl) {
                    column(title: "Expenses", rows: roster.expenseRows, accent: CentmondTheme.Colors.negative)
                    column(title: "Income",   rows: roster.incomeRows,   accent: CentmondTheme.Colors.positive)
                }
            }
        }
    }

    private var summaryStrip: some View {
        HStack {
            tile(label: "Monthly income",  value: roster.totalMonthlyIncome,  color: CentmondTheme.Colors.positive)
            tile(label: "Monthly expense", value: roster.totalMonthlyExpense, color: CentmondTheme.Colors.negative)
            tile(label: "Net",
                 value: roster.totalMonthlyIncome - roster.totalMonthlyExpense,
                 color: roster.totalMonthlyIncome >= roster.totalMonthlyExpense ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
        }
    }

    private func tile(label: String, value: Decimal, color: Color) -> some View {
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

    private func column(title: String, rows: [RecurringRoster.Row], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            HStack {
                Text(title.uppercased())
                    .font(CentmondTheme.Typography.captionMedium)
                    .tracking(0.5)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Spacer()
                Text("\(rows.count) items")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            if rows.isEmpty {
                Text("Nothing yet")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ForEach(rows) { row in
                    recurringRow(row, accent: accent)
                    Divider().background(CentmondTheme.Colors.strokeSubtle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func recurringRow(_ row: RecurringRoster.Row, accent: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text("next " + row.nextOccurrence.formatted(.dateTime.month(.abbreviated).day()))
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            Spacer()
            Text(row.frequencyLabel)
                .font(CentmondTheme.Typography.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(accent.opacity(0.12))
                .foregroundStyle(accent)
                .clipShape(Capsule())
            Text(CurrencyFormat.compact(row.normalizedMonthly) + "/mo")
                .font(CentmondTheme.Typography.mono).monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}
