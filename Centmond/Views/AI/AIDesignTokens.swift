import SwiftUI

// ============================================================
// MARK: - AI Design Tokens
// ============================================================
//
// Minimal design-system bridge so AI views compile with the
// same `DS.Colors.*` / `DS.Typography.*` references used in
// the iOS source. Maps everything to standard SwiftUI tokens.
//
// ============================================================

enum DS {

    enum Colors {
        static let accent   = Color.accentColor
        static let text     = Color.primary
        static let subtext  = Color.secondary
        static let surface  = Color(.controlBackgroundColor)
        static let surface2 = Color(.windowBackgroundColor)
        static let surfaceElevated = Color.white.opacity(0.08)
        static let bg       = Color(.windowBackgroundColor)
        static let danger   = Color.red
        static let warning  = Color.orange
        static let positive = Color.green
    }

    enum Typography {
        static let title    = Font.title2.weight(.bold)
        static let section  = Font.headline
        static let body     = Font.body
        static let callout  = Font.callout.weight(.medium)
        static let caption  = Font.caption
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
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.controlBackgroundColor))
            )
        }
    }

    // MARK: - Primary Button Style

    struct PrimaryButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(.white)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Colors.accent)
                        .opacity(configuration.isPressed ? 0.8 : 1.0)
                )
        }
    }
}
