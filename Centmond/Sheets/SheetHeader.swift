import SwiftUI

struct SheetHeader: View {
    let title: String
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(CentmondTheme.Typography.heading2)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(CentmondTheme.Colors.bgQuaternary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plainHover)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.top, CentmondTheme.Spacing.xl)
        .padding(.bottom, CentmondTheme.Spacing.lg)
    }
}
