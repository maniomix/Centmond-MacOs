import SwiftUI
import SwiftData
import AppKit

// Phase 11 — the macOS prefs TabView and every per-tab subview have been
// retired. `InAppSettingsView` is the single source of truth, and ⌘, now
// navigates the main window to it via `CommandGroup(replacing: .appSettings)`
// in `CentmondApp`.
//
// The only survivor in this file is `EraseAllDataSheet`, which the in-app
// Danger Zone row still presents. Kept here (instead of moved to its own
// file) to avoid breaking the Xcode filesystem-synchronized group layout
// mid-refactor — the history is easier to follow with the sheet at its
// historical path.

// MARK: - Erase All Data Confirmation Sheet

struct EraseAllDataSheet: View {
    let requiredPhrase: String
    @Binding var typedPhrase: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var isPhraseValid: Bool {
        typedPhrase.trimmingCharacters(in: .whitespacesAndNewlines) == requiredPhrase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
            HStack(spacing: CentmondTheme.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.negative)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Erase All Data")
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("This action is permanent and cannot be undone.")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                }
            }

            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                Text("The following will be permanently deleted:")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                bulletList([
                    "Every account, balance, and balance history point",
                    "All transactions, splits, transfers, and tags",
                    "All budget categories and monthly budget overrides",
                    "Goals, contributions, and allocation rules",
                    "Subscriptions and recurring templates",
                    "Household members, shares, and settlement history",
                    "Net-worth snapshots and milestones",
                    "AI chat history, insights, merchant memory, and learned preferences",
                    "Review-queue entries and dismissed insights",
                    "Smart folders, saved filters, and scheduled reports"
                ])
            }

            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                Text("In addition, these settings will be reset:")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                bulletList([
                    "Onboarding will run again on next launch",
                    "App lock will be disabled and the passcode cleared"
                ])
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("There is no backup. This operation cannot be reversed.")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.negative)
                Text("If you want to keep a copy of your data, cancel now and use Reports \u{2192} Copy as CSV first.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("To confirm, type  \(requiredPhrase)  below:")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                TextField(requiredPhrase, text: $typedPhrase)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            HStack(spacing: CentmondTheme.Spacing.sm) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Erase Everything", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isPhraseValid)
            }
        }
        .padding(CentmondTheme.Spacing.xxl)
        .frame(width: 520)
    }

    @ViewBuilder
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{2022}")
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Text(item)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
