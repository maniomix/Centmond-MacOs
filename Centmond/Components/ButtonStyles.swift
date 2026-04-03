import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CentmondTheme.Typography.bodyMedium)
            .foregroundStyle(.white)
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .frame(height: CentmondTheme.Sizing.buttonHeight)
            .background(
                LinearGradient(
                    colors: [CentmondTheme.Colors.accent, Color(hex: "2563EB")],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(CentmondTheme.Motion.micro, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CentmondTheme.Typography.bodyMedium)
            .foregroundStyle(CentmondTheme.Colors.textSecondary)
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .frame(height: CentmondTheme.Sizing.buttonHeight)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(CentmondTheme.Motion.micro, value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CentmondTheme.Typography.bodyMedium)
            .foregroundStyle(CentmondTheme.Colors.textSecondary)
            .padding(.horizontal, CentmondTheme.Spacing.md)
            .frame(height: CentmondTheme.Sizing.buttonHeight)
            .background(configuration.isPressed ? CentmondTheme.Colors.bgQuaternary : .clear)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .animation(CentmondTheme.Motion.micro, value: configuration.isPressed)
    }
}
