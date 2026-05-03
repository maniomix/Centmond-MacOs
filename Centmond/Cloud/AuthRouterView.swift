import SwiftUI

// ============================================================
// MARK: - Auth Router (macOS)
// ============================================================
// Top-level auth gate. Shows one of:
//   • SignInView
//   • SignUpView
//   • EmailConfirmationView (when AuthManager.pendingConfirmationEmail is set)
//
// RootView wraps the rest of the app behind this — i.e. the main
// app shell only renders once `authManager.isAuthenticated == true`.
// ============================================================

struct AuthRouterView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var mode: Mode = .signIn

    enum Mode { case signIn, signUp }

    var body: some View {
        Group {
            if authManager.pendingConfirmationEmail != nil {
                EmailConfirmationView()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if mode == .signUp {
                SignUpView(onSwitchToSignIn: { switchTo(.signIn) })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            } else {
                SignInView(onSwitchToSignUp: { switchTo(.signUp) })
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85),
                   value: authManager.pendingConfirmationEmail)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: mode)
    }

    private func switchTo(_ next: Mode) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { mode = next }
    }
}
