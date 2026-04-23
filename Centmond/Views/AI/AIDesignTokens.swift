import SwiftUI

// ============================================================
// MARK: - AI Design Tokens (thin alias over CentmondTheme)
// ============================================================
//
// Historically `DS` shipped as a parallel mini design system
// that mapped to generic `Color.accentColor` / `Color.primary`,
// causing AI views to drift visually from the rest of the app.
//
// Phase 1 visual polish: `DS` now forwards every member to
// `CentmondTheme` so the 23 consumer sites automatically pick
// up the canonical palette, typography, radius, and elevation
// without per-site edits. Treat `DS` as deprecated — prefer
// `CentmondTheme.*` directly in new code.
//
// ============================================================

enum DS {

    enum Colors {
        static let accent            = CentmondTheme.Colors.accent
        static let text              = CentmondTheme.Colors.textPrimary
        static let subtext           = CentmondTheme.Colors.textSecondary
        static let surface           = CentmondTheme.Colors.bgSecondary
        static let surface2          = CentmondTheme.Colors.bgTertiary
        static let surfaceElevated   = CentmondTheme.Colors.bgQuaternary
        static let bg                = CentmondTheme.Colors.bgPrimary
        static let danger            = CentmondTheme.Colors.negative
        static let warning           = CentmondTheme.Colors.warning
        static let positive          = CentmondTheme.Colors.positive
    }

    enum Typography {
        static let title    = CentmondTheme.Typography.heading1
        static let section  = CentmondTheme.Typography.heading2
        static let body     = CentmondTheme.Typography.body
        static let callout  = CentmondTheme.Typography.bodyMedium
        static let caption  = CentmondTheme.Typography.caption
    }

    // MARK: - Card Container

    struct Card<Content: View>: View {
        let content: Content

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(CentmondTheme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .fill(CentmondTheme.Colors.bgSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
        }
    }

    // MARK: - Primary Button Style

    struct PrimaryButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .padding(.vertical, CentmondTheme.Spacing.md)
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                        .fill(CentmondTheme.Colors.accent)
                        .opacity(configuration.isPressed ? 0.8 : 1.0)
                )
        }
    }
}
