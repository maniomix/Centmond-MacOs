import SwiftUI
import Supabase

// ============================================================
// MARK: - AccountSettingsSection (macOS)
// ============================================================
// Drop-in chunk for the user's existing Settings UI. Shows:
//   • Currently signed-in email
//   • Last sync time
//   • Sign Out button
//   • Delete Account (two-step confirmation, calls the
//     `delete_account()` RPC)
//
// Use:
//   Section("Account") { AccountSettingsSection() }
// ============================================================

struct AccountSettingsSection: View {
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var coordinator = CloudSyncCoordinator.shared

    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showDeleteFinal = false
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Email + last sync
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(CentmondTheme.Colors.accent.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Text(initial)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayEmail)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text(syncSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }
                Spacer()
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }

            HStack(spacing: 10) {
                Button("Sign Out") {
                    showSignOutConfirm = true
                }
                .disabled(isWorking)

                Button("Delete Account…") {
                    showDeleteConfirm = true
                }
                .foregroundStyle(CentmondTheme.Colors.negative)
                .disabled(isWorking)

                Spacer()
            }
        }
        .alert("Sign out?", isPresented: $showSignOutConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { signOut() }
        } message: {
            Text("Your local data stays on this Mac. You can sign back in any time.")
        }
        .alert("Delete your account?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) { showDeleteFinal = true }
        } message: {
            Text("We'll remove every transaction, account, budget, and goal you've stored in the cloud. This can't be undone.")
        }
        .alert("Last check", isPresented: $showDeleteFinal) {
            Button("Keep my account", role: .cancel) {}
            Button("Delete everything", role: .destructive) {
                Task { await deleteAccount() }
            }
        } message: {
            Text("Tap Delete everything to confirm.")
        }
    }

    // MARK: - Actions

    private func signOut() {
        do {
            try authManager.signOut()
            CloudSyncCoordinator.shared.stop()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteAccount() async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            try await CloudClient.shared.client.rpc("delete_account").execute()
            SecureLogger.info("Cloud data wiped via delete_account RPC")
        } catch {
            self.error = error.localizedDescription
            SecureLogger.error("delete_account RPC failed", error)
            return
        }

        // Clear locally synced caches that survive sign-out.
        UserDefaults.standard.removeObject(forKey: "centmond.lastSyncedAt")
        UserDefaults.standard.removeObject(forKey: "centmond.cloudDeletionQueue.v1")

        // Force sign-out so the auth screen reappears immediately.
        try? authManager.signOut()
        CloudSyncCoordinator.shared.stop()
    }

    // MARK: - Computed

    private var displayEmail: String {
        if let email = authManager.currentUser?.email, !email.isEmpty {
            return email
        }
        return "—"
    }

    private var initial: String {
        guard let first = displayEmail.first, displayEmail != "—" else { return "?" }
        return String(first).uppercased()
    }

    private var syncSubtitle: String {
        if let last = coordinator.lastSuccessfulSync {
            let s = Int(Date().timeIntervalSince(last))
            if s < 60   { return "Synced just now" }
            if s < 3600 { return "Synced \(s / 60) min ago" }
            if s < 86400 { return "Synced \(s / 3600) h ago" }
            return "Synced \(s / 86400) d ago"
        }
        return coordinator.isOnline ? "Syncing…" : "Offline"
    }
}
