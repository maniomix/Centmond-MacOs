import SwiftUI
import SwiftData

// ============================================================
// MARK: - AI Activity Dashboard (Phase 3: Audit)
// ============================================================
//
// Shows complete history of AI actions with:
//   - action summary + explanation
//   - trust level + risk badge
//   - timestamp
//   - grouped actions for multi-action requests
//
// macOS Centmond: @Observable singletons, ModelContext,
// no undo functionality (not available on macOS backend),
// DS.Card replaced with manual card style.
//
// ============================================================

struct AIActivityDashboard: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let actionHistory = AIActionHistory.shared

    @State private var showWorkflow = false
    @State private var filter: ActivityFilter = .all

    enum ActivityFilter: String, CaseIterable {
        case all       = "All"
        case auto      = "Auto"
        case confirmed = "Confirmed"
        case blocked   = "Blocked"
        case undone    = "Undone"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    quickActionsSection
                    if !actionHistory.records.isEmpty {
                        statsSection
                        filterBar
                    }
                    historySection
                }
                .padding()
            }
            .background(DS.Colors.bg)
            .navigationTitle("AI Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DS.Colors.subtext)
                    }
                    .buttonStyle(.plain)
                }
                if !actionHistory.records.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Menu {
                            Button(role: .destructive) {
                                actionHistory.clear()
                            } label: {
                                Label("Clear History", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(DS.Colors.subtext)
                        }
                    }
                }
            }
            .sheet(isPresented: $showWorkflow) {
                AIWorkflowView()
            }
        }
        .frame(minWidth: 500, minHeight: 450)
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI Tools")
                .font(DS.Typography.section)
                .foregroundStyle(DS.Colors.text)

            HStack(spacing: 12) {
                toolButton(icon: "list.clipboard.fill", title: "Month Review") {
                    showWorkflow = true
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
    }

    private func toolButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(CentmondTheme.Typography.heading1.weight(.regular))
                    .foregroundStyle(DS.Colors.accent)
                Text(title)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .fill(DS.Colors.accent.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Statistics")
                .font(DS.Typography.section)
                .foregroundStyle(DS.Colors.text)

            HStack(spacing: 0) {
                statItem(value: "\(actionHistory.records.count)", label: "Total")
                Spacer()
                statItem(value: "\(actionHistory.todayCount)", label: "Today")
                Spacer()
                statItem(value: "\(actionHistory.undoneCount)", label: "Undone")
                Spacer()
                statItem(value: "\(actionHistory.blockedCount)", label: "Blocked")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.accent)
            Text(label)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.subtext)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ActivityFilter.allCases, id: \.self) { f in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { filter = f }
                    } label: {
                        Text(f.rawValue)
                            .font(DS.Typography.caption)
                            .foregroundStyle(filter == f ? .white : DS.Colors.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(filter == f ? DS.Colors.accent : DS.Colors.accent.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - History

    private var filteredRecords: [AIActionRecord] {
        switch filter {
        case .all:       return actionHistory.records
        case .auto:      return actionHistory.records.filter { $0.trustLevel == "auto" && $0.outcome == .executed }
        case .confirmed: return actionHistory.records.filter { $0.outcome == .confirmed }
        case .blocked:   return actionHistory.records.filter { $0.outcome == .blocked }
        case .undone:    return actionHistory.records.filter { $0.isUndone }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Activity")
                .font(DS.Typography.section)
                .foregroundStyle(DS.Colors.text)

            let records = filteredRecords
            if records.isEmpty {
                emptyState
            } else {
                ForEach(records) { record in
                    activityRow(record)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(CentmondTheme.Typography.display.weight(.regular))
                .foregroundStyle(DS.Colors.subtext.opacity(0.4))
            Text(filter == .all ? "No AI actions yet" : "No \(filter.rawValue.lowercased()) actions")
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.subtext)
            Text("Actions executed by AI will appear here.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.subtext)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
    }

    // MARK: - Activity Row

    private func activityRow(_ record: AIActionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: icon + summary + trust badge
            HStack(spacing: 10) {
                actionIcon(record)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(record.summary)
                            .font(DS.Typography.body)
                            .foregroundStyle(record.isUndone ? DS.Colors.subtext : DS.Colors.text)
                            .strikethrough(record.isUndone)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        trustBadge(record.trustLevel)
                        outcomeBadge(record.outcome, isUndone: record.isUndone)
                        Text(timeAgo(record.executedAt))
                            .font(CentmondTheme.Typography.captionSmall)
                            .foregroundStyle(DS.Colors.subtext)
                    }
                }

                Spacer()
            }

            // Explanation row
            if !record.explanation.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.fill")
                        .font(CentmondTheme.Typography.overlineRegular)
                        .foregroundStyle(DS.Colors.warning)
                    Text(record.explanation)
                        .font(CentmondTheme.Typography.captionSmall)
                        .foregroundStyle(DS.Colors.subtext)
                        .lineLimit(2)
                }
                .padding(.leading, 42)
            }

            // Group indicator
            if let groupLabel = record.groupLabel {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(CentmondTheme.Typography.overlineRegular)
                        .foregroundStyle(DS.Colors.accent.opacity(0.6))
                    Text(groupLabel)
                        .font(CentmondTheme.Typography.captionSmall)
                        .foregroundStyle(DS.Colors.subtext)
                        .lineLimit(1)
                }
                .padding(.leading, 42)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
    }

    // MARK: - Badges

    private func actionIcon(_ record: AIActionRecord) -> some View {
        Image(systemName: iconForType(record.action.type))
            .font(CentmondTheme.Typography.bodyLarge)
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(colorForOutcome(record.outcome, isUndone: record.isUndone), in: Circle())
    }

    private func trustBadge(_ level: String) -> some View {
        let (text, color): (String, Color) = {
            switch level {
            case "auto":      return ("Auto", DS.Colors.positive)
            case "confirm":   return ("Confirmed", DS.Colors.accent)
            case "neverAuto": return ("Blocked", DS.Colors.danger)
            default:          return (level, DS.Colors.subtext)
            }
        }()

        return Text(text)
            .font(CentmondTheme.Typography.overlineSemibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func outcomeBadge(_ outcome: ActionOutcome, isUndone: Bool) -> some View {
        Group {
            if isUndone {
                Text("Undone")
                    .font(CentmondTheme.Typography.overlineSemibold)
                    .foregroundStyle(DS.Colors.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.Colors.warning.opacity(0.12), in: Capsule())
            } else if outcome == .failed {
                Text("Failed")
                    .font(CentmondTheme.Typography.overlineSemibold)
                    .foregroundStyle(DS.Colors.danger)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.Colors.danger.opacity(0.12), in: Capsule())
            }
        }
    }

    // MARK: - Helpers

    private func iconForType(_ type: String) -> String {
        switch type {
        case "add_transaction":     return "plus"
        case "edit_transaction":    return "pencil"
        case "delete_transaction":  return "trash"
        case "split_transaction":   return "person.2"
        case "transfer":            return "arrow.left.arrow.right"
        case "add_recurring":       return "repeat"
        case "edit_recurring":      return "pencil"
        case "cancel_recurring":    return "xmark"
        case "set_budget", "adjust_budget": return "chart.pie"
        case "set_category_budget": return "tag"
        case "create_goal":         return "target"
        case "add_contribution":    return "arrow.up"
        case "update_goal":         return "pencil"
        case "add_subscription":    return "repeat"
        case "cancel_subscription": return "xmark"
        case "update_balance":      return "banknote"
        case "analyze", "compare", "forecast", "advice": return "chart.bar"
        default:                    return "questionmark"
        }
    }

    private func colorForOutcome(_ outcome: ActionOutcome, isUndone: Bool) -> Color {
        if isUndone { return DS.Colors.subtext }
        switch outcome {
        case .executed, .confirmed: return DS.Colors.positive
        case .blocked:              return DS.Colors.danger
        case .failed:               return DS.Colors.danger.opacity(0.7)
        case .pending:              return DS.Colors.warning
        case .rejected:             return DS.Colors.subtext
        case .undone:               return DS.Colors.subtext
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let df = DateFormatter()
        df.dateFormat = "MMM d, HH:mm"
        return df.string(from: date)
    }
}
