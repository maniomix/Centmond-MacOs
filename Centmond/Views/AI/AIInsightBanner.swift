import SwiftUI

// ============================================================
// MARK: - AI Insight Banner
// ============================================================
//
// Compact banner card for displaying a single AIInsight.
// Used on the dashboard and insights screen.
//
// ============================================================

struct AIInsightBanner: View {
    let insight: AIInsight
    var onAction: ((AIAction) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(severityColor)
                Text(insight.title)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.text)
                Spacer()
                severityDot
            }

            Text(insight.body)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.subtext)
                .fixedSize(horizontal: false, vertical: true)

            if let action = insight.suggestedAction {
                Button {
                    onAction?(action)
                } label: {
                    Text(actionLabel(action))
                        .font(DS.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DS.Colors.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(severityColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch insight.type {
        case .budgetWarning: return "exclamationmark.triangle"
        case .spendingAnomaly: return "exclamationmark.circle"
        case .savingsOpportunity: return "lightbulb"
        case .recurringDetected: return "repeat.circle"
        case .weeklyReport: return "calendar"
        case .goalProgress: return "target"
        case .patternDetected: return "chart.bar"
        case .morningBriefing: return "sun.max"
        }
    }

    private var severityColor: Color {
        switch insight.severity {
        case .critical: return DS.Colors.danger
        case .warning: return DS.Colors.warning
        case .info: return DS.Colors.accent
        case .positive: return DS.Colors.positive
        }
    }

    private var severityDot: some View {
        Circle()
            .fill(severityColor)
            .frame(width: 8, height: 8)
    }

    private func actionLabel(_ action: AIAction) -> String {
        switch action.type {
        case .addContribution: return "Add contribution"
        case .cancelSubscription: return "Cancel subscription"
        case .setBudget: return "Set budget"
        default: return "Take action"
        }
    }
}

// MARK: - Dashboard Insight Row

struct AIInsightRow: View {
    let insights: [AIInsight]
    var onAction: ((AIAction) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(insights.prefix(5)) { insight in
                    AIInsightBanner(insight: insight, onAction: onAction)
                        .frame(width: 280)
                }
            }
            .padding(.horizontal)
        }
    }
}
