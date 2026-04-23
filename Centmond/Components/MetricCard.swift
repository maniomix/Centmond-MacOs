import SwiftUI

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let iconColor: Color
    var valueColor: Color?
    var trend: String?
    var trendPositive: Bool?
    var subtitle: String?

    init(
        title: String,
        value: String,
        icon: String = "chart.bar.fill",
        iconColor: Color = CentmondTheme.Colors.accent,
        valueColor: Color? = nil,
        trend: String? = nil,
        trendPositive: Bool? = nil,
        subtitle: String? = nil
    ) {
        self.title = title
        self.value = value
        self.icon = icon
        self.iconColor = iconColor
        self.valueColor = valueColor
        self.trend = trend
        self.trendPositive = trendPositive
        self.subtitle = subtitle
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                // Top row: title + icon
                HStack {
                    Text(title)
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)

                    Spacer()

                    Image(systemName: icon)
                        .font(CentmondTheme.Typography.subheading.weight(.medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 32, height: 32)
                        .background(iconColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                }

                // Value
                Text(value)
                    .font(CentmondTheme.Typography.monoLarge)
                    .foregroundStyle(valueColor ?? CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(CentmondTheme.Motion.numeric, value: value)

                // Trend or subtitle
                if let trend, let trendPositive {
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        Image(systemName: trendPositive ? "arrow.up.right" : "arrow.down.right")
                            .font(CentmondTheme.Typography.overlineSemibold)

                        Text(trend)
                            .font(CentmondTheme.Typography.caption)

                        if let subtitle {
                            Text(subtitle)
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }
                    .foregroundStyle(
                        trendPositive
                            ? CentmondTheme.Colors.positive
                            : CentmondTheme.Colors.negative
                    )
                    .animation(CentmondTheme.Motion.numeric, value: trendPositive)
                } else if let subtitle {
                    Text(subtitle)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
