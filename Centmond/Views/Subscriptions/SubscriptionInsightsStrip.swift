import SwiftUI
import SwiftData

/// Horizontal strip of optimizer insights. Re-runs `AISubscriptionOptimizer`
/// on every appear so newly-detected price hikes / expiring trials surface
/// without a manual refresh. Each card is tappable to apply the bound action
/// (cancel / pause / switch-to-annual / acknowledge).
///
/// Intentionally compact — when the optimizer finds zero recommendations the
/// strip collapses entirely, keeping the hub chrome minimal.
struct SubscriptionInsightsStrip: View {
    let subscriptions: [Subscription]
    @Environment(\.modelContext) private var modelContext
    @State private var result: SubscriptionOptimizationResult?
    @State private var applied: Set<UUID> = []

    var body: some View {
        if let r = result, !visibleRecs(r).isEmpty {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                header(r)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        ForEach(visibleRecs(r)) { rec in
                            insightCard(rec)
                        }
                    }
                }
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.md)
            .background(CentmondTheme.Colors.bgPrimary)
            .onAppear(perform: reload)
            .onChange(of: subscriptions.count) { _, _ in reload() }
        } else {
            Color.clear.frame(height: 0).onAppear(perform: reload)
        }
    }

    // MARK: - Pieces

    private func header(_ r: SubscriptionOptimizationResult) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(CentmondTheme.Typography.captionSmall)
                .foregroundStyle(CentmondTheme.Colors.accent)
            Text("INSIGHTS")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)
            if r.potentialSavings > 0 {
                Text("·  save up to \(CurrencyFormat.standard(r.potentialSavings))/mo")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
            Spacer()
        }
    }

    private func insightCard(_ rec: SubscriptionOptimizationResult.Recommendation) -> some View {
        let tint = urgencyTint(rec.urgency)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: iconFor(rec.type))
                    .font(CentmondTheme.Typography.overlineSemibold)
                    .foregroundStyle(tint)
                Text(rec.subscriptionName)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
            }
            Text(rec.reason)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if rec.potentialSaving > 0 {
                    Text("save \(CurrencyFormat.standard(rec.potentialSaving))/mo")
                        .font(CentmondTheme.Typography.overlineSemibold.monospacedDigit())
                        .foregroundStyle(CentmondTheme.Colors.positive)
                }
                Spacer()
                actionButton(rec)
            }
        }
        .padding(CentmondTheme.Spacing.md)
        .frame(width: 260, height: 110, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                .fill(CentmondTheme.Colors.bgSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }

    private func actionButton(_ rec: SubscriptionOptimizationResult.Recommendation) -> some View {
        let label = actionLabel(rec.actionType)
        let isApplied = applied.contains(rec.id)
        return Button {
            guard !isApplied else { return }
            Haptics.impact()
            _ = AISubscriptionOptimizer.apply(rec, in: modelContext)
            applied.insert(rec.id)
        } label: {
            Text(isApplied ? "Done" : label)
                .font(CentmondTheme.Typography.overlineSemibold)
                .foregroundStyle(isApplied ? CentmondTheme.Colors.textTertiary : CentmondTheme.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isApplied
                        ? CentmondTheme.Colors.bgQuaternary
                        : CentmondTheme.Colors.bgTertiary)
                )
        }
        .buttonStyle(.plain)
        .disabled(isApplied)
    }

    // MARK: - Helpers

    private func reload() {
        result = AISubscriptionOptimizer.shared.analyze(context: modelContext)
    }

    /// Surface only actionable, non-noisy recs on the strip. The full list
    /// still lives in the detail view (P7 follow-up) when we want a richer
    /// breakdown — the strip is for top-of-funnel nudges only.
    private func visibleRecs(_ r: SubscriptionOptimizationResult) -> [SubscriptionOptimizationResult.Recommendation] {
        r.recommendations
            .filter { !applied.contains($0.id) }
            .filter { $0.urgency != .info || $0.potentialSaving > 0 }
            .prefix(8)
            .map { $0 }
    }

    private func urgencyTint(_ u: SubscriptionOptimizationResult.Recommendation.Urgency) -> Color {
        switch u {
        case .urgent:     return CentmondTheme.Colors.negative
        case .attention:  return CentmondTheme.Colors.warning
        case .suggestion: return CentmondTheme.Colors.accent
        case .info:       return CentmondTheme.Colors.textSecondary
        }
    }

    private func iconFor(_ t: SubscriptionOptimizationResult.Recommendation.RecommendationType) -> String {
        switch t {
        case .cancel:           return "xmark.circle.fill"
        case .downgrade:        return "arrow.down.circle.fill"
        case .overlap:          return "rectangle.stack.fill"
        case .freeAlternative:  return "gift.fill"
        case .trialEnding:      return "clock.fill"
        case .priceHike:        return "arrow.up.right.circle.fill"
        case .annualSavings:    return "calendar.badge.plus"
        case .pastDue:          return "exclamationmark.triangle.fill"
        case .duplicateCharge:  return "doc.on.doc.fill"
        }
    }

    private func actionLabel(_ a: SubscriptionOptimizationResult.Recommendation.ActionType) -> String {
        switch a {
        case .cancel: return "Cancel"
        case .pause: return "Pause"
        case .switchToAnnual: return "Switch to annual"
        case .acknowledgePriceChange: return "Got it"
        case .acknowledgeDuplicate: return "Acknowledge"
        case .review: return "Review"
        }
    }
}
