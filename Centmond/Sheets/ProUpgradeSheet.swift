import SwiftUI

struct ProUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Foundation for Pro gating. StoreKit hookup lands later (P7); for now
    /// the upgrade button flips this flag locally so downstream feature
    /// gates can already read `@AppStorage("isProUnlocked")` and behave
    /// correctly. Restoring purchases will overwrite the same key.
    @AppStorage("isProUnlocked") private var isProUnlocked = false

    private let features: [(icon: String, title: String, description: String)] = [
        ("target", "Goals", "Set savings goals and track progress over time"),
        ("chart.line.uptrend.xyaxis", "Forecasting", "Project future balances based on recurring patterns"),
        ("chart.bar.fill", "Net Worth", "Track assets, liabilities, and net worth trends"),
        ("doc.text.fill", "Reports", "Detailed spending reports with category breakdowns"),
        ("person.2.fill", "Household", "Share finances and collaborate with family members"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SheetHeader(title: "Upgrade to Pro") { dismiss() }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(spacing: CentmondTheme.Spacing.xxl) {
                    // Hero
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(CentmondTheme.Colors.warning)

                        Text("Unlock the full experience")
                            .font(CentmondTheme.Typography.heading2)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)

                        Text("Get access to advanced features for smarter money management.")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, CentmondTheme.Spacing.lg)

                    // Feature list
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                        ForEach(features, id: \.title) { feature in
                            HStack(spacing: CentmondTheme.Spacing.md) {
                                Image(systemName: feature.icon)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(CentmondTheme.Colors.accent)
                                    .frame(width: 28, height: 28)
                                    .background(CentmondTheme.Colors.accent.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title)
                                        .font(CentmondTheme.Typography.bodyMedium)
                                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                    Text(feature.description)
                                        .font(CentmondTheme.Typography.caption)
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, CentmondTheme.Spacing.xxl)
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Footer
            VStack(spacing: CentmondTheme.Spacing.sm) {
                if isProUnlocked {
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(CentmondTheme.Colors.positive)
                        Text("Pro is active on this Mac")
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    }
                    Button("Done") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button {
                        // TODO: StoreKit integration. For now, the flag just
                        // flips locally so feature gates wired against
                        // `isProUnlocked` already work end-to-end.
                        isProUnlocked = true
                        dismiss()
                    } label: {
                        Text("Upgrade — $4.99/month")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button("Maybe Later") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 520)
    }
}
