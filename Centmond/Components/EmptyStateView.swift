import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let heading: String
    let description: String
    var primaryAction: String?
    var secondaryAction: String?
    var onPrimaryAction: (() -> Void)?
    var onSecondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)

            Text(heading)
                .font(CentmondTheme.Typography.heading2)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            Text(description)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            HStack(spacing: CentmondTheme.Spacing.sm) {
                if let primaryAction, let action = onPrimaryAction {
                    Button(primaryAction) { action() }
                        .buttonStyle(PrimaryButtonStyle())
                }

                if let secondaryAction, let action = onSecondaryAction {
                    Button(secondaryAction) { action() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
