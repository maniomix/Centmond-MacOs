import SwiftUI

// One titled card per enabled ReportSection. Delegates body rendering
// to the existing per-kind body views — they're self-contained and
// already charted, so this card is just chrome + KPI chips + the body.

struct ReportSectionCard: View {
    let section: ReportSection
    let result: ReportResult

    @State private var isExpanded = true

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                header

                if isExpanded {
                    if !result.summary.kpis.isEmpty {
                        kpiStrip
                    }
                    sectionBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: section.symbol)
                .font(CentmondTheme.Typography.subheading)
                .foregroundStyle(CentmondTheme.Colors.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(section.subtitle)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Spacer()

            Button {
                withAnimation(CentmondTheme.Motion.default) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - KPI strip

    private var kpiStrip: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            ForEach(result.summary.kpis) { kpi in
                kpiTile(kpi)
            }
        }
    }

    private func kpiTile(_ kpi: ReportKPI) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kpi.label.uppercased())
                .font(CentmondTheme.Typography.captionMedium)
                .tracking(0.5)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .lineLimit(1)
            Text(formatted(kpi))
                .font(CentmondTheme.Typography.heading3)
                .foregroundStyle(tone(kpi.tone))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.vertical, CentmondTheme.Spacing.xs)
        .padding(.horizontal, CentmondTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md)
                .fill(CentmondTheme.Colors.bgPrimary.opacity(0.4))
        )
    }

    private func tone(_ t: ReportKPI.Tone) -> Color {
        switch t {
        case .neutral:  return CentmondTheme.Colors.textPrimary
        case .positive: return CentmondTheme.Colors.positive
        case .negative: return CentmondTheme.Colors.negative
        case .warning:  return CentmondTheme.Colors.warning
        }
    }

    private func formatted(_ kpi: ReportKPI) -> String {
        switch kpi.valueFormat {
        case .currency: return CurrencyFormat.compact(kpi.value)
        case .percent:  return "\(Int(truncating: kpi.value as NSDecimalNumber))%"
        case .integer:  return "\(Int(truncating: kpi.value as NSDecimalNumber))"
        }
    }

    // MARK: - Body dispatch

    @ViewBuilder
    private var sectionBody: some View {
        switch result.body {
        case .periodSeries(let s):
            PeriodSeriesBodyView(series: s, groupByLabel: result.definition.groupBy.label)
        case .categoryBreakdown(let c):
            CategoryBreakdownBodyView(breakdown: c)
        case .merchantLeaderboard(let m):
            MerchantLeaderboardBodyView(leaderboard: m)
        case .heatmap(let h):
            BudgetHeatmapBodyView(heatmap: h)
        case .netWorth(let n):
            NetWorthBodyPreview(payload: n)
        case .subscriptionRoster(let r):
            SubscriptionRosterBodyView(roster: r)
        case .recurringRoster(let r):
            RecurringRosterBodyView(roster: r)
        case .goalsProgress(let g):
            GoalsProgressBodyView(progress: g)
        case .empty(let reason):
            emptyBody(reason)
        }
    }

    private func emptyBody(_ reason: ReportBody.EmptyReason) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "tray")
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(emptyMessage(reason))
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Spacer()
        }
        .padding(.vertical, CentmondTheme.Spacing.lg)
    }

    private func emptyMessage(_ r: ReportBody.EmptyReason) -> String {
        switch r {
        case .noTransactionsInRange: return "No transactions in this range."
        case .allFilteredOut:        return "Filters removed every result — widen them in the controls rail."
        case .missingData:           return "No data available for this section yet."
        }
    }
}
