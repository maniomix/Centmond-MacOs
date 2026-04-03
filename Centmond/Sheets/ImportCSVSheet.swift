import SwiftUI

struct ImportCSVSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isDragOver = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SheetHeader(title: "Import CSV") { dismiss() }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Content
            VStack(spacing: CentmondTheme.Spacing.xl) {
                Spacer()

                // Drop zone
                VStack(spacing: CentmondTheme.Spacing.md) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(isDragOver ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)

                    Text("Drag & drop a CSV file here")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)

                    Text("or")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)

                    Button("Browse Files") {
                        // TODO: NSOpenPanel integration
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, CentmondTheme.Spacing.xxl)
                .background(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                        .strokeBorder(
                            isDragOver ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault,
                            style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                        )
                )
                .padding(.horizontal, CentmondTheme.Spacing.xxl)

                // Format hint
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                    Text("SUPPORTED FORMATS")
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .tracking(0.3)

                    Text("CSV files with columns: Date, Payee, Amount, Category (optional)")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)

                Spacer()
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 400)
    }
}
