import Foundation
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Supabase

// ============================================================
// MARK: - AuthManager (macOS)
// ============================================================
// Mirrors iOS's AuthManager with the platform diffs:
//   • UIApplication.shared.open  →  NSWorkspace.shared.open
//   • Same OAuth deep-link `centmond://auth-callback`
//
// Hooks for SwiftData stores: when `isAuthenticated` flips true,
// each repository on macOS triggers its initial pull. When it
// flips false, repositories stop their realtime channels and
// clear in-memory caches.
// ============================================================

@MainActor
final class AuthManager: ObservableObject {

    static let shared = AuthManager()

    private var supabase: SupabaseClient { CloudClient.shared.client }

    // MARK: - Published state

    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isCheckingSession = true
    @Published var pendingConfirmationEmail: String?

    // MARK: - Init / restore

    init() {
        Task {
            do {
                let session = try await supabase.auth.session
                await MainActor.run {
                    self.currentUser = session.user
                    self.isAuthenticated = true
                    self.isCheckingSession = false
                    SecureLogger.info("Session restored")
                }
            } catch {
                await MainActor.run {
                    self.isAuthenticated = false
                    self.isCheckingSession = false
                    SecureLogger.debug("No existing session")
                }
            }

            for await state in await supabase.auth.authStateChanges {
                await MainActor.run {
                    let valid = state.session.flatMap { $0.isExpired ? nil : $0 }
                    self.currentUser = valid?.user
                    self.isAuthenticated = valid != nil
                    SecureLogger.debug("Auth state: \(self.isAuthenticated)")
                }
            }
        }
    }

    // MARK: - Email + password

    func signUp(email: String, password: String, displayName: String? = nil) async throws {
        SecureLogger.info("Sign up starting")
        let metadata: [String: AnyJSON] = displayName.map { ["display_name": .string($0)] } ?? [:]
        _ = try await supabase.auth.signUp(email: email, password: password, data: metadata)

        // If Supabase requires email confirmation, no session yet — route
        // the UI to the EmailConfirmationView via pendingConfirmationEmail.
        do {
            let session = try await supabase.auth.session
            await MainActor.run {
                self.currentUser = session.user
                self.isAuthenticated = true
                self.pendingConfirmationEmail = nil
            }
        } catch {
            await MainActor.run {
                self.pendingConfirmationEmail = email
                SecureLogger.info("Sign-up pending email confirmation")
            }
        }
    }

    func signIn(email: String, password: String) async throws {
        try await supabase.auth.signIn(email: email, password: password)
        SecureLogger.info("Signed in")
    }

    func signOut() throws {
        Task {
            try await supabase.auth.signOut()
            await MainActor.run {
                self.isAuthenticated = false
                self.currentUser = nil
                self.pendingConfirmationEmail = nil
            }
            SecureLogger.info("Signed out")
        }
    }

    func resetPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email)
        SecureLogger.info("Password reset email sent")
    }

    func resendConfirmationEmail() async throws {
        guard let email = pendingConfirmationEmail else { return }
        try await supabase.auth.resend(email: email, type: .signup)
        SecureLogger.info("Resent confirmation email")
    }

    func cancelPendingConfirmation() {
        pendingConfirmationEmail = nil
    }

    // MARK: - OAuth (Google / Apple)
    //
    // Web flow via Supabase. The OS opens the system browser; after the
    // user authorizes, the redirect `centmond://auth-callback?...` is
    // handed back to `handleOpenURL(_:)` (registered in CentmondApp).

    func signInWithGoogle() async throws {
        let url = try supabase.auth.getOAuthSignInURL(
            provider: .google,
            redirectTo: URL(string: "centmond://auth-callback")
        )
        await MainActor.run {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
        SecureLogger.info("Started Google OAuth flow")
    }

    func signInWithApple() async throws {
        // Apple is intentionally disabled in Supabase until an Apple
        // Developer account is wired up; this surfaces as a friendly
        // error in the UI rather than a crash.
        let url = try supabase.auth.getOAuthSignInURL(
            provider: .apple,
            redirectTo: URL(string: "centmond://auth-callback")
        )
        await MainActor.run {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
        SecureLogger.info("Started Apple OAuth flow")
    }

    /// Called by CentmondApp.onOpenURL when the OAuth provider redirects
    /// back to `centmond://auth-callback?...`. Completes the session.
    func handleOpenURL(_ url: URL) {
        Task {
            do {
                try await supabase.auth.session(from: url)
                SecureLogger.info("OAuth session completed")
            } catch {
                SecureLogger.error("OAuth session completion failed", error)
            }
        }
    }

    // MARK: - Stale-session detection

    /// Probes `profiles` to confirm the cached JWT still maps to a real
    /// user. If the row is gone (account deleted on another device), we
    /// force-signout. Transient network errors are ignored — only the
    /// definitive "no profile row" signal triggers signout.
    func validateSessionStillValid() async {
        guard isAuthenticated else { return }
        struct Probe: Codable { let id: String }
        do {
            let rows: [Probe] = try await supabase
                .from("profiles")
                .select("id")
                .limit(1)
                .execute()
                .value
            if rows.isEmpty {
                SecureLogger.warning("Profile missing — user was deleted; signing out")
                await forceSignOutAfterStaleSession()
            }
        } catch {
            SecureLogger.debug("Session probe non-fatal error: \(error.localizedDescription)")
        }
    }

    func forceSignOutAfterStaleSession() async {
        do { try await supabase.auth.signOut() } catch { /* SDK may have no session */ }
        await MainActor.run {
            self.isAuthenticated = false
            self.currentUser = nil
            self.pendingConfirmationEmail = nil
        }
    }
}
