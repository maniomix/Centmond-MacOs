import SwiftUI
import Charts

// ============================================================
// MARK: - Liability Payoff Card (P6)
// ============================================================
//
// Compares the three `PayoffStrategy` outcomes side by side, with
// a slider for an extra monthly payment pool. The chart overlays
// the remaining-balance timeline of all three strategies so the
// user can see snowball/avalanche pull ahead of minimum-only.
//
// Skipped entirely when there are no liabilities — Net Worth view
// already shows a "great job!" empty state in the breakdown column.
// ============================================================

struct LiabilityPayoffCard: View {
    let liabilityAccounts: [Account]

    @State private var extraMonthly: Double = 0
    @State private var focusedStrategy: PayoffStrategy = .avalanche

    private var totalBalance: Decimal {
        liabilityAccounts.reduce(Decimal.zero) { $0 + abs($1.currentBalance) }
    }

    private var anyMissingRate: Bool {
        liabilityAccounts.contains { ($0.interestRatePercent ?? 0) <= 0 }
    }

    private var plans: [PayoffPlan] {
        PayoffStrategy.allCases.map { strategy in
            PayoffSimulator.simulate(
                accounts: liabilityAccounts,
                strategy: strategy,
                extraMonthly: Decimal(extraMonthly)
            )
        }
    }

    private var minPlan: PayoffPlan { plans[0] }
    private var focusedPlan: PayoffPlan {
        plans.first(where: { $0.strategy == focusedStrategy }) ?? minPlan
    }

    private var interestSaved: Decimal {
        max(minPlan.totalInterest - focusedPlan.totalInterest, 0)
    }

    private var monthsSaved: Int {
        max(minPlan.months - focusedPlan.months, 0)
    }

    var body: some View {
        if liabilityAccounts.isEmpty || totalBalance == 0 {
            EmptyView()
        } else {
            CardContainer {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                    header
                    if anyMissingRate { missingRateNotice }
                    extraSlider
                    strategyCompareGrid
                    timelineChart
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DEBT PAYOFF")
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(1)
                Text("Plan your way out")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            Spacer()
            Text(CurrencyFormat.standard(totalBalance))
                .font(CentmondTheme.Typography.monoLarge)
                .foregroundStyle(CentmondTheme.Colors.negative)
                .monospacedDigit()
        }
    }

    private var missingRateNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text("Add APR + minimum payment in Edit Account to make these projections accurate.")
                .font(CentmondTheme.Typography.caption)
        }
        .foregroundStyle(CentmondTheme.Colors.warning)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CentmondTheme.Colors.warning.opacity(0.10))
        )
    }

    // MARK: - Slider

    private var extraSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Extra monthly payment")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Spacer()
                Text(CurrencyFormat.standard(Decimal(extraMonthly)))
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .monospacedDigit()
            }
            Slider(value: $extraMonthly, in: 0...2000, step: 25)
                .tint(CentmondTheme.Colors.accent)
            HStack {
                Text("$0")
                Spacer()
                Text("$1,000")
                Spacer()
                Text("$2,000")
            }
            .font(.system(size: 9))
            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
        }
    }

    // MARK: - Strategy compare

    private var strategyCompareGrid: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            ForEach(plans, id: \.strategy) { plan in
                strategyTile(plan: plan)
            }
        }
    }

    private func strategyTile(plan: PayoffPlan) -> some View {
        let isFocused = plan.strategy == focusedStrategy
        let accent = strategyColor(plan.strategy)

        return Button {
            focusedStrategy = plan.strategy
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 8, height: 8)
                    Text(plan.strategy.label)
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }

                if plan.didFinish, let date = plan.payoffDate {
                    Text(date.formatted(.dateTime.month(.abbreviated).year()))
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                    Text("\(plan.months) months")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                } else {
                    Text("Never")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                    Text("Min payment < interest")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }

                Divider().opacity(0.3)

                HStack {
                    Text("Interest")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Spacer()
                    Text(CurrencyFormat.compact(plan.totalInterest))
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                        .monospacedDigit()
                }

                if plan.strategy != .minimum && interestSaved > 0 && plan.strategy == focusedStrategy {
                    HStack {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 8))
                        Text("Saves \(CurrencyFormat.compact(interestSaved))")
                            .font(CentmondTheme.Typography.caption)
                        if monthsSaved > 0 {
                            Text("· \(monthsSaved)mo earlier")
                                .font(CentmondTheme.Typography.caption)
                        }
                    }
                    .foregroundStyle(CentmondTheme.Colors.positive)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isFocused ? accent.opacity(0.08) : CentmondTheme.Colors.bgSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isFocused ? accent.opacity(0.6) : CentmondTheme.Colors.strokeSubtle, lineWidth: isFocused ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Timeline chart

    private var timelineChart: some View {
        let series = plans.map { plan -> (PayoffStrategy, [(Int, Double)]) in
            let pts = plan.timeline.enumerated().map { (i, bal) in
                (i, Double(truncating: bal as NSDecimalNumber))
            }
            return (plan.strategy, pts)
        }

        let maxMonths = series.map { $0.1.count }.max() ?? 1

        return Chart {
            ForEach(series, id: \.0) { strategy, pts in
                ForEach(pts, id: \.0) { idx, value in
                    LineMark(
                        x: .value("Month", idx),
                        y: .value("Balance", value),
                        series: .value("Strategy", strategy.rawValue)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(strategyColor(strategy))
                    .lineStyle(StrokeStyle(
                        lineWidth: strategy == focusedStrategy ? 2.5 : 1.4,
                        dash: strategy == .minimum ? [4, 3] : []
                    ))
                    .opacity(strategy == focusedStrategy ? 1.0 : 0.55)
                }
            }
        }
        .chartXScale(domain: 0...max(maxMonths - 1, 1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.3))
                AxisValueLabel {
                    if let m = v.as(Int.self) {
                        Text(m == 0 ? "Now" : "\(m)mo")
                            .font(CentmondTheme.Typography.caption)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.3))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(CurrencyFormat.compact(Decimal(d)))
                            .font(CentmondTheme.Typography.caption)
                    }
                }
            }
        }
        .frame(height: 180)
    }

    private func strategyColor(_ s: PayoffStrategy) -> Color {
        switch s {
        case .minimum:   return CentmondTheme.Colors.negative
        case .snowball:  return CentmondTheme.Colors.warning
        case .avalanche: return CentmondTheme.Colors.positive
        }
    }
}
