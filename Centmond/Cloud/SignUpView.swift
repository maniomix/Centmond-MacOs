import SwiftUI

struct SignUpView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    let onSwitchToSignIn: () -> Void

    private var formValid: Bool {
        !email.isEmpty && password.count >= 6 && password == confirm
    }

    var body: some View {
        ZStack {
            AuthBackground()
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 40)
                    AuthBrandHeader(subtitle: "Create your account")

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
                            placeholder: "At least 6 characters",
                            text: $password
                        )
                        AuthPasswordField(
                            title: "Confirm Password",
                            placeholder: "Re-enter password",
                            text: $confirm
                        )
                    }

                    if !password.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            requirement(met: password.count >= 6, text: "At least 6 characters")
                            requirement(met: !confirm.isEmpty && password == confirm, text: "Passwords match")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let errorMessage { AuthErrorBanner(message: errorMessage) }

                    AuthPrimaryButton(
                        title: "Create Account",
                        isLoading: isLoading,
                        isEnabled: formValid,
                        action: signUp
                    )

                    Button(action: onSwitchToSignIn) {
                        HStack(spacing: 4) {
                            Text("Already have an account?")
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            Text("Sign In")
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

            if isLoading { AuthLoadingOverlay(label: "Creating account…") }
        }
    }

    @ViewBuilder
    private func requirement(met: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(met ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textTertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
        }
    }

    private func signUp() {
        guard password == confirm else { errorMessage = "Passwords don't match"; return }
        isLoading = true
        errorMessage = nil
        Task {
            defer { Task { @MainActor in isLoading = false } }
            do {
                try await authManager.signUp(
                    email: email.trimmingCharacters(in: .whitespaces).lowercased(),
                    password: password.trimmingCharacters(in: .whitespaces)
                )
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}
