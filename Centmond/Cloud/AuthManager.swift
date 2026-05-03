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
        // Auth restore on launch is tricky. supabase-swift docs:
        //   "emitLocalSessionAsInitialSession: When `true`, emits the
        //    locally stored session immediately as the initial session.
        //    Note: If you rely on the initial session to opt users in,
        //    you need to add an additional check for `session.isExpired`
        //    when this is set to `true`."
        //
        // So the .initialSession event arrives ALWAYS, even when the
        // stored token is expired. If we treat expired-token as "no
        // auth" and flip isCheckingSession=false on that event,
        // RootView renders AuthRouterView for ~1 s — exactly the time
        // it takes the auto-refresh to mint a new token and emit
        // .tokenRefreshed. That's the launch flash.
        //
        // Fix: discriminate on event type. Hold isCheckingSession=true
        // through .initialSession-with-expired-or-nil-session, waiting
        // for the auto-refresh's .tokenRefreshed (success) or the 5 s
        // safety timeout (genuinely no session) before letting RootView
        // commit to AuthRouterView.
        Task {
            for await state in await supabase.auth.authStateChanges {
                await MainActor.run {
                    let valid = state.session.flatMap { $0.isExpired ? nil : $0 }
                    self.currentUser = valid?.user
                    self.isAuthenticated = valid != nil

                    switch state.event {
                    case .signedIn, .tokenRefreshed, .userUpdated, .mfaChallengeVerified:
                        // Definitive positive auth event.
                        self.isCheckingSession = false
                    case .signedOut, .userDeleted:
                        // Definitive negative auth event.
                        self.isCheckingSession = false
                    case .initialSession:
                        // Only resolve if the local session was actually
                        // valid. If it was nil OR expired, the auto-refresh
                        // is in flight — wait for .tokenRefreshed.
                        if valid != nil {
                            self.isCheckingSession = false
                        }
                    case .passwordRecovery:
                        // No auth-state change; user is mid-recovery.
                        break
                    @unknown default:
                        break
                    }
                    SecureLogger.debug("Auth event: \(state.event.rawValue) authenticated=\(self.isAuthenticated) checking=\(self.isCheckingSession)")
                }
            }
        }

        // Safety net: if .tokenRefreshed never arrives (genuinely no
        // session, refresh failed, network wedged), don't pin the user on
        // a blank splash forever. After 5 s, accept the current state as
        // final and let RootView commit.
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if self.isCheckingSession {
                    self.isCheckingSession = false
                    SecureLogger.warning("Auth restore timed out after 5s; committing to current auth state (\(self.isAuthenticated))")
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
