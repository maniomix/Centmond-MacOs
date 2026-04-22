import SwiftUI

// ============================================================
// MARK: - Dashboard Insight Strip (P5)
// ============================================================
//
// Top-of-dashboard row that surfaces the 1–2 most urgent
// insights. Only renders when there's something worth showing
// (non-positive insights exist). Empty state is no-render — we
// don't want a permanent "all clear" ribbon taking space.
//
// Delegates to `AIInsightBanner` for every card so visual +
// action behavior matches the full Insights hub. Tail "See all"
// chip routes to the hub itself.
// ============================================================

struct DashboardInsightStrip: View {
    @Environment(AppRouter.self) private var router
    private let engine = AIInsightEngine.shared

    private var topInsights: [AIInsight] {
        // Non-positive, already sorted by severity desc in the engine.
        engine.insights
            .filter { $0.severity != .positive }
            .prefix(2)
            .map { $0 }
    }

    var body: some View {
        if !topInsights.isEmpty {
            HStack(alignment: .top, spacing: CentmondTheme.Spacing.lg) {
                ForEach(topInsights) { insight in
                    AIInsightBanner(insight: insight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if engine.insights.count > topInsights.count {
                    seeAllChip
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var seeAllChip: some View {
        Button {
            router.navigate(to: .insights)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 14, weight: .semibold))
                Text("See all")
                    .font(CentmondTheme.Typography.caption)
                    .fontWeight(.semibold)
                Text("\(engine.insights.count)")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .foregroundStyle(CentmondTheme.Colors.accent)
            .frame(width: 88)
            .frame(maxHeight: .infinity)
            .padding(.vertical, CentmondTheme.Spacing.md)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CentmondTheme.Colors.accent.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plainHover)
    }
}
