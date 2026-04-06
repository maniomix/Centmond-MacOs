import SwiftUI

struct InAppSettingsView: View {
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"
    @AppStorage("startOfWeek") private var startOfWeek = 1
    @AppStorage("autoOpenInspector") private var autoOpenInspector = true
    @AppStorage("tableDensity") private var tableDensity = "default"
    @AppStorage("sidebarIconOnly") private var sidebarIconOnly = false

    var body: some View {
        ScrollView {
            VStack(spacing: CentmondTheme.Spacing.xxl) {
                // Header
                VStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)

                    Text("Settings")
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Text("Customize your Centmond experience")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }
                .padding(.top, CentmondTheme.Spacing.xxxl)
                .padding(.bottom, CentmondTheme.Spacing.lg)

                // Cards grid
                VStack(spacing: CentmondTheme.Spacing.lg) {
                    // General
                    settingsCard(title: "General", icon: "slider.horizontal.3", iconColor: CentmondTheme.Colors.accent) {
                        settingsRow {
                            Label("Default Currency", systemImage: "dollarsign.circle")
                            Spacer()
                            Picker("", selection: $defaultCurrency) {
                                Text("USD ($)").tag("USD")
                                Text("EUR (€)").tag("EUR")
                                Text("GBP (£)").tag("GBP")
                                Text("JPY (¥)").tag("JPY")
                                Text("CAD (C$)").tag("CAD")
                                Text("AUD (A$)").tag("AUD")
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }

                        Divider().background(CentmondTheme.Colors.strokeSubtle)

                        settingsRow {
                            Label("Start of Week", systemImage: "calendar")
                            Spacer()
                            Picker("", selection: $startOfWeek) {
                                Text("Sunday").tag(1)
                                Text("Monday").tag(2)
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }

                        Divider().background(CentmondTheme.Colors.strokeSubtle)

                        settingsRow {
                            Label("Auto-open inspector", systemImage: "sidebar.right")
                            Spacer()
                            Toggle("", isOn: $autoOpenInspector)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }

                    // Appearance
                    settingsCard(title: "Appearance", icon: "paintbrush.fill", iconColor: Color(hex: "8B5CF6")) {
                        settingsRow {
                            Label("Table Density", systemImage: "line.3.horizontal")
                            Spacer()
                            Picker("", selection: $tableDensity) {
                                Text("Default").tag("default")
                                Text("Compact").tag("compact")
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }

                        Divider().background(CentmondTheme.Colors.strokeSubtle)

                        settingsRow {
                            Label("Compact sidebar", systemImage: "sidebar.left")
                            Spacer()
                            Toggle("", isOn: $sidebarIconOnly)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }

                        Divider().background(CentmondTheme.Colors.strokeSubtle)

                        settingsRow {
                            Label("Color Scheme", systemImage: "moon.fill")
                            Spacer()
                            Text("Dark")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }

                    // Feedback
                    settingsCard(title: "Feedback", icon: "hand.tap.fill", iconColor: Color(hex: "F59E0B")) {
                        settingsRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Haptic Feedback", systemImage: "waveform.path")
                                Text("Trackpad feedback on hover, selection, and actions")
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            }
                            Spacer()
                            Toggle("", isOn: $hapticsEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }

                    // App info
                    settingsCard(title: "About", icon: "info.circle.fill", iconColor: CentmondTheme.Colors.textTertiary) {
                        settingsRow {
                            Label("Version", systemImage: "number")
                            Spacer()
                            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                                Text("\(version) (\(build))")
                                    .font(CentmondTheme.Typography.body)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            }
                        }

                        Divider().background(CentmondTheme.Colors.strokeSubtle)

                        settingsRow {
                            Label("Database", systemImage: "internaldrive")
                            Spacer()
                            Text("SwiftData (local)")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }
                }
                .frame(maxWidth: 560)

                Spacer(minLength: CentmondTheme.Spacing.xxxl)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Components

    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))

                Text(title.uppercased())
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.vertical, CentmondTheme.Spacing.md)

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Card content
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
        }
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            content()
        }
        .font(CentmondTheme.Typography.body)
        .foregroundStyle(CentmondTheme.Colors.textPrimary)
        .frame(height: 44)
    }
}
