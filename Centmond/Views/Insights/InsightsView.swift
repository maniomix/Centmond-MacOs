import SwiftUI
import SwiftData

// ============================================================
// MARK: - Insights Hub (P5)
// ============================================================
//
// Single surface for every insight the engine emits. Grouped
// by severity, filterable by domain, with a calm empty state
// that leans on positive insights when the queue is clear.
//
// Data source: `AIInsightEngine.shared.insights` (in-memory,
// refreshed on launch / scene-active / midnight). The engine
// owns dedupe + dismissals + caps; this view just renders and
// routes taps through `engine.apply`.
// ============================================================

struct InsightsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext

    private let engine = AIInsightEngine.shared

    @State private var filterDomain: AIInsight.Domain?

    // MARK: - Derived

    private var allInsights: [AIInsight] { engine.insights }

    private var visibleInsights: [AIInsight] {
        guard let filterDomain else { return allInsights }
        return allInsights.filter { $0.domain == filterDomain }
    }

    private var criticals: [AIInsight] { visibleInsights.filter { $0.severity == .critical } }
    private var warnings:  [AIInsight] { visibleInsights.filter { $0.severity == .warning } }
    private var watches:   [AIInsight] { visibleInsights.filter { $0.severity == .watch } }
    private var positives: [AIInsight] { visibleInsights.filter { $0.severity == .positive } }

    private var activeDomains: [AIInsight.Domain] {
        AIInsight.Domain.allCases.filter { d in allInsights.contains(where: { $0.domain == d }) }
    }

    private var nonPositiveCount: Int {
        allInsights.filter { $0.severity != .positive }.count
    }

    // MARK: - Body

    var body: some View {
        content
            .background(CentmondTheme.Colors.bgPrimary)
            .onAppear { engine.refresh(context: modelContext) }
    }

    @ViewBuilder
    private var content: some View {
        if allInsights.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider().background(CentmondTheme.Colors.strokeSubtle)

                ScrollView {
                    VStack(spacing: CentmondTheme.Spacing.xl) {
                        section("Needs action", insights: criticals, tint: CentmondTheme.Colors.negative)
                        section("Worth a look", insights: warnings,  tint: CentmondTheme.Colors.warning)
                        section("Keep an eye on", insights: watches,  tint: CentmondTheme.Colors.accent)
                        section("Going well",    insights: positives, tint: CentmondTheme.Colors.positive)
                    }
                    .padding(CentmondTheme.Spacing.xxl)
                }
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: CentmondTheme.Spacing.lg) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                if nonPositiveCount > 0 {
                    Text("\(nonPositiveCount)")
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CentmondTheme.Colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
                }
                Text("\(allInsights.count) active")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }

            Spacer()

            if activeDomains.count > 1 {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    filterChip(label: "All", domain: nil)
                    ForEach(activeDomains, id: \.self) { d in
                        filterChip(label: d.displayName, domain: d)
                    }
                }
            }

            Button {
                engine.refresh(context: modelContext)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .buttonStyle(.plainHover)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
    }

    private func filterChip(label: String, domain: AIInsight.Domain?) -> some View {
        let isActive = filterDomain == domain
        return Button {
            withAnimation(CentmondTheme.Motion.micro) { filterDomain = domain }
        } label: {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(isActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isActive ? CentmondTheme.Colors.accent.opacity(0.12) : CentmondTheme.Colors.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
        }
        .buttonStyle(.plainHover)
    }

    // MARK: - Section

    @ViewBuilder
    private func section(_ title: String, insights: [AIInsight], tint: Color) -> some View {
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(title)
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(tint)
                        .tracking(0.5)
                    Text("\(insights.count)")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    Spacer()
                }

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg),
                    GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg)
                ], spacing: CentmondTheme.Spacing.lg) {
                    ForEach(insights) { insight in
                        AIInsightBanner(insight: insight)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(CentmondTheme.Colors.positive)

            Text("All clear")
                .font(CentmondTheme.Typography.heading2)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            Text("Nothing needs your attention right now. Keep logging transactions and Centmond will flag anything worth acting on.")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            Button("Refresh now") {
                engine.refresh(context: modelContext)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Domain display names

extension AIInsight.Domain {
    var displayName: String {
        switch self {
        case .budget:       return "Budget"
        case .subscription: return "Subscriptions"
        case .goal:         return "Goals"
        case .recurring:    return "Recurring"
        case .anomaly:      return "Anomalies"
        case .cashflow:     return "Cashflow"
        case .duplicate:    return "Duplicates"
        }
    }
}
