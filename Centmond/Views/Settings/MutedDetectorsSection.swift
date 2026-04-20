import SwiftUI

// ============================================================
// MARK: - Muted Detectors Section (P8)
// ============================================================
//
// Compact settings row listing every detector that's currently
// muted — either auto-muted by the telemetry heuristic after
// repeated dismissals, or manually muted by the user. Each
// entry shows its counters and an "Un-mute" button.
//
// Empty state is no-render — when nothing's muted we hide the
// whole section rather than showing "No muted detectors" noise.
// ============================================================

struct MutedDetectorsSection: View {
    @State private var telemetry = InsightTelemetry.shared

    private var mutedEntries: [(id: String, counters: InsightTelemetry.Counters)] {
        telemetry.counters
            .filter { $0.value.muted }
            .map { (id: $0.key, counters: $0.value) }
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        if !mutedEntries.isEmpty {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                HStack {
                    Label("Muted Insights", systemImage: "bell.slash.fill")
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    Spacer()
                    Text("\(mutedEntries.count)")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }

                ForEach(mutedEntries, id: \.id) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detectorDisplayName(entry.id))
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            Text("Shown \(entry.counters.shown) • Dismissed \(entry.counters.dismissed)")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                        Spacer()
                        Button("Un-mute") {
                            telemetry.setMuted(entry.id, muted: false)
                        }
                        .buttonStyle(SecondaryChipButtonStyle())
                    }
                }
            }
        }
    }

    private func detectorDisplayName(_ id: String) -> String {
        switch id {
        case "cashflow:runway":         return "Low runway"
        case "cashflow:incomeDrop":     return "Income drop"
        case "subscription:unused":     return "Unused subscriptions"
        case "subscription:hike":       return "Subscription price hikes"
        case "subscription:duplicate":  return "Duplicate subscriptions"
        case "recurring:overdue":       return "Overdue recurring"
        case "anomaly:daySpike":        return "Unusual-day spikes"
        case "anomaly:newMerchant":     return "New large merchants"
        case "duplicate:txn":           return "Duplicate transactions"
        case "budget:exceeded":         return "Budget exceeded"
        case "budget:pace":             return "Budget pace ahead"
        case "budget:cat":              return "Category over budget"
        case "goal:almost":             return "Goal almost complete"
        case "goal:overdue":            return "Goal overdue"
        case "goal:stalled":            return "Goal stalled"
        case "pattern:topCategory":     return "Top category summary"
        case "sub:renew":               return "Upcoming renewals"
        default:                        return id
        }
    }
}
