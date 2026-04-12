import SwiftUI
import SwiftData
import os

// ============================================================
// MARK: - AI Optimizer View (Phase 8)
// ============================================================
//
// Displays optimization results as structured cards.
// Shows recommendations, projected impact, assumptions,
// and tradeoff comparisons.
//
// macOS Centmond: ModelContext instead of Store, @Observable,
// amounts in dollars (Decimal), no presentation detents.
//
// ============================================================

private let logger = Logger(subsystem: "com.centmond", category: "AIOptimizerView")

struct AIOptimizerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let optimizer = AIOptimizer.shared

    @State private var selectedType: OptimizationType? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // -- Quick actions grid --
                    optimizationPicker

                    // -- Result card --
                    if let result = optimizer.latestResult {
                        optimizationResultCard(result)
                    } else {
                        emptyState
                    }

                    // -- History --
                    if optimizer.resultHistory.count > 1 {
                        historySection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(DS.Colors.bg)
            .navigationTitle("Optimizer")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .frame(minWidth: 450, minHeight: 400)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - Optimization Picker
    // ══════════════════════════════════════════════════════════

    private var optimizationPicker: some View {
        let types: [(OptimizationType, String)] = [
            (.safeToSpend,        "Safe to Spend"),
            (.budgetRescue,       "Budget Rescue"),
            (.goalCatchUp,        "Goal Catch-Up"),
            (.subscriptionCleanup,"Subscriptions"),
            (.leanMonthPlan,      "Lean Month"),
            (.spendingFreeze,     "Spending Freeze"),
        ]

        return LazyVGrid(columns: [
            GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
        ], spacing: 10) {
            ForEach(types, id: \.0) { (type, label) in
                Button {
                    runOptimization(type)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: type.icon)
                            .font(.system(size: 20))
                            .foregroundStyle(optimizer.latestResult?.type == type ? .white : DS.Colors.accent)
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(optimizer.latestResult?.type == type ? .white : DS.Colors.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(optimizer.latestResult?.type == type
                                  ? DS.Colors.accent
                                  : (colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - Result Card
    // ══════════════════════════════════════════════════════════

    private func optimizationResultCard(_ result: OptimizationResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: result.type.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(DS.Typography.callout)
                        .fontWeight(.bold)
                        .foregroundStyle(DS.Colors.text)
                    Text(result.summary)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                confidenceBadge(result.confidence)
            }

            // Projected impact
            if let impact = result.projectedImpact {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11))
                    Text(impact)
                        .font(DS.Typography.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(DS.Colors.positive)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(DS.Colors.positive.opacity(0.1), in: Capsule())
            }

            // Projected savings
            if let savings = result.projectedSavings, savings > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11))
                    Text("Potential savings: \(fmtDollars(savings))")
                        .font(DS.Typography.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(DS.Colors.accent)
            }

            Divider()

            // Recommendations
            VStack(alignment: .leading, spacing: 8) {
                Text("Recommendations")
                    .font(DS.Typography.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(DS.Colors.text)

                ForEach(result.recommendations) { rec in
                    recommendationRow(rec)
                }
            }

            // Scenarios (tradeoff comparison)
            if !result.scenarios.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Comparison")
                        .font(DS.Typography.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(DS.Colors.text)

                    ForEach(result.scenarios) { scenario in
                        scenarioCard(scenario)
                    }
                }
            }

            // Assumptions
            if !result.assumptions.isEmpty {
                Divider()
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(result.assumptions, id: \.self) { a in
                            Text("- \(a)")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Colors.subtext)
                        }
                    }
                } label: {
                    Text("Assumptions")
                        .font(DS.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(DS.Colors.subtext)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(DS.Colors.accent.opacity(0.15), lineWidth: 1)
        )
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - Recommendation Row
    // ══════════════════════════════════════════════════════════

    private func recommendationRow(_ rec: OptimizationRecommendation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: rec.impact.icon)
                .font(.system(size: 12))
                .foregroundStyle(impactColor(rec.impact))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title)
                    .font(DS.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DS.Colors.text)
                Text(rec.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let amount = rec.amount, amount != 0 {
                Text(fmtDollars(amount))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(DS.Colors.text)
            }
        }
        .padding(.vertical, 4)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - Scenario Card
    // ══════════════════════════════════════════════════════════

    private func scenarioCard(_ scenario: OptimizationScenario) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(scenario.label)
                    .font(DS.Typography.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(DS.Colors.text)
                Spacer()
                Text("Risk: \(scenario.riskLevel)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(scenario.riskLevel == "high" ? DS.Colors.danger : (scenario.riskLevel == "moderate" ? DS.Colors.warning : DS.Colors.positive))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        (scenario.riskLevel == "high" ? DS.Colors.danger : (scenario.riskLevel == "moderate" ? DS.Colors.warning : DS.Colors.positive)).opacity(0.1),
                        in: Capsule()
                    )
            }

            Text(scenario.description)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.subtext)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pros")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Colors.positive)
                    ForEach(scenario.pros, id: \.self) { pro in
                        Text("+ \(pro)")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Colors.subtext)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cons")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Colors.danger)
                    ForEach(scenario.cons, id: \.self) { con in
                        Text("- \(con)")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Colors.subtext)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.accent.opacity(0.04))
        )
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - History
    // ══════════════════════════════════════════════════════════

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(DS.Typography.caption)
                .fontWeight(.bold)
                .foregroundStyle(DS.Colors.text)

            ForEach(optimizer.resultHistory.dropFirst().prefix(5)) { result in
                Button {
                    optimizer.latestResult = result
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: result.type.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Colors.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.title)
                                .font(DS.Typography.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(DS.Colors.text)
                            Text(timeAgo(result.createdAt))
                                .font(.system(size: 10))
                                .foregroundStyle(DS.Colors.subtext)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Colors.subtext)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - Empty State
    // ══════════════════════════════════════════════════════════

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.line.text.clipboard")
                .font(.system(size: 40))
                .foregroundStyle(DS.Colors.accent.opacity(0.6))
            Text("Choose an Optimization")
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Colors.text)
            Text("Click an option above to generate a financial plan or analysis.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.subtext)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: - Helpers
    // ══════════════════════════════════════════════════════════

    private func runOptimization(_ type: OptimizationType) {
        switch type {
        case .safeToSpend:
            _ = optimizer.safeToSpend(context: context)
        case .budgetRescue, .budgetReallocation:
            _ = optimizer.budgetRescue(context: context)
        case .goalCatchUp:
            _ = optimizer.goalCatchUp(context: context)
        case .subscriptionCleanup:
            _ = optimizer.subscriptionCleanup(context: context)
        case .leanMonthPlan:
            _ = optimizer.leanMonthPlan(context: context)
        case .spendingFreeze:
            _ = optimizer.spendingFreeze(context: context)
        case .paycheckAllocation:
            let budget = currentBudgetEstimate()
            _ = optimizer.paycheckAllocation(context: context, paycheckAmount: budget)
        case .tradeoffComparison:
            break // Requires specific inputs -- triggered from chat
        }
    }

    /// Rough paycheck estimate: uses the current month's total budget as a proxy.
    private func currentBudgetEstimate() -> Decimal {
        let cal = Calendar.current
        let year = cal.component(.year, from: Date())
        let month = cal.component(.month, from: Date())
        let descriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        return (try? context.fetch(descriptor).first?.amount) ?? 3000
    }

    private func confidenceBadge(_ confidence: Double) -> some View {
        let pct = Int(confidence * 100)
        let color: Color = confidence >= 0.7 ? DS.Colors.positive
            : (confidence >= 0.5 ? DS.Colors.accent : DS.Colors.subtext)
        return Text("\(pct)%")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func impactColor(_ impact: OptimizationRecommendation.Impact) -> Color {
        switch impact {
        case .high:   return DS.Colors.danger
        case .medium: return DS.Colors.warning
        case .low:    return DS.Colors.positive
        }
    }

    private func fmtDollars(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        let isNeg = d < 0
        let str = String(format: "$%.2f", abs(d))
        return isNeg ? "-\(str)" : str
    }

    private func timeAgo(_ date: Date) -> String {
        let mins = Int(Date().timeIntervalSince(date) / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

// ══════════════════════════════════════════════════════════════
// MARK: - Compact Optimization Card (for Chat/Dashboard)
// ══════════════════════════════════════════════════════════════

/// A compact card that summarizes an optimization result.
/// Can be embedded in chat messages or dashboard.
struct AIOptimizationCard: View {
    let result: OptimizationResult
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: result.type.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
                Text(result.title)
                    .font(DS.Typography.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(DS.Colors.text)
                Spacer()
                if let savings = result.projectedSavings, savings > 0 {
                    Text(fmtDollars(savings))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(DS.Colors.positive)
                }
            }

            Text(result.summary)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.subtext)
                .fixedSize(horizontal: false, vertical: true)

            // Top 2 recommendations
            ForEach(result.recommendations.prefix(2)) { rec in
                HStack(spacing: 6) {
                    Image(systemName: rec.impact.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(impactColor(rec.impact))
                    Text(rec.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.text)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DS.Colors.accent.opacity(0.15), lineWidth: 1)
        )
    }

    private func impactColor(_ impact: OptimizationRecommendation.Impact) -> Color {
        switch impact {
        case .high:   return DS.Colors.danger
        case .medium: return DS.Colors.warning
        case .low:    return DS.Colors.positive
        }
    }

    private func fmtDollars(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        let isNeg = d < 0
        let str = String(format: "$%.2f", abs(d))
        return isNeg ? "-\(str)" : str
    }
}
