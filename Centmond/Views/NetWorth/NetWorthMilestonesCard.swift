import SwiftUI
import SwiftData

// ============================================================
// MARK: - Net Worth Milestones Card (P7)
// ============================================================
//
// Horizontal strip of milestone tiles derived from snapshot
// history. Renders nothing when there are no milestones yet —
// we don't want a permanent empty celebration ribbon.
//
// Includes a compact "Directed to goals this month" chip so the
// user can see how much of their ongoing net-worth build-up is
// pre-committed savings vs passive growth (the goals bridge
// called for in P7 of the Net Worth rebuild plan).
// ============================================================

struct NetWorthMilestonesCard: View {
    let snapshots: [NetWorthSnapshot]

    @Environment(\.modelContext) private var modelContext

    private var milestones: [NetWorthMilestone] {
        NetWorthMilestoneDetector.detect(from: snapshots)
    }

    private var goalsThisMonth: Decimal {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? .now
        let descriptor = FetchDescriptor<GoalContribution>(
            predicate: #Predicate { $0.date >= start && $0.amount > 0 }
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.reduce(Decimal.zero) { $0 + $1.amount }
    }

    var body: some View {
        if milestones.isEmpty && goalsThisMonth == 0 {
            EmptyView()
        } else {
            CardContainer {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    header
                    if !milestones.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: CentmondTheme.Spacing.md) {
                                ForEach(milestones.prefix(6)) { m in
                                    tile(for: m)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MILESTONES")
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(1)
                Text(milestones.isEmpty
                     ? "Keep going — the first milestone is around the corner"
                     : "Markers along the way")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            Spacer()
            if goalsThisMonth > 0 {
                goalsChip
            }
        }
    }

    private var goalsChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "target")
                .font(.system(size: 11, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(CurrencyFormat.compact(goalsThisMonth))
                    .font(CentmondTheme.Typography.captionMedium)
                    .monospacedDigit()
                Text("to goals this month")
                    .font(.system(size: 9))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
        }
        .foregroundStyle(CentmondTheme.Colors.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(CentmondTheme.Colors.accent.opacity(0.10))
        )
        .help("Sum of every GoalContribution posted so far this calendar month — money that's already pre-committed to savings.")
    }

    private func tile(for m: NetWorthMilestone) -> some View {
        let tint = color(for: m.kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: m.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Text(m.title)
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            Text(m.detail)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Text(CurrencyFormat.compact(m.value))
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .padding(12)
        .frame(width: 180, height: 110, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }

    private func color(for kind: NetWorthMilestone.Kind) -> Color {
        switch kind {
        case .thresholdCrossed: return CentmondTheme.Colors.accent
        case .allTimeHigh:      return CentmondTheme.Colors.positive
        case .crossedZero:      return CentmondTheme.Colors.warning
        case .doubled:          return CentmondTheme.Colors.positive
        }
    }
}
