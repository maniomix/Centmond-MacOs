import SwiftUI

// ============================================================
// MARK: - SyncStatusToolbarItem (macOS)
// ============================================================
// Small SF Symbol button suitable for the macOS toolbar. State
// is observed from CloudSyncCoordinator. Click opens a popover
// with details (online status, last sync time, pending changes,
// "Sync now" action).
//
// Drop into AppShell:
//
//   .toolbar {
//       ToolbarItem(placement: .primaryAction) {
//           SyncStatusToolbarItem()
//       }
//   }
// ============================================================

struct SyncStatusToolbarItem: View {
    @ObservedObject private var coordinator = CloudSyncCoordinator.shared
    @Environment(\.modelContext) private var modelContext
    @State private var showPopover = false

    private enum Look { case synced, syncing, offline, error }

    private var look: Look {
        if !coordinator.isOnline { return .offline }
        if case .error = coordinator.status { return .error }
        if case .syncing = coordinator.status { return .syncing }
        return .synced
    }

    var body: some View {
        Button { showPopover = true } label: {
            switch look {
            case .syncing:
                ProgressView().controlSize(.small).tint(CentmondTheme.Colors.accent)
            case .error:
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundStyle(CentmondTheme.Colors.negative)
            case .offline:
                Image(systemName: "cloud.slash.fill")
                    .foregroundStyle(CentmondTheme.Colors.warning)
            case .synced:
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
        }
        .help(accessibilityLabel)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popoverContent
        }
    }

    // MARK: - Popover

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: headlineIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(headlineColor)
                Text(headlineText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let last = coordinator.lastSuccessfulSync {
                    detailRow("Last synced", value: timeAgo(last))
                }
                detailRow("Network", value: coordinator.isOnline ? "Online" : "Offline")
                if coordinator.pendingChanges {
                    detailRow("Pending", value: "Local edits not yet uploaded")
                }
                if case .error(let msg) = coordinator.status {
                    detailRow("Error", value: msg, valueColor: CentmondTheme.Colors.negative)
                }
            }

            Divider()

            Button {
                showPopover = false
                Task { await coordinator.pushDirty(context: modelContext) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Sync now")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(CentmondTheme.Colors.accent.opacity(0.12), in: Capsule())
                .foregroundStyle(CentmondTheme.Colors.accent)
                .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled({
                if case .syncing = coordinator.status { return true }
                return false
            }())
        }
        .padding(14)
        .frame(width: 260)
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String, valueColor: Color = CentmondTheme.Colors.textPrimary) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(valueColor)
                .lineLimit(2)
        }
    }

    // MARK: - Computed

    private var headlineText: String {
        switch look {
        case .synced:  return "All synced"
        case .syncing: return "Syncing now"
        case .offline: return "Offline"
        case .error:   return "Sync error"
        }
    }

    private var headlineColor: Color {
        switch look {
        case .synced:  return CentmondTheme.Colors.positive
        case .syncing: return CentmondTheme.Colors.accent
        case .offline: return CentmondTheme.Colors.warning
        case .error:   return CentmondTheme.Colors.negative
        }
    }

    private var headlineIcon: String {
        switch look {
        case .synced:  return "checkmark.icloud.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .offline: return "cloud.slash.fill"
        case .error:   return "exclamationmark.icloud.fill"
        }
    }

    private var accessibilityLabel: String {
        switch look {
        case .synced:  return "All synced"
        case .syncing: return "Syncing"
        case .offline: return "Offline — saved locally"
        case .error:   return "Sync error"
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60   { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }
}
