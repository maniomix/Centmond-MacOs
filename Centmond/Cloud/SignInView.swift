import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showForgot = false

    let onSwitchToSignUp: () -> Void

    var body: some View {
        ZStack {
            AuthBackground()
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 40)
                    AuthBrandHeader(subtitle: "Sign in to continue")

                    OAuthButtons(errorMessage: $errorMessage)
                    OrDivider()

                    VStack(spacing: 12) {
                        AuthField(
                            title: "Email",
                            icon: "envelope.fill",
                            placeholder: "your@email.com",
                            text: $email
                        )
                        AuthPasswordField(
                            title: "Password",
                            placeholder: "Enter your password",
                            text: $password
                        )
                        HStack {
                            Spacer()
                            Button("Forgot password?") { showForgot = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(CentmondTheme.Colors.accent)
                        }
                    }

                    if let errorMessage { AuthErrorBanner(message: errorMessage) }

                    AuthPrimaryButton(
                        title: "Sign In",
                        isLoading: isLoading,
                        isEnabled: !email.isEmpty && !password.isEmpty,
                        action: signIn
                    )

                    Button(action: onSwitchToSignUp) {
                        HStack(spacing: 4) {
                            Text("New to Centmond?")
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            Text("Create an account")
                                .fontWeight(.semibold)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                        }
                        .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                    Spacer(minLength: 24)
                }
                .frame(maxWidth: 400)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }

            if isLoading { AuthLoadingOverlay(label: "Signing in…") }
        }
        .sheet(isPresented: $showForgot) {
            ForgotPasswordSheet(prefilledEmail: email)
        }
    }

    private func signIn() {
        isLoading = true
        errorMessage = nil
        Task {
            defer { Task { @MainActor in isLoading = false } }
            do {
                try await authManager.signIn(
                    email: email.trimmingCharacters(in: .whitespaces).lowercased(),
                    password: password.trimmingCharacters(in: .whitespaces)
                )
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

// MARK: - Forgot password sheet

struct ForgotPasswordSheet: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    let prefilledEmail: String
    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var sent = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(CentmondTheme.Colors.accent.opacity(0.16))
                    .frame(width: 70, height: 70)
                Image(systemName: sent ? "checkmark.circle.fill" : "key.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.accent)
            }
            .padding(.top, 30)

            Text(sent ? "Check your email" : "Reset password")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Text(sent
                 ? "We sent a reset link to \(email)."
                 : "Enter your email and we'll send you a reset link.")
                .font(.system(size: 13))
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if !sent {
                AuthField(title: "Email", icon: "envelope.fill",
                          placeholder: "your@email.com", text: $email)
                    .padding(.horizontal, 24)

                if let errorMessage { AuthErrorBanner(message: errorMessage).padding(.horizontal, 24) }

                AuthPrimaryButton(
                    title: "Send reset link",
                    isLoading: isLoading,
                    isEnabled: !email.isEmpty,
                    action: send
                )
                .padding(.horizontal, 24)
            } else {
                AuthPrimaryButton(
                    title: "Done", isLoading: false, isEnabled: true,
                    action: { dismiss() }
                )
                .padding(.horizontal, 24)
            }

            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .padding(.bottom, 20)
        }
        .frame(width: 380, height: 380)
        .background(CentmondTheme.Colors.bgPrimary)
        .onAppear { if email.isEmpty { email = prefilledEmail } }
    }

    private func send() {
        isLoading = true
        errorMessage = nil
        Task {
            defer { Task { @MainActor in isLoading = false } }
            do {
                try await authManager.resetPassword(
                    email: email.trimmingCharacters(in: .whitespaces).lowercased()
                )
                await MainActor.run { sent = true }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}
