import SwiftUI
import SwiftData

// ============================================================
// MARK: - AI Insight Banner (P4)
// ============================================================
//
// Compact card for a single AIInsight. Renders the severity
// pill, warning text, optional advice line, primary CTA button,
// and a dismiss/snooze menu. All action plumbing (structured
// action, deeplink, auto-dismiss) goes through
// `AIInsightEngine.apply` so every surface that shows insights
// gets identical behavior.
//
// ============================================================

struct AIInsightBanner: View {
    let insight: AIInsight

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    private let engine = AIInsightEngine.shared

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

            Text(insight.warning)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.subtext)
                .fixedSize(horizontal: false, vertical: true)

            if let advice = insight.advice, !advice.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(severityColor)
                    Text(advice)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let cause = insight.cause, !cause.isEmpty {
                Text(cause)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.subtext.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if !insight.primaryActionLabel.isEmpty {
                    Button {
                        engine.apply(insight, router: router, context: modelContext)
                    } label: {
                        Text(insight.primaryActionLabel)
                            .font(DS.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(severityColor)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Menu {
                    Button("Snooze 1 day") {
                        engine.dismiss(insight, context: modelContext, snoozeDays: 1)
                    }
                    Button("Snooze 7 days") {
                        engine.dismiss(insight, context: modelContext, snoozeDays: 7)
                    }
                    Divider()
                    Button("Dismiss permanently", role: .destructive) {
                        engine.dismiss(insight, context: modelContext, snoozeDays: nil)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Colors.subtext)
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
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
        switch insight.kind {
        case .budgetWarning:        return "exclamationmark.triangle"
        case .spendingAnomaly:      return "exclamationmark.circle"
        case .savingsOpportunity:   return "lightbulb"
        case .recurringDetected:    return "repeat.circle"
        case .weeklyReport:         return "calendar"
        case .goalProgress:         return "target"
        case .patternDetected:      return "chart.bar"
        case .morningBriefing:      return "sun.max"
        case .subscriptionRenewal:  return "arrow.clockwise.circle"
        case .subscriptionUnused:   return "zzz"
        case .cashflowRisk:         return "drop.triangle"
        case .duplicateTransaction: return "doc.on.doc"
        }
    }

    private var severityColor: Color {
        switch insight.severity {
        case .critical: return DS.Colors.danger
        case .warning:  return DS.Colors.warning
        case .watch:    return DS.Colors.accent
        case .positive: return DS.Colors.positive
        }
    }

    private var severityDot: some View {
        Circle()
            .fill(severityColor)
            .frame(width: 8, height: 8)
    }
}

// MARK: - Dashboard Insight Row

struct AIInsightRow: View {
    let insights: [AIInsight]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(insights.prefix(5)) { insight in
                    AIInsightBanner(insight: insight)
                        .frame(width: 280)
                }
            }
            .padding(.horizontal)
        }
    }
}
