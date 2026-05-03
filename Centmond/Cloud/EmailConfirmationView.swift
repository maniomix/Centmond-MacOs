import SwiftUI

struct EmailConfirmationView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var isResending = false
    @State private var note: String?

    var body: some View {
        ZStack {
            AuthBackground()
            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(CentmondTheme.Colors.accent.opacity(0.16))
                        .frame(width: 100, height: 100)
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                }

                VStack(spacing: 8) {
                    Text("Check your email")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("We sent a confirmation link to")
                        .font(.system(size: 13))
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    Text(authManager.pendingConfirmationEmail ?? "your email")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("Open the link in your inbox to activate your account, then come back and sign in.")
                        .font(.system(size: 12))
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 6)
                }

                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }

                VStack(spacing: 10) {
                    AuthPrimaryButton(
                        title: isResending ? "Sending…" : "Resend email",
                        isLoading: isResending,
                        isEnabled: true,
                        action: resend
                    )
                    Button("Back to sign in") {
                        authManager.cancelPendingConfirmation()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }
                .frame(maxWidth: 320)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func resend() {
        isResending = true
        note = nil
        Task {
            defer { Task { @MainActor in isResending = false } }
            do {
                try await authManager.resendConfirmationEmail()
                await MainActor.run { note = "Email sent. Check your inbox (and spam)." }
            } catch {
                await MainActor.run { note = "Could not resend right now. Try again in a minute." }
            }
        }
    }
}
