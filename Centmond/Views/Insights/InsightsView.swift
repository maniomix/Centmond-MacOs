import SwiftUI
import SwiftData

struct InsightsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Insight.createdAt, order: .reverse) private var allInsights: [Insight]

    @State private var showDismissed = false
    @State private var filterType: InsightType?
    @State private var showDismissAllConfirmation = false

    private var activeInsights: [Insight] { allInsights.filter { !$0.isDismissed } }
    private var dismissedInsights: [Insight] { allInsights.filter { $0.isDismissed } }

    private var visibleInsights: [Insight] {
        var result = showDismissed ? allInsights : activeInsights
        if let filterType {
            result = result.filter { $0.type == filterType }
        }
        return result.sorted { lhs, rhs in
            let lhsPriority = typePriority(lhs.type)
            let rhsPriority = typePriority(rhs.type)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func typePriority(_ type: InsightType) -> Int {
        switch type {
        case .budgetAlert: 0
        case .spendingAnomaly: 1
        case .savingsOpportunity: 2
        case .subscriptionChange: 3
        case .goalProgress: 4
        case .netWorthMilestone: 5
        }
    }

    private var activeTypes: [InsightType] {
        let source = showDismissed ? allInsights : activeInsights
        let types = Set(source.map(\.type))
        return InsightType.allCases.filter { types.contains($0) }
    }

    var body: some View {
        Group {
            if allInsights.isEmpty {
                EmptyStateView(
                    icon: "lightbulb.fill",
                    heading: "Insights will appear here",
                    description: "Once you have transaction and budget data, Centmond will surface spending patterns and actionable insights."
                )
            } else if visibleInsights.isEmpty && !showDismissed {
                VStack(spacing: CentmondTheme.Spacing.lg) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(CentmondTheme.Colors.positive)

                    Text("All caught up")
                        .font(CentmondTheme.Typography.heading2)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Text("You've reviewed all \(dismissedInsights.count) insight\(dismissedInsights.count == 1 ? "" : "s").")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)

                    Button("Show Dismissed") {
                        showDismissed = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    insightsToolbar

                    Divider().background(CentmondTheme.Colors.strokeSubtle)

                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg),
                            GridItem(.flexible(), spacing: CentmondTheme.Spacing.lg)
                        ], spacing: CentmondTheme.Spacing.lg) {
                            ForEach(visibleInsights) { insight in
                                InsightCard(
                                    insight: insight,
                                    onDismiss: {
                                        withAnimation(CentmondTheme.Motion.layout) {
                                            insight.isDismissed = true
                                        }
                                    },
                                    onRestore: {
                                        withAnimation(CentmondTheme.Motion.layout) {
                                            insight.isDismissed = false
                                        }
                                    },
                                    onDelete: {
                                        withAnimation(CentmondTheme.Motion.layout) {
                                            modelContext.delete(insight)
                                        }
                                    },
                                    onNavigate: { navigateForInsight(insight) }
                                )
                            }
                        }
                        .padding(CentmondTheme.Spacing.xxl)
                    }
                }
            }
        }
        .alert("Dismiss All Insights", isPresented: $showDismissAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Dismiss All") {
                withAnimation(CentmondTheme.Motion.layout) {
                    for insight in activeInsights {
                        insight.isDismissed = true
                    }
                }
            }
        } message: {
            Text("Mark all \(activeInsights.count) active insight\(activeInsights.count == 1 ? "" : "s") as dismissed?")
        }
    }

    // MARK: - Toolbar

    private var insightsToolbar: some View {
        HStack(spacing: CentmondTheme.Spacing.lg) {
            // Count badge
            HStack(spacing: CentmondTheme.Spacing.sm) {
                if activeInsights.count > 0 {
                    Text("\(activeInsights.count)")
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CentmondTheme.Colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
                }
                Text("\(activeInsights.count) active")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }

            if !dismissedInsights.isEmpty {
                Text("\(dismissedInsights.count) dismissed")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }

            Spacer()

            // Type filter chips
            if activeTypes.count > 1 {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    filterChip(label: "All", type: nil)
                    ForEach(activeTypes, id: \.self) { type in
                        filterChip(label: type.shortLabel, type: type)
                    }
                }
            }

            // Actions
            if activeInsights.count > 1 {
                Button {
                    showDismissAllConfirmation = true
                } label: {
                    Text("Dismiss All")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }

            if !dismissedInsights.isEmpty {
                Toggle("Show dismissed", isOn: $showDismissed)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
    }

    private func filterChip(label: String, type: InsightType?) -> some View {
        let isActive = filterType == type
        return Button {
            withAnimation(CentmondTheme.Motion.micro) {
                filterType = type
            }
        } label: {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(isActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isActive ? CentmondTheme.Colors.accent.opacity(0.12) : CentmondTheme.Colors.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navigation

    private func navigateForInsight(_ insight: Insight) {
        switch insight.type {
        case .budgetAlert:
            router.navigate(to: .budget)
        case .spendingAnomaly:
            router.navigate(to: .transactions)
        case .subscriptionChange:
            router.navigate(to: .subscriptions)
        case .savingsOpportunity:
            router.navigate(to: .budget)
        case .goalProgress:
            router.navigate(to: .goals)
        case .netWorthMilestone:
            router.navigate(to: .netWorth)
        }
    }
}

// MARK: - Insight Card

struct InsightCard: View {
    let insight: Insight
    var onDismiss: () -> Void
    var onRestore: () -> Void
    var onDelete: () -> Void
    var onNavigate: () -> Void
    @State private var isHovered = false

    private var typeColor: Color {
        Color(hex: insight.type.colorHex)
    }

    var body: some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
            // Left accent border
            Rectangle()
                .fill(typeColor)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            // Icon
            Image(systemName: insight.type.iconName)
                .font(.system(size: 20))
                .foregroundStyle(typeColor)
                .frame(width: 32, height: 32)
                .background(typeColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

            // Content
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                // Type label
                Text(insight.type.displayName.uppercased())
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(typeColor)
                    .tracking(0.5)

                Text(insight.title)
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(insight.isDismissed ? CentmondTheme.Colors.textTertiary : CentmondTheme.Colors.textPrimary)
                    .lineLimit(2)

                Text(insight.body)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .lineLimit(4)

                HStack(spacing: CentmondTheme.Spacing.md) {
                    Text(insight.createdAt.formatted(.relative(presentation: .named)))
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                    Spacer()

                    Button {
                        onNavigate()
                    } label: {
                        HStack(spacing: 3) {
                            Text("View")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                        }
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)

                    if insight.isDismissed {
                        Button("Restore") {
                            onRestore()
                        }
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .buttonStyle(.plain)
                    } else {
                        Button("Dismiss") {
                            onDismiss()
                        }
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(isHovered ? CentmondTheme.Colors.strokeDefault : CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
        .shadow(color: isHovered ? .black.opacity(0.3) : .clear, radius: 8, y: 2)
        .opacity(insight.isDismissed ? 0.6 : 1.0)
        .onHover { hovering in
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
        .contextMenu {
            if !insight.isDismissed {
                Button { onNavigate() } label: {
                    Label("Go to \(insight.type.displayName)", systemImage: "arrow.right.circle")
                }
                Divider()
                Button { onDismiss() } label: {
                    Label("Dismiss", systemImage: "xmark.circle")
                }
            } else {
                Button { onRestore() } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - InsightType extensions

extension InsightType {
    var shortLabel: String {
        switch self {
        case .spendingAnomaly: "Spending"
        case .budgetAlert: "Budget"
        case .subscriptionChange: "Subscriptions"
        case .savingsOpportunity: "Savings"
        case .goalProgress: "Goals"
        case .netWorthMilestone: "Net Worth"
        }
    }
}
