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

            RecurringSettingsView()
                .tabItem {
                    Label("Recurring", systemImage: "repeat.circle")
                }
                .tag(SettingsTab.recurring)

            NetWorthSettingsView()
                .tabItem {
                    Label("Net Worth", systemImage: "chart.line.uptrend.xyaxis")
                }
                .tag(SettingsTab.netWorth)

            // Review Queue is temporarily hidden. Uncomment to restore;
            // ReviewQueueSettingsView itself is still compiled below.
            // ReviewQueueSettingsView()
            //     .tabItem {
            //         Label("Review Queue", systemImage: "tray.fill")
            //     }
            //     .tag(SettingsTab.reviewQueue)

            ReportsSettingsView()
                .tabItem {
                    Label("Reports", systemImage: "doc.richtext")
                }
                .tag(SettingsTab.reports)

            HouseholdSettingsView()
                .tabItem {
                    Label("Household", systemImage: "person.2")
                }
                .tag(SettingsTab.household)

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
    case general, appearance, security, data, recurring, netWorth, reviewQueue, reports, household, about
}

// MARK: - Review Queue Settings (P8)

struct ReviewQueueSettingsView: View {
    @Bindable private var telemetry = ReviewQueueTelemetry.shared

    var body: some View {
        Form {
            Section("Detectors") {
                ForEach(ReviewReasonCode.allCases, id: \.self) { reason in
                    Toggle(isOn: Binding(
                        get: { !telemetry.isMuted(reason) },
                        set: { telemetry.setMuted(reason, muted: !$0) }
                    )) {
                        Label(reason.title, systemImage: reason.icon)
                    }
                }
            }
            Section {
                HStack {
                    Text("Resolved this week")
                    Spacer()
                    Text("\(telemetry.resolvedThisWeek)")
                        .monospacedDigit()
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }
            } footer: {
                Text("Disabled detectors stop surfacing their reason in the Review Queue. Re-enable any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
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
                BackupService.wipeAllData(in: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete every account, transaction, budget, goal, subscription, and other entry from Centmond, and reset onboarding and app lock. This cannot be undone.")
        }
        .alert("Export", isPresented: $showExportInfo) {
            Button("OK") {}
        } message: {
            Text("Navigate to the Reports screen and use the \"Copy as CSV\" button to export your data for a specific date range.")
        }
    }
}

// MARK: - About

// MARK: - Household Settings (P9)

struct HouseholdSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HouseholdMember.joinedAt) private var allMembers: [HouseholdMember]
    @Bindable private var telemetry = HouseholdTelemetry.shared

    /// UUID of the default payer for new manual transactions. Persisted as a
    /// String so AppStorage can handle it; converted to UUID at read time.
    @AppStorage("householdDefaultPayerID") private var defaultPayerIDString: String = ""
    @AppStorage("householdAutoSplitNewExpenses") private var autoSplitNewExpenses: Bool = false
    @AppStorage("householdUnsettledReminderDays") private var unsettledReminderDays: Int = 30
    @AppStorage("householdNotificationsEnabled") private var notificationsEnabled: Bool = true

    private var members: [HouseholdMember] { allMembers.filter(\.isActive) }

    var body: some View {
        Form {
            if members.isEmpty {
                Section {
                    Text("Add household members from the Household hub to unlock per-person attribution, splits, and settle-ups.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            } else {
                Section("Defaults") {
                    Picker("Default payer", selection: $defaultPayerIDString) {
                        Text("Ask each time").tag("")
                        ForEach(members) { m in
                            Text(m.name).tag(m.id.uuidString)
                        }
                    }
                    Text("New manual transactions and AI-added expenses are attributed to this member unless you pick a different one at entry.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                    Toggle("Auto-split new expenses across the household", isOn: $autoSplitNewExpenses)
                        .disabled(members.count < 2)
                    Text("When on, any new transaction with no explicit split is given equal ExpenseShare rows for every active member. You can still edit them per-transaction.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }

                Section {
                    HStack {
                        Text("Splits created")
                        Spacer()
                        Text("\(telemetry.splitsThisWeek)")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Settlements logged")
                        Spacer()
                        Text("\(telemetry.settlementsThisWeek)")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Attribution coverage")
                        Spacer()
                        Text(coverageLabel)
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .monospacedDigit()
                    }
                } header: {
                    Text("This week")
                } footer: {
                    Text("Attribution coverage shows what share of this month's non-transfer transactions carry a household member. Low numbers usually mean a default payer isn't set or the payee-learner needs more history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Reminders") {
                    Toggle("Surface household insights", isOn: $notificationsEnabled)

                    Stepper(value: $unsettledReminderDays, in: 7...90, step: 7) {
                        HStack {
                            Text("Unsettled reminder after")
                            Spacer()
                            Text("\(unsettledReminderDays) days")
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .monospacedDigit()
                        }
                    }
                    .disabled(!notificationsEnabled)
                    Text("Split shares that stay unpaid past this window surface as a Household insight. Set higher for slow-rolling households, lower to keep the ledger tight.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var coverageLabel: String {
        guard let pct = HouseholdTelemetry.attributionCoveragePercent(in: modelContext) else {
            return "—"
        }
        return "\(Int((pct * 100).rounded()))%"
    }
}

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

// MARK: - Recurring

/// Tunables for the recurring automation pipeline. Every key is read at
/// the call-site of the corresponding service method (no observers, no
/// notifications) so a settings change takes effect on the next
/// `RecurringScheduler.tick` — which fires on launch, scene-active, and
/// midnight rollover.
struct RecurringSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("recurringDetectionEnabled") private var detectionEnabled = true
    @AppStorage("recurringAutoConfirmThreshold") private var autoConfirmThreshold: Double = 0.85
    @AppStorage("recurringAutoApproveDays") private var autoApproveDays: Int = 7
    @AppStorage("recurringDriftEnabled") private var driftEnabled = true
    @AppStorage("recurringDriftThreshold") private var driftThreshold: Double = 0.10
    @AppStorage("recurringStaleAutoPauseEnabled") private var staleAutoPauseEnabled = true
    @AppStorage("recurringStaleMissCount") private var staleMissCount: Int = 3
    @AppStorage("recurringNotificationsEnabled") private var notificationsEnabled = false
    @AppStorage("recurringNotificationsThreshold") private var notificationsThreshold: Double = 100

    var body: some View {
        Form {
            Section("Detection") {
                Toggle("Auto-detect recurring transactions", isOn: $detectionEnabled)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Auto-add confidence")
                        Spacer()
                        Text("\(Int(autoConfirmThreshold * 100))%")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .monospacedDigit()
                    }
                    Slider(value: $autoConfirmThreshold, in: 0.7...0.95, step: 0.05)
                        .disabled(!detectionEnabled)
                    Text("Patterns at or above this confidence are added automatically. Lower values catch more, but may add false positives.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }

            Section("Review queue") {
                Stepper(value: $autoApproveDays, in: 0...30) {
                    HStack {
                        Text("Auto-approve after")
                        Spacer()
                        Text(autoApproveDays == 0 ? "Off" : "\(autoApproveDays) day\(autoApproveDays == 1 ? "" : "s")")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .monospacedDigit()
                    }
                }
                Text("Auto-created transactions sit in the review queue for this many days, then quietly mark themselves reviewed. Set to 0 to require manual approval.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }

            Section("Drift correction") {
                Toggle("Auto-update template amount when prices change", isOn: $driftEnabled)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text("\(Int(driftThreshold * 100))%")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .monospacedDigit()
                    }
                    Slider(value: $driftThreshold, in: 0.05...0.25, step: 0.01)
                        .disabled(!driftEnabled)
                    Text("Templates self-update when 3 consecutive linked transactions all land at a new price differing from the template by at least this percentage.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }

            Section("Stale templates") {
                Toggle("Auto-pause templates with no recent activity", isOn: $staleAutoPauseEnabled)

                Stepper(value: $staleMissCount, in: 2...12) {
                    HStack {
                        Text("Pause after missed cycles")
                        Spacer()
                        Text("\(staleMissCount)")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .monospacedDigit()
                    }
                }
                .disabled(!staleAutoPauseEnabled)
                Text("Templates with this many consecutive expected occurrences and zero linked transactions get paused. Resume manually from the templates list.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }

            Section("Notifications") {
                Toggle("Notify the day before a recurring expense", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, enabled in
                        if enabled {
                            RecurringNotificationScheduler.requestAuthorization { _ in
                                RecurringNotificationScheduler.rescheduleAll(context: modelContext)
                            }
                        } else {
                            RecurringNotificationScheduler.rescheduleAll(context: modelContext)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Only when amount is at least")
                        Spacer()
                        Text("$\(Int(notificationsThreshold))")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .monospacedDigit()
                    }
                    Slider(value: $notificationsThreshold, in: 0...500, step: 10)
                        .disabled(!notificationsEnabled)
                        .onChange(of: notificationsThreshold) { _, _ in
                            RecurringNotificationScheduler.rescheduleAll(context: modelContext)
                        }
                    Text("Skips small recurring charges so notifications stay rare and meaningful. Set to $0 to alert on every recurring expense.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recurring")
    }
}

// MARK: - Net Worth (P10)

struct NetWorthSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @AppStorage("netWorthAutoSnapshotEnabled") private var autoSnapshot = true
    @AppStorage("netWorthBackfillDays") private var backfillDays: Int = 365

    @State private var showRebuildConfirm = false
    @State private var lastActionMessage: String?

    var body: some View {
        Form {
            Section("Snapshots") {
                Toggle("Take a daily snapshot automatically", isOn: $autoSnapshot)
                Text("Snapshots fire on launch, midnight, and when the app comes back to the foreground. Turn off if you'd rather snapshot manually below.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                Stepper(value: $backfillDays, in: 30...1825, step: 30) {
                    HStack {
                        Text("Backfill window")
                        Spacer()
                        Text("\(backfillDays) days")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .monospacedDigit()
                    }
                }
                Text("How far back the first-launch backfill (and the destructive Rebuild action) reconstruct daily snapshots from your transaction history. Capped at 5 years.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                Button("Snapshot now") {
                    NetWorthHistoryService.snapshotNow(context: modelContext)
                    lastActionMessage = "Snapshot written for today."
                }
            }

            Section("Export") {
                Button("Export history as CSV…") {
                    let ok = NetWorthCSVExporter.exportSnapshots(context: modelContext)
                    lastActionMessage = ok ? "Exported snapshot history." : "No snapshots to export, or save was cancelled."
                }
                Text("CSV columns: date, assets, liabilities, net_worth, source. Opens cleanly in Numbers or Excel.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }

            Section("Rebuild") {
                Button("Rebuild history from transactions…", role: .destructive) {
                    showRebuildConfirm = true
                }
                Text("Wipes every Net Worth snapshot and per-account balance point, then rebuilds the entire backfill window from your current balances and transaction deltas. Use after large data imports or sign corrections.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }

            if let msg = lastActionMessage {
                Section {
                    Text(msg)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Net Worth")
        .confirmationDialog(
            "Rebuild Net Worth history?",
            isPresented: $showRebuildConfirm,
            titleVisibility: .visible
        ) {
            Button("Rebuild last \(backfillDays) days", role: .destructive) {
                NetWorthHistoryService.rebuildHistory(context: modelContext)
                lastActionMessage = "History rebuilt over the last \(backfillDays) days."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all stored snapshots and per-account balance points, then re-derives them from your current account balances minus future transaction deltas. The current totals will not change.")
        }
    }
}
