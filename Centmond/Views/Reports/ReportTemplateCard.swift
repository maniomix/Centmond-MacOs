import SwiftUI

struct ReportTemplateCard: View {
    let kind: ReportKind
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack(alignment: .top) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .frame(width: 40, height: 40)
                        .background(CentmondTheme.Colors.accentMuted)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHovered ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                        .opacity(isHovered ? 1 : 0.6)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title)
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .lineLimit(1)

                    Text(kind.tagline)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(CentmondTheme.Spacing.lg)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
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
                color: .black.opacity(isHovered ? 0.30 : 0.10),
                radius: isHovered ? 10 : 3,
                y: isHovered ? 3 : 1
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(CentmondTheme.Motion.default) { isHovered = hovering }
        }
    }
}

struct SavedReportCard: View {
    let saved: SavedReport
    let onRun: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onRun) {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                HStack(alignment: .center) {
                    Image(systemName: saved.symbol ?? kind?.symbol ?? "doc.text")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .frame(width: 28, height: 28)
                        .background(CentmondTheme.Colors.accentMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Spacer()

                    if isHovered {
                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(CentmondTheme.Colors.negative)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(saved.name)
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .lineLimit(1)

                    Text(footnote)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(CentmondTheme.Spacing.md)
            .frame(width: 200, alignment: .topLeading)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .stroke(isHovered ? CentmondTheme.Colors.strokeStrong : CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
    }

    private var kind: ReportKind? {
        guard let raw = saved.kindRaw else { return nil }
        return ReportKind(rawValue: raw)
    }

    private var footnote: String {
        if let last = saved.lastRunAt {
            return "Last run " + last.formatted(.relative(presentation: .named))
        }
        return "Never run"
    }
}
