import SwiftUI

struct CardContainer<Content: View>: View {
    let content: Content
    @State private var isHovered = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(CentmondTheme.Spacing.lg)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                    .stroke(
                        isHovered ? CentmondTheme.Colors.strokeStrong : CentmondTheme.Colors.strokeDefault,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(isHovered ? 0.35 : 0.15),
                radius: isHovered ? 12 : 4,
                y: isHovered ? 4 : 2
            )
            .onHover { hovering in
                withAnimation(CentmondTheme.Motion.default) {
                    isHovered = hovering
                }
            }
    }
}
