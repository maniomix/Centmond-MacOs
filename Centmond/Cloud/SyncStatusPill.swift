import SwiftUI

// ============================================================
// MARK: - SyncStatusPill (macOS)
// ============================================================
// Auto-hiding banner that surfaces sync state only when the
// user actually needs to see it.
//
// Show conditions:
//   • Offline                              — show immediately
//   • Sync error                           — show immediately
//   • Pending sync stuck > 2 s             — show after sustain delay
//
// The sustain delay matters: a normal save → push cycle takes
// ~2-3 s with the debounce. Without sustain, the pill flips
// "Syncing… → hidden" every keystroke and looks broken. With
// sustain, it stays invisible for fast cycles and only appears
// when something is genuinely slow / stuck.
//
// Mount on AppShell (or RootView) via:
//   .overlay(alignment: .top) { SyncStatusPill() }
// ============================================================

struct SyncStatusPill: View {
    @ObservedObject private var coordinator = CloudSyncCoordinator.shared
    @State private var showPendingPill: Bool = false
    @State private var pendingTask: Task<Void, Never>?

    private let pendingSustain: TimeInterval = 2.0

    var body: some View {
        Group {
            if let info = pillInfo {
                HStack(spacing: 8) {
                    Image(systemName: info.icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(info.label)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(info.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(info.background, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(info.foreground.opacity(0.18), lineWidth: 0.5)
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: pillInfo?.label)
        .onChange(of: coordinator.pendingChanges) { _, isPending in
            pendingTask?.cancel()
            if isPending {
                pendingTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(pendingSustain * 1_000_000_000))
                    if !Task.isCancelled,
                       coordinator.pendingChanges,
                       coordinator.isOnline,
                       case .syncing = coordinator.status {
                        showPendingPill = true
                    } else if !Task.isCancelled, !coordinator.pendingChanges {
                        showPendingPill = false
                    }
                }
            } else {
                showPendingPill = false
            }
        }
        .onChange(of: coordinator.status) { _, newStatus in
            if case .syncing = newStatus { return }
            showPendingPill = false
        }
    }

    // MARK: - State → look

    private var pillInfo: PillInfo? {
        if !coordinator.isOnline {
            return PillInfo(
                label: "Offline — saved locally",
                icon: "wifi.slash",
                foreground: CentmondTheme.Colors.warning,
                background: CentmondTheme.Colors.warningMuted
            )
        }
        if case .error = coordinator.status {
            return PillInfo(
                label: "Sync error — will retry",
                icon: "exclamationmark.triangle.fill",
                foreground: CentmondTheme.Colors.negative,
                background: CentmondTheme.Colors.negativeMuted
            )
        }
        if showPendingPill {
            return PillInfo(
                label: "Syncing changes…",
                icon: "arrow.triangle.2.circlepath",
                foreground: CentmondTheme.Colors.accent,
                background: CentmondTheme.Colors.accentMuted
            )
        }
        return nil
    }

    private struct PillInfo {
        let label: String
        let icon: String
        let foreground: Color
        let background: Color
    }
}
