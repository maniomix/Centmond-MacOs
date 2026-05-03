import SwiftUI

// ============================================================
// MARK: - Auth shared UI pieces (macOS)
// ============================================================
// Brand background, header, OAuth buttons, password field,
// error banner, loading overlay. Used by SignInView,
// SignUpView, and EmailConfirmationView.
// ============================================================

// MARK: - Background

struct AuthBackground: View {
    var body: some View {
        ZStack {
            CentmondTheme.Colors.bgPrimary.ignoresSafeArea()
            GeometryReader { geo in
                ZStack {
                    Circle()
                        .fill(CentmondTheme.Colors.accent.opacity(0.18))
                        .frame(width: geo.size.width * 0.5)
                        .blur(radius: 90)
                        .offset(x: -geo.size.width * 0.15, y: -geo.size.height * 0.25)
                    Circle()
                        .fill(CentmondTheme.Colors.accent.opacity(0.10))
                        .frame(width: geo.size.width * 0.6)
                        .blur(radius: 110)
                        .offset(x: geo.size.width * 0.20, y: geo.size.height * 0.30)
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Brand header

struct AuthBrandHeader: View {
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(CentmondTheme.Colors.accent.opacity(0.18))
                    .frame(width: 76, height: 76)
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.accent)
            }
            VStack(spacing: 4) {
                Text("CENTMOND")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
        }
    }
}

// MARK: - OAuth buttons

struct OAuthButtons: View {
    @EnvironmentObject private var authManager: AuthManager
    @Binding var errorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            providerButton(
                title: "Continue with Google",
                icon: "globe",
                background: CentmondTheme.Colors.bgSecondary,
                foreground: CentmondTheme.Colors.textPrimary,
                stroke: CentmondTheme.Colors.strokeDefault.opacity(0.6)
            ) {
                Task {
                    do { try await authManager.signInWithGoogle() }
                    catch { errorMessage = error.localizedDescription }
                }
            }

            providerButton(
                title: "Continue with Apple",
                icon: "applelogo",
                background: CentmondTheme.Colors.textPrimary,
                foreground: CentmondTheme.Colors.bgPrimary,
                stroke: .clear
            ) {
                Task {
                    do { try await authManager.signInWithApple() }
                    catch {
                        errorMessage = "Apple sign-in isn't available yet. Use email or Google for now."
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func providerButton(
        title: String, icon: String,
        background: Color, foreground: Color, stroke: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(background)
            .foregroundStyle(foreground)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Or divider

struct OrDivider: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(CentmondTheme.Colors.strokeDefault)
                .frame(height: 1)
            Text("OR")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Rectangle()
                .fill(CentmondTheme.Colors.strokeDefault)
                .frame(height: 1)
        }
    }
}

// MARK: - Auth field

struct AuthField: View {
    let title: String
    let icon: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 16)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
            }
            .padding(12)
            .background(CentmondTheme.Colors.bgInput, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CentmondTheme.Colors.strokeSubtle, lineWidth: 0.6)
            )
        }
    }
}

// MARK: - Password field

struct AuthPasswordField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    @State private var show = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 16)
                Group {
                    if show { TextField(placeholder, text: $text) }
                    else    { SecureField(placeholder, text: $text) }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 14))

                Button { show.toggle() } label: {
                    Image(systemName: show ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(CentmondTheme.Colors.bgInput, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CentmondTheme.Colors.strokeSubtle, lineWidth: 0.6)
            )
        }
    }
}

// MARK: - Error banner

struct AuthErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CentmondTheme.Colors.negative)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(CentmondTheme.Colors.negative)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            CentmondTheme.Colors.negativeMuted,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Primary button

struct AuthPrimaryButton: View {
    let title: String
    let isLoading: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading { ProgressView().controlSize(.small).tint(.white) }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(CentmondTheme.Colors.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
    }
}

// MARK: - Loading overlay

struct AuthLoadingOverlay: View {
    let label: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
