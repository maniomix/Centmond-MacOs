import SwiftUI

extension View {
    func cardStyle() -> some View {
        self
            .padding(CentmondTheme.Spacing.lg)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
    }

    func screenBackground() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CentmondTheme.Colors.bgPrimary)
    }
}
