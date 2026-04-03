import SwiftUI

struct TrendIndicator: View {
    let value: String
    let isPositive: Bool

    var body: some View {
        HStack(spacing: CentmondTheme.Spacing.xs) {
            Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 11, weight: .medium))

            Text(value)
                .font(CentmondTheme.Typography.caption)
                .monospacedDigit()
        }
        .foregroundStyle(
            isPositive
                ? CentmondTheme.Colors.positive
                : CentmondTheme.Colors.negative
        )
    }
}
