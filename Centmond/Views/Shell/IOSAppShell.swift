#if os(iOS)
import SwiftUI
import SwiftData
import Auth

/// Placeholder iOS shell — proves the iOS target builds and runs end-to-end.
/// Track B3-B6 will replace this with the real TabView shell + native views.
struct IOSAppShell: View {
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var coordinator = CloudSyncCoordinator.shared

    var body: some View {
        TabView {
            placeholder("Dashboard", icon: "house.fill")
                .tabItem { Label("Dashboard", systemImage: "house.fill") }

            placeholder("Transactions", icon: "list.bullet.rectangle.fill")
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle.fill") }

            placeholder("Budgets", icon: "chart.pie.fill")
                .tabItem { Label("Budgets", systemImage: "chart.pie.fill") }

            placeholder("Reports", icon: "doc.richtext.fill")
                .tabItem { Label("Reports", systemImage: "doc.richtext.fill") }

            accountTab
                .tabItem { Label("Account", systemImage: "person.crop.circle.fill") }
        }
    }

    private func placeholder(_ title: String, icon: String) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title2.weight(.semibold))
                Text("iOS UI lands in Track B3-B6.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
        }
    }

    private var accountTab: some View {
        NavigationStack {
            List {
                Section("Signed in") {
                    LabeledContent("Email", value: authManager.currentUser?.email ?? "—")
                    LabeledContent("Sync") {
                        switch coordinator.status {
                        case .idle:    Text("Idle")
                        case .syncing: ProgressView()
                        case .success: Text("Synced").foregroundStyle(.green)
                        case .error(let msg): Text(msg).foregroundStyle(.red).font(.caption)
                        case .offline: Text("Offline").foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        try? authManager.signOut()
                        CloudSyncCoordinator.shared.stop()
                    }
                }
            }
            .navigationTitle("Account")
        }
    }
}
#endif
