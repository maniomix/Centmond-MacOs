import SwiftUI
import SwiftData

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
                .tag(SettingsTab.appearance)

            SecuritySettingsView()
                .tabItem {
                    Label("Security", systemImage: "lock.shield")
                }
                .tag(SettingsTab.security)

            DataSettingsView()
                .tabItem {
                    Label("Data", systemImage: "internaldrive")
                }
                .tag(SettingsTab.data)

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(SettingsTab.about)
        }
        .frame(width: 520, height: 420)
    }
}

enum SettingsTab: String {
    case general, appearance, security, data, about
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"
    @AppStorage("startOfWeek") private var startOfWeek = 1
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Default Currency", selection: $defaultCurrency) {
                    Text("USD ($)").tag("USD")
                    Text("EUR (\u{20AC})").tag("EUR")
                    Text("GBP (\u{00A3})").tag("GBP")
                    Text("JPY (\u{00A5})").tag("JPY")
                    Text("CAD (C$)").tag("CAD")
                    Text("AUD (A$)").tag("AUD")
                }

                Picker("Start of Week", selection: $startOfWeek) {
                    Text("Sunday").tag(1)
                    Text("Monday").tag(2)
                }
            }

            Section("Behavior") {
                Toggle("Show review queue badge in sidebar", isOn: .constant(true))
                    .disabled(true)

                Toggle("Auto-open inspector on selection", isOn: AppStorage(wrappedValue: true, "autoOpenInspector").projectedValue)
            }

            Section("Feedback") {
                Toggle("Haptic feedback", isOn: $hapticsEnabled)

                Text("Provides subtle trackpad feedback on hover, selection, and actions. Requires a Force Touch trackpad.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @AppStorage("tableDensity") private var tableDensity = "default"
    @AppStorage("sidebarIconOnly") private var sidebarIconOnly = false

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Table Density", selection: $tableDensity) {
                    Text("Default").tag("default")
                    Text("Compact").tag("compact")
                }

                Toggle("Compact sidebar (icons only)", isOn: $sidebarIconOnly)
            }

            Section("Theme") {
                HStack {
                    Text("Color Scheme")
                    Spacer()
                    Text("Dark")
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }

                Text("Centmond currently uses a dark theme. Light mode support is planned for a future release.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}

// MARK: - Security

struct SecuritySettingsView: View {
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appPasscode") private var storedPasscode = ""
    @AppStorage("lockOnSleep") private var lockOnSleep = true
    @AppStorage("lockTimeoutMinutes") private var lockTimeoutMinutes = 5

    @State private var isSettingPasscode = false
    @State private var newPasscode = ""
    @State private var confirmPasscode = ""
    @State private var passcodeError = ""

    var body: some View {
        Form {
            Section("App Lock") {
                Toggle("Require passcode to open Centmond", isOn: $appLockEnabled)
                    .onChange(of: appLockEnabled) { _, enabled in
                        if enabled && storedPasscode.isEmpty {
                            isSettingPasscode = true
                            appLockEnabled = false // revert until passcode is set
                        }
                        if !enabled {
                            storedPasscode = ""
                        }
                    }

                if appLockEnabled {
                    Toggle("Lock when Mac sleeps", isOn: $lockOnSleep)

                    Picker("Auto-lock after inactivity", selection: $lockTimeoutMinutes) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("Never").tag(0)
                    }

                    Button("Change Passcode...") {
                        isSettingPasscode = true
                        newPasscode = ""
                        confirmPasscode = ""
                        passcodeError = ""
                    }
                }
            }

            Section {
                Text("Your passcode is stored locally on this Mac. Centmond does not transmit any authentication data.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Security")
        .sheet(isPresented: $isSettingPasscode) {
            setPasscodeSheet
        }
    }

    private var setPasscodeSheet: some View {
        VStack(spacing: CentmondTheme.Spacing.xxl) {
            Text(storedPasscode.isEmpty ? "Set Passcode" : "Change Passcode")
                .font(CentmondTheme.Typography.heading2)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                SecureField("New 4-digit passcode", text: $newPasscode)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: newPasscode) { _, val in
                        newPasscode = String(val.filter(\.isNumber).prefix(4))
                    }

                SecureField("Confirm passcode", text: $confirmPasscode)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: confirmPasscode) { _, val in
                        confirmPasscode = String(val.filter(\.isNumber).prefix(4))
                    }

                if !passcodeError.isEmpty {
                    Text(passcodeError)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                }
            }
            .frame(width: 260)

            HStack(spacing: CentmondTheme.Spacing.md) {
                Button("Cancel") {
                    isSettingPasscode = false
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Save") {
                    savePasscode()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(newPasscode.count != 4)
            }
        }
        .padding(CentmondTheme.Spacing.xxxl)
        .frame(width: 380, height: 280)
        .background(CentmondTheme.Colors.bgSecondary)
        .preferredColorScheme(.dark)
    }

    private func savePasscode() {
        guard newPasscode.count == 4, newPasscode.allSatisfy(\.isNumber) else {
            passcodeError = "Passcode must be exactly 4 digits"
            return
        }
        guard newPasscode == confirmPasscode else {
            passcodeError = "Passcodes do not match"
            return
        }
        storedPasscode = newPasscode
        appLockEnabled = true
        isSettingPasscode = false
    }
}

// MARK: - Data

struct DataSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showResetConfirmation = false
    @State private var showExportInfo = false

    var body: some View {
        Form {
            Section("Storage") {
                HStack {
                    Text("Database")
                    Spacer()
                    Text("SwiftData (local)")
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }

                HStack {
                    Text("Location")
                    Spacer()
                    Text("~/Library/Application Support")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }

            Section("Export") {
                Button("Export Transactions as CSV...") {
                    showExportInfo = true
                }

                Text("Use Reports > Copy as CSV to export filtered transaction data.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }

            Section("Reset") {
                Button("Reset Onboarding") {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                }

                Button("Delete All Data...", role: .destructive) {
                    showResetConfirmation = true
                }
                .foregroundStyle(CentmondTheme.Colors.negative)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Data")
        .alert("Delete All Data?", isPresented: $showResetConfirmation) {
            Button("Delete Everything", role: .destructive) {
                // Clear all preferences
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                UserDefaults.standard.set(false, forKey: "appLockEnabled")
                UserDefaults.standard.set("", forKey: "appPasscode")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset all preferences. Database data must be deleted by removing the app's Application Support folder. This cannot be undone.")
        }
        .alert("Export", isPresented: $showExportInfo) {
            Button("OK") {}
        } message: {
            Text("Navigate to the Reports screen and use the \"Copy as CSV\" button to export your data for a specific date range.")
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(CentmondTheme.Colors.accent)

            Text("Centmond")
                .font(CentmondTheme.Typography.heading1)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            Text("Your personal finance command center")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                Text("Version \(version) (\(build))")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Divider()
                .frame(width: 200)
                .padding(.vertical, CentmondTheme.Spacing.sm)

            VStack(spacing: CentmondTheme.Spacing.xs) {
                keyboardShortcutRow(keys: "\u{2318}K", action: "Command Palette")
                keyboardShortcutRow(keys: "\u{2318}N", action: "New Transaction")
                keyboardShortcutRow(keys: "\u{2318}I", action: "Toggle Inspector")
                keyboardShortcutRow(keys: "\u{2318}1-9", action: "Navigate Screens")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func keyboardShortcutRow(keys: String, action: String) -> some View {
        HStack {
            Text(keys)
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 80, alignment: .trailing)
            Text(action)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .frame(width: 160, alignment: .leading)
        }
    }
}
