import SwiftUI

// ============================================================
// MARK: - Dashboard Review Queue Strip (P6)
// ============================================================
//
// Compact banner surfaced on the Dashboard when the Review Queue
// has items. Tapping navigates to the hub; the secondary "Triage"
// button enters focus mode directly. No-renders when count == 0
// so the Dashboard stays calm when there's nothing to do.
// ============================================================

struct DashboardReviewStrip: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        if router.reviewQueueCount > 0 {
            Button { router.navigate(to: .reviewQueue) } label: {
                HStack(spacing: CentmondTheme.Spacing.md) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .frame(width: 32, height: 32)
                        .background(CentmondTheme.Colors.accent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(router.reviewQueueCount) \(router.reviewQueueCount == 1 ? "item" : "items") to review")
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Text("Uncategorized, pending, or flagged")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    }

                    Spacer()

                    Button {
                        router.requestTriage = true
                        router.navigate(to: .reviewQueue)
                    } label: {
                        Label("Triage", systemImage: "bolt.fill")
                            .font(CentmondTheme.Typography.caption)
                    }
                    .buttonStyle(GhostButtonStyle())

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.vertical, CentmondTheme.Spacing.md)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(CentmondTheme.Colors.accent.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plainHover)
        }
    }
}
