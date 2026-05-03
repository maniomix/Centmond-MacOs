import Foundation
import Combine
import Supabase

// ============================================================
// MARK: - Supabase Client (macOS)
// ============================================================
// Single shared client. Mirrors iOS's SupabaseManager but slim:
// no per-table CRUD lives here — Repositories own that. This
// type just configures auth + exposes the client.
// ============================================================

@MainActor
final class CloudClient: ObservableObject {

    static let shared = CloudClient()

    /// Implicitly-unwrapped because `setupClient()` runs at init time
    /// and either succeeds or crashes loudly via `preconditionFailure`.
    /// A nil `client` would just defer the crash to the first auth call
    /// site, which is harder to diagnose.
    var client: SupabaseClient!

    @Published var isSyncing: Bool = false

    private init() {
        setupClient()
    }

    private func setupClient() {
        let config = AppConfig.shared
        config.validate()

        guard !config.supabaseURL.isEmpty,
              !config.supabaseAnonKey.isEmpty,
              let url = URL(string: config.supabaseURL) else {
            SecureLogger.error("Missing Supabase configuration. Check Centmond.plist.")
            preconditionFailure("Supabase configuration missing or invalid — cannot start app.")
        }

        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: config.supabaseAnonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
        SecureLogger.info("Supabase client initialized [\(config.environment.rawValue)]")
    }
}
