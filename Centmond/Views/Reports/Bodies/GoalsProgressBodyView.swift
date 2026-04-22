import SwiftUI

struct GoalsProgressBodyView: View {
    let progress: GoalsProgressBody

    private let columns = [
        GridItem(.adaptive(minimum: 320, maximum: 420), spacing: CentmondTheme.Spacing.lg)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
            summaryCard
            gridCard
        }
    }

    private var summaryCard: some View {
        CardContainer {
            HStack(spacing: CentmondTheme.Spacing.xxxl) {
                tile(label: "Saved so far", value: progress.totalCurrent, color: CentmondTheme.Colors.positive)
                tile(label: "Target",       value: progress.totalTarget,  color: CentmondTheme.Colors.textPrimary)
                tile(label: "In period",    value: progress.contributionsInRange, color: CentmondTheme.Colors.accent)
                progressRing
            }
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

    private var progressRing: some View {
        let pct: Double = progress.totalTarget > 0
            ? Double(truncating: (progress.totalCurrent / progress.totalTarget) as NSDecimalNumber)
            : 0
        return ZStack {
            Circle()
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(1, pct))
                .stroke(
                    AngularGradient(
                        colors: [CentmondTheme.Colors.accent.opacity(0.7), CentmondTheme.Colors.accent],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((pct * 100).rounded()))%")
                    .font(CentmondTheme.Typography.heading2)
                    .monospacedDigit()
                Text("overall").font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
        }
        .frame(width: 96, height: 96)
    }

    private var gridCard: some View {
        LazyVGrid(columns: columns, spacing: CentmondTheme.Spacing.lg) {
            ForEach(progress.rows) { row in
                goalCard(row)
            }
        }
    }

    private func goalCard(_ row: GoalsProgressBody.Row) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Image(systemName: row.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .frame(width: 32, height: 32)
                        .background(CentmondTheme.Colors.accentMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Text("\(Int((row.percentComplete * 100).rounded()))% complete")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }

                    Spacer()

                    Text(CurrencyFormat.compact(row.currentAmount))
                        .font(CentmondTheme.Typography.heading3)
                        .monospacedDigit()
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(CentmondTheme.Colors.accent.opacity(0.12))
                            .frame(height: 6)
                        Capsule().fill(CentmondTheme.Colors.accent)
                            .frame(width: max(4, geo.size.width * CGFloat(min(1, row.percentComplete))), height: 6)
                    }
                }
                .frame(height: 6)

                HStack {
                    Text("of " + CurrencyFormat.compact(row.targetAmount))
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)

                    Spacer()

                    if let monthly = row.monthlyContribution, monthly > 0 {
                        Text(CurrencyFormat.compact(monthly) + "/mo")
                            .font(CentmondTheme.Typography.caption).monospacedDigit()
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    }

                    if let projected = row.projectedCompletion {
                        Text("· by " + projected.formatted(.dateTime.month(.abbreviated).year()))
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                }
            }
        }
    }
}
