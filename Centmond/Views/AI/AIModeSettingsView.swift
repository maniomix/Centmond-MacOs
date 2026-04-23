import SwiftUI

// ============================================================
// MARK: - AI Mode Settings View
// ============================================================
//
// Mode selection UI. Shows all 4 modes (Advisor, Assistant,
// Autopilot, CFO) as cards with behavior bullets.
//
// ============================================================

struct AIModeSettingsView: View {
    private let modeManager = AIAssistantModeManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerSection

                    ForEach(AssistantMode.allCases) { mode in
                        modeCard(mode)
                    }

                    currentModeSummary

                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .background(DS.Colors.bg)
            .navigationTitle("AI Mode")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .frame(minWidth: 450, minHeight: 500)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "dial.medium.fill")
                .font(CentmondTheme.Typography.display.weight(.regular))
                .foregroundStyle(DS.Colors.accent)

            Text("How should Centmond AI behave?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.Colors.text)

            Text("Choose a mode that matches your comfort level. You can change this anytime.")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(DS.Colors.subtext)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Mode Card

    private func modeCard(_ mode: AssistantMode) -> some View {
        let isSelected = modeManager.currentMode == mode

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                modeManager.currentMode = mode
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: mode.icon)
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? .white : modeAccentColor(mode))
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                                .fill(isSelected ? modeAccentColor(mode) : modeAccentColor(mode).opacity(0.15))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title)
                            .font(CentmondTheme.Typography.subheading)
                            .foregroundStyle(DS.Colors.text)
                        Text(mode.tagline)
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(DS.Colors.subtext)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(modeAccentColor(mode))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(mode.behaviorBullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(isSelected ? modeAccentColor(mode) : DS.Colors.subtext.opacity(0.4))
                                .frame(width: 5, height: 5)
                                .padding(.top, 5)
                            Text(bullet)
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(DS.Colors.subtext)
                        }
                    }
                }

                HStack(spacing: 12) {
                    behaviorPill("Clarification", value: clarificationLabel(mode))
                    behaviorPill("Proactive", value: mode.proactiveIntensity.title)
                    behaviorPill("Optimization", value: mode.optimizationEmphasis.title)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                    .fill(isSelected
                          ? modeAccentColor(mode).opacity(colorScheme == .dark ? 0.12 : 0.06)
                          : DS.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                    .strokeBorder(isSelected ? modeAccentColor(mode) : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func behaviorPill(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(CentmondTheme.Typography.micro.weight(.medium))
                .foregroundStyle(DS.Colors.subtext.opacity(0.6))
            Text(value)
                .font(CentmondTheme.Typography.overlineSemibold)
                .foregroundStyle(DS.Colors.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(DS.Colors.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
    }

    private var currentModeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current: \(modeManager.currentMode.title)")
                .font(CentmondTheme.Typography.bodyLarge.weight(.semibold))
                .foregroundStyle(DS.Colors.text)

            Text(modeManager.currentMode.description)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(DS.Colors.subtext)

            Divider()

            HStack(spacing: 16) {
                summaryItem("Auto-Execute Safe", check: modeManager.currentMode.autoExecuteSafe)
                summaryItem("Auto-Execute Medium", check: modeManager.currentMode.autoExecuteMedium)
                summaryItem("Auto-Execute High", check: modeManager.currentMode.autoExecuteHigh)
            }
        }
        .padding(14)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
    }

    private func summaryItem(_ label: String, check: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: check ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(CentmondTheme.Typography.subheading.weight(.regular))
                .foregroundStyle(check ? DS.Colors.positive : DS.Colors.subtext.opacity(0.4))
            Text(label)
                .font(CentmondTheme.Typography.micro.weight(.medium))
                .foregroundStyle(DS.Colors.subtext)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func modeAccentColor(_ mode: AssistantMode) -> Color {
        switch mode {
        case .advisor:   return .blue
        case .assistant:  return DS.Colors.accent
        case .autopilot:  return .orange
        case .cfo:        return .purple
        }
    }

    private func clarificationLabel(_ mode: AssistantMode) -> String {
        switch mode {
        case .advisor:   return "Frequent"
        case .assistant:  return "Moderate"
        case .autopilot:  return "Rare"
        case .cfo:        return "Minimal"
        }
    }
}

// MARK: - Compact Mode Indicator (for chat toolbar)

struct AIModeIndicator: View {
    private let modeManager = AIAssistantModeManager.shared
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: modeManager.currentMode.icon)
                    .font(CentmondTheme.Typography.overlineRegular)
                Text(modeManager.currentMode.title)
                    .font(CentmondTheme.Typography.overlineSemibold)
            }
            .foregroundStyle(modeColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(modeColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var modeColor: Color {
        switch modeManager.currentMode {
        case .advisor:   return .blue
        case .assistant:  return DS.Colors.accent
        case .autopilot:  return .orange
        case .cfo:        return .purple
        }
    }
}
