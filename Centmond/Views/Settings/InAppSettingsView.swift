import SwiftUI
import SwiftData
import KeyboardShortcuts
import UniformTypeIdentifiers
import AppKit

struct InAppSettingsView: View {
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"
    @AppStorage("startOfWeek") private var startOfWeek = 1
    @AppStorage("autoOpenInspector") private var autoOpenInspector = true
    @AppStorage("tableDensity") private var tableDensity = "default"
    @AppStorage("sidebarIconOnly") private var sidebarIconOnly = false

    @Environment(AppRouter.self) private var router

    // Subscriptions notifications (P8)
    @AppStorage(SubscriptionNotificationScheduler.masterEnabledKey) private var subNotifEnabled = true
    @AppStorage(SubscriptionNotificationScheduler.trialAlertDaysKey) private var subTrialLeadDays = 2
    @AppStorage(SubscriptionNotificationScheduler.chargeAlertEnabledKey) private var subChargeEnabled = true
    @AppStorage(SubscriptionNotificationScheduler.chargeAlertThresholdKey) private var subChargeThreshold: Double = 10
    @AppStorage(SubscriptionNotificationScheduler.priceHikeAlertEnabledKey) private var subPriceHikeEnabled = true
    @AppStorage(SubscriptionNotificationScheduler.unusedAlertEnabledKey) private var subUnusedEnabled = true

    // Recurring / Forecast / Household reminder keys — Phase 6 alerts unification.
    @AppStorage(RecurringNotificationScheduler.masterEnabledKey) private var recurringAlertsEnabled = false
    @AppStorage(RecurringNotificationScheduler.chargeAlertThresholdKey) private var recurringAlertsThreshold: Double = 100
    @AppStorage(ForecastNotificationScheduler.masterEnabledKey) private var forecastAlertsEnabled = true
    @AppStorage("householdNotificationsEnabled") private var householdAlertsEnabled = true
    @AppStorage("householdUnsettledReminderDays") private var householdUnsettledDays = 30

    // Phase 7 — Automation keys.
    @AppStorage("recurringDetectionEnabled") private var recurringDetectionEnabled = true
    @AppStorage("recurringAutoConfirmThreshold") private var recurringAutoConfirmThreshold: Double = 0.85
    @AppStorage("recurringAutoApproveDays") private var recurringAutoApproveDays: Int = 7
    @AppStorage("recurringDriftEnabled") private var recurringDriftEnabled = true
    @AppStorage("recurringDriftThreshold") private var recurringDriftThreshold: Double = 0.10
    @AppStorage("recurringStaleAutoPauseEnabled") private var recurringStaleAutoPauseEnabled = true
    @AppStorage("recurringStaleMissCount") private var recurringStaleMissCount: Int = 3

    @AppStorage("netWorthAutoSnapshotEnabled") private var netWorthAutoSnapshot = true
    @AppStorage("netWorthBackfillDays") private var netWorthBackfillDays: Int = 365

    @AppStorage("householdDefaultPayerID") private var householdDefaultPayerID: String = ""
    @AppStorage("householdAutoSplitNewExpenses") private var householdAutoSplit = false

    // Phase 8 — Privacy & Security keys.
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appPasscode") private var storedPasscode = ""
    @AppStorage("lockOnSleep") private var lockOnSleep = true
    @AppStorage("lockTimeoutMinutes") private var lockTimeoutMinutes = 5

    @State private var showSetPasscodeSheet = false
    @State private var newPasscode = ""
    @State private var confirmPasscode = ""
    @State private var passcodeError = ""

    // Phase 9 — Reports keys + telemetry.
    @AppStorage("reports.defaultFormat") private var reportsDefaultFormatRaw: String = ReportExportFormat.pdf.rawValue
    @AppStorage("reports.csvIncludeRawTransactions") private var reportsCsvIncludeRaw = false
    @AppStorage("reports.autoSummarize") private var reportsAutoSummarize = false
    @Bindable private var reportsTelemetry = ReportsTelemetry.shared

    @State private var showResetReportsActivityConfirm = false
    @State private var showResetOnboardingConfirm = false

    // Active household members drive the default-payer picker options.
    @Query(sort: \HouseholdMember.joinedAt) private var allHouseholdMembers: [HouseholdMember]

    @State private var showNetWorthRebuildConfirm = false
    @State private var automationActionMessage: String?

    @Environment(\.modelContext) private var modelContext

    // AI
    private let aiManager = AIManager.shared
    private let modeManager = AIAssistantModeManager.shared
    private let insightEngine = AIInsightEngine.shared
    @State private var showDeleteModelConfirm = false
    @State private var showDownloadConfirm = false
    @State private var showModelImporter = false
    @State private var showResetMemoryConfirm = false
    @State private var showModelPicker = false

    // Danger Zone — erase all data
    @State private var showEraseAllSheet = false
    @State private var showEraseRestartAlert = false
    @State private var eraseConfirmationPhrase = ""
    private let eraseRequiredPhrase = "DELETE ALL"

    // Phase 2 shell state. Stored globally via AppStorage so deeplinks
    // (router.openSettings(domain:)) can write the target key before the
    // view appears. Phase 10.
    @AppStorage("settings.selectedDomain") private var selectedDomainRaw: String = SettingsDomain.workspace.rawValue
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool

    private var selectedDomain: SettingsDomain {
        SettingsDomain(rawValue: selectedDomainRaw) ?? .workspace
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 232)
                .background(.regularMaterial)
                .background(CentmondTheme.Colors.bgPrimary)
            Divider()
                .background(CentmondTheme.Colors.strokeSubtle)
            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            // Hidden command-F button: focuses the sidebar search field
            // from anywhere in the Settings pane. Invisible, zero-size.
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
        .sheet(isPresented: $showEraseAllSheet) {
            EraseAllDataSheet(
                requiredPhrase: eraseRequiredPhrase,
                typedPhrase: $eraseConfirmationPhrase,
                onCancel: { showEraseAllSheet = false },
                onConfirm: {
                    StoreNuke.requestNukeOnNextLaunch()
                    showEraseAllSheet = false
                    showEraseRestartAlert = true
                }
            )
        }
        .alert("Quit to Finish Reset", isPresented: $showEraseRestartAlert) {
            Button("Quit Centmond", role: .destructive) {
                NSApp.terminate(nil)
            }
        } message: {
            Text("Centmond will erase all data the next time it launches. Click Quit Centmond to finish the reset, then open Centmond again. Your data will be gone, and onboarding will run from the beginning.")
        }
        .alert("Delete AI Model?", isPresented: $showDeleteModelConfirm) {
            Button("Delete", role: .destructive) {
                aiManager.deleteModel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the downloaded model file. You can re-download it later.")
        }
        .alert("Reset AI Memory?", isPresented: $showResetMemoryConfirm) {
            Button("Reset", role: .destructive) {
                AIMemoryStore.shared.clearAll()
                AIMerchantMemory.shared.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will erase all learned preferences, merchant memory, and approval history. This cannot be undone.")
        }
        .fileImporter(
            isPresented: $showModelImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result,
               let url = urls.first,
               url.lastPathComponent.hasSuffix(".gguf") {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                try? aiManager.importModel(from: url)
                aiManager.loadModel()
            }
        }
        .sheet(isPresented: $showModelPicker) {
            AIModelPickerSheet()
        }
        .sheet(isPresented: $showSetPasscodeSheet) {
            setPasscodeSheet
        }
        .confirmationDialog(
            "Rebuild Net Worth history?",
            isPresented: $showNetWorthRebuildConfirm,
            titleVisibility: .visible
        ) {
            Button("Rebuild last \(netWorthBackfillDays) days", role: .destructive) {
                NetWorthHistoryService.rebuildHistory(context: modelContext)
                automationActionMessage = "Net-worth history rebuilt over the last \(netWorthBackfillDays) days."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every snapshot and per-account balance point, then re-derives them from your current account balances minus future transaction deltas. Current totals will not change.")
        }
        .confirmationDialog(
            "Reset activity counters?",
            isPresented: $showResetReportsActivityConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { reportsTelemetry.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears report run and export counts. Saved presets and generated files are not affected.")
        }
        .confirmationDialog(
            "Replay onboarding on next launch?",
            isPresented: $showResetOnboardingConfirm,
            titleVisibility: .visible
        ) {
            Button("Replay", role: .destructive) {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The welcome tour runs again next time you open Centmond. Your data is not affected.")
        }
    }

    // MARK: - Phase 5 — AI Assistant groups

    private var activeModelSummary: String {
        if let active = aiManager.availableModels.first(where: { $0.filename == AIManager.modelFilename }) {
            return "\(active.quantization) \u{00B7} \(active.formattedSize)"
        }
        return AIManager.modelFilename.replacingOccurrences(of: ".gguf", with: "")
    }

    @ViewBuilder
    private var aiModelGroup: some View {
        SettingsRowGroup(
            "Model",
            icon: "cpu",
            iconColor: DS.Colors.accent,
            footer: aiManager.isModelDownloaded
                ? "Weights live on this Mac. Delete releases the disk space and requires a re-download to chat again."
                : "Centmond runs its assistant fully on-device — no cloud, no telemetry. Pick a model to get started."
        ) {
            SettingsRow.status(
                "Status",
                systemImage: "waveform.path.ecg",
                value: aiStatusLabel,
                indicator: aiStatusColor
            )
            SettingsRow.navigation(
                "Active model",
                systemImage: "sparkle",
                help: "Swap between downloaded models or pick a different quantization.",
                trailing: activeModelSummary,
                action: { showModelPicker = true }
            )
            if case .downloading(let progress, _) = aiManager.status {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: CentmondTheme.Spacing.md) {
                        SettingsRowLabel("Downloading", systemImage: "arrow.down.circle.fill",
                                         help: "Feel free to use the rest of Centmond while this runs.")
                        Text("\(Int(progress * 100))%")
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .monospacedDigit()
                    }
                    HStack(spacing: CentmondTheme.Spacing.md) {
                        ProgressView(value: progress)
                            .tint(DS.Colors.accent)
                        Button("Cancel") { aiManager.cancelDownload() }
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(DS.Colors.danger)
                    }
                }
                .padding(.vertical, 10)
            }
            if !aiManager.isModelDownloaded {
                SettingsRow.action(
                    "Download a model",
                    systemImage: "arrow.down.circle",
                    help: "Pick a recommended model that fits your Mac.",
                    buttonLabel: "Choose\u{2026}",
                    buttonSystemImage: "chevron.right",
                    action: { showModelPicker = true }
                )
                SettingsRow.action(
                    "Import a .gguf file",
                    systemImage: "folder",
                    help: "Bring your own weights from a download you already have.",
                    buttonLabel: "Import\u{2026}",
                    buttonSystemImage: "tray.and.arrow.down",
                    action: { showModelImporter = true }
                )
            } else {
                SettingsRow.action(
                    "Replace the active model",
                    systemImage: "arrow.triangle.2.circlepath",
                    help: "Swap in a different .gguf without losing your chat history.",
                    buttonLabel: "Replace\u{2026}",
                    action: { showModelImporter = true }
                )
                SettingsRow.action(
                    "Delete the model file",
                    systemImage: "trash",
                    help: "Frees disk space. You can re-download any time from the picker.",
                    buttonLabel: "Delete\u{2026}",
                    role: .destructive,
                    action: { showDeleteModelConfirm = true }
                )
            }
        }
    }

    @ViewBuilder
    private var aiBehaviorGroup: some View {
        SettingsRowGroup(
            "Behavior",
            icon: "dial.medium.fill",
            iconColor: DS.Colors.accent,
            footer: "Assistant mode controls how chatty and autonomous the AI is. Advice polish rewrites plain detector output into friendlier prose."
        ) {
            SettingsRow.picker(
                "Assistant mode",
                systemImage: "dial.medium.fill",
                help: "From purely reactive to proactively suggesting actions.",
                selection: Binding(
                    get: { modeManager.currentMode },
                    set: { modeManager.currentMode = $0 }
                ),
                options: AssistantMode.allCases.map { ($0, $0.title) },
                width: 160
            )
            SettingsRow.toggle(
                "AI advice polish",
                systemImage: "wand.and.stars",
                help: "Uses the on-device model to rewrite detector output into plain-English advice. Costs a little battery on older Macs.",
                isOn: Binding(
                    get: { insightEngine.isInsightEnrichmentEnabled },
                    set: { insightEngine.isInsightEnrichmentEnabled = $0 }
                )
            )
        }
    }

    @ViewBuilder
    private var aiNotificationsGroup: some View {
        SettingsRowGroup(
            "Notifications",
            icon: "bell",
            iconColor: DS.Colors.accent,
            footer: "These are macOS notifications generated by Centmond itself — nothing leaves your Mac."
        ) {
            SettingsRow.toggle(
                "Morning insights",
                systemImage: "sun.max.fill",
                help: "A short daily digest pushed at 9am.",
                isOn: Binding(
                    get: { insightEngine.isMorningNotificationEnabled },
                    set: { insightEngine.isMorningNotificationEnabled = $0 }
                )
            )
            SettingsRow.toggle(
                "Weekly review",
                systemImage: "calendar.badge.clock",
                help: "A Sunday-evening summary of spending, goals, and anomalies.",
                isOn: Binding(
                    get: { insightEngine.isWeeklyReviewEnabled },
                    set: { insightEngine.isWeeklyReviewEnabled = $0 }
                )
            )
            SettingsRow.toggle(
                "Critical push",
                systemImage: "exclamationmark.bubble.fill",
                help: "Interrupts you only for high-severity findings (fraud-like activity, budget blown).",
                isOn: Binding(
                    get: { insightEngine.isCriticalPushEnabled },
                    set: { insightEngine.isCriticalPushEnabled = $0 }
                )
            )
        }
    }

    @ViewBuilder
    private var aiShortcutsGroup: some View {
        SettingsRowGroup(
            "Shortcuts",
            icon: "keyboard",
            iconColor: DS.Colors.accent,
            footer: "Click the recorder and press a key combination. Cleared fields disable the shortcut."
        ) {
            SettingsRowContainerShim(
                label: SettingsRowLabel(
                    "AI chat",
                    systemImage: "bubble.left.and.bubble.right",
                    help: "Open the assistant from anywhere in the app."
                )
            ) {
                KeyboardShortcuts.Recorder("", name: .toggleAIChat)
                    .frame(width: 160)
            }
        }
    }

    @ViewBuilder
    private var aiMemoryGroup: some View {
        SettingsRowGroup(
            "Memory",
            icon: "brain",
            iconColor: DS.Colors.accent,
            footer: "AI memory contains learned preferences, merchant aliases, and approval history. Resetting won't affect your transactions."
        ) {
            SettingsRow.status(
                "Learned items",
                systemImage: "brain",
                help: "Everything the assistant has inferred about your habits.",
                value: "\(AIMemoryStore.shared.totalCount)"
            )
            SettingsRow.action(
                "Reset AI memory",
                systemImage: "arrow.counterclockwise.circle",
                help: "Erases learned preferences, merchant memory, and approval history.",
                buttonLabel: "Reset\u{2026}",
                role: .destructive,
                action: { showResetMemoryConfirm = true }
            )
        }
    }

    @ViewBuilder
    private var aiMutedGroup: some View {
        SettingsRowGroup(
            "Muted insights",
            icon: "speaker.slash",
            iconColor: DS.Colors.accent,
            footer: "Silenced detectors stop producing insights until you re-enable them here."
        ) {
            MutedDetectorsSection()
                .padding(.vertical, 10)
        }
    }

    private var aiStatusColor: Color {
        switch aiManager.status {
        case .ready, .generating: return DS.Colors.positive
        case .loading, .downloading: return DS.Colors.warning
        case .error: return DS.Colors.danger
        case .notLoaded: return CentmondTheme.Colors.textQuaternary
        }
    }

    private var aiStatusLabel: String {
        switch aiManager.status {
        case .ready: return "Ready"
        case .generating: return "Generating…"
        case .loading: return "Loading…"
        case .downloading(let p, _): return "Downloading \(Int(p * 100))%"
        case .error(let msg): return msg
        case .notLoaded: return aiManager.isModelDownloaded ? "Not loaded" : "No model"
        }
    }

    // MARK: - Phase 6 — Alerts groups

    /// Wrap a raw AppStorage binding so writing the value also reruns the
    /// given scheduler. Keeps the side-effect co-located with the binding so
    /// every row doesn't need its own `.onChange` modifier.
    private func rescheduling<Value>(
        _ binding: Binding<Value>,
        reschedule: @escaping () -> Void
    ) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                reschedule()
            }
        )
    }

    private func subReschedule() {
        SubscriptionNotificationScheduler.rescheduleAll(context: modelContext)
    }

    private func recurringReschedule() {
        RecurringNotificationScheduler.rescheduleAll(context: modelContext)
    }

    private func forecastReschedule() {
        ForecastNotificationScheduler.rescheduleAll(context: modelContext)
    }

    @ViewBuilder
    private var alertsSubscriptionsGroup: some View {
        SettingsRowGroup(
            "Subscription alerts",
            icon: "bell.badge.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Centmond never transmits your data — these run locally and post macOS notifications."
        ) {
            SettingsRow.toggle(
                "Enable subscription alerts",
                systemImage: "power",
                help: "Master switch — turning off cancels every pending subscription alert.",
                isOn: Binding(
                    get: { subNotifEnabled },
                    set: { newValue in
                        subNotifEnabled = newValue
                        if newValue {
                            SubscriptionNotificationScheduler.requestAuthorization { _ in
                                subReschedule()
                            }
                        } else {
                            subReschedule()
                        }
                    }
                )
            )
            SettingsRow.picker(
                "Trial-ends lead time",
                systemImage: "clock",
                help: "How early to notify before a free trial ends.",
                selection: rescheduling($subTrialLeadDays, reschedule: subReschedule),
                options: [
                    (0, "Same day"),
                    (1, "1 day before"),
                    (2, "2 days before"),
                    (3, "3 days before"),
                    (7, "7 days before")
                ],
                width: 170
            )
            SettingsRow.toggle(
                "Charge tomorrow",
                systemImage: "calendar.badge.exclamationmark",
                help: "Notify the morning before a charge over the threshold.",
                isOn: rescheduling($subChargeEnabled, reschedule: subReschedule)
            )
            SettingsRow.picker(
                "Charge alert threshold",
                systemImage: "dollarsign.circle",
                help: "Skip charges below this amount so alerts stay rare.",
                selection: rescheduling($subChargeThreshold, reschedule: subReschedule),
                options: [
                    (0.0, "Any amount"),
                    (5.0, "$5+"),
                    (10.0, "$10+"),
                    (25.0, "$25+"),
                    (50.0, "$50+")
                ],
                width: 150
            )
            SettingsRow.toggle(
                "Price hikes",
                systemImage: "arrow.up.right.circle",
                help: "Ping when a subscription bills more than its typical historical amount.",
                isOn: rescheduling($subPriceHikeEnabled, reschedule: subReschedule)
            )
            SettingsRow.toggle(
                "Unused subscriptions",
                systemImage: "moon.zzz",
                help: "Nudge after 60+ days without any related transactions so you can consider cancelling.",
                isOn: rescheduling($subUnusedEnabled, reschedule: subReschedule)
            )
        }
    }

    @ViewBuilder
    private var alertsRecurringGroup: some View {
        SettingsRowGroup(
            "Recurring reminders",
            icon: "repeat.circle.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Recurring templates include things like rent, salary, and utility bills — see the Recurring screen for the full list."
        ) {
            SettingsRow.toggle(
                "Notify the day before",
                systemImage: "calendar.badge.clock",
                help: "Ping the morning before a recurring charge is expected.",
                isOn: Binding(
                    get: { recurringAlertsEnabled },
                    set: { newValue in
                        recurringAlertsEnabled = newValue
                        if newValue {
                            RecurringNotificationScheduler.requestAuthorization { _ in
                                recurringReschedule()
                            }
                        } else {
                            recurringReschedule()
                        }
                    }
                )
            )
            SettingsRow.slider(
                "Only when amount is at least",
                systemImage: "dollarsign.circle",
                help: "Skips small recurring charges so reminders stay meaningful.",
                value: rescheduling($recurringAlertsThreshold, reschedule: recurringReschedule),
                range: 0...500,
                step: 10,
                format: { "$\(Int($0))" }
            )
        }
    }

    @ViewBuilder
    private var alertsForecastGroup: some View {
        SettingsRowGroup(
            "Forecast alerts",
            icon: "chart.line.uptrend.xyaxis",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Forecasting looks at upcoming bills vs projected income and flags runway risk."
        ) {
            SettingsRow.toggle(
                "Warn about runway + cash-flow risk",
                systemImage: "exclamationmark.triangle",
                help: "Surface a macOS notification when your projected runway drops below 14 days or a month turns negative.",
                isOn: Binding(
                    get: { forecastAlertsEnabled },
                    set: { newValue in
                        forecastAlertsEnabled = newValue
                        if newValue {
                            ForecastNotificationScheduler.requestAuthorization { _ in
                                forecastReschedule()
                            }
                        } else {
                            forecastReschedule()
                        }
                    }
                )
            )
        }
    }

    @ViewBuilder
    private var alertsHouseholdGroup: some View {
        SettingsRowGroup(
            "Household reminders",
            icon: "person.2.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Household insights surface in the Dashboard strip and the Insights hub — they don't post macOS notifications."
        ) {
            SettingsRow.toggle(
                "Surface household insights",
                systemImage: "lightbulb.fill",
                help: "Unsettled balances, missing attribution, and imbalanced splits.",
                isOn: $householdAlertsEnabled
            )
            SettingsRow.stepper(
                "Unsettled reminder after",
                systemImage: "hourglass",
                help: "Split shares that stay unpaid past this window surface as an insight.",
                value: $householdUnsettledDays,
                range: 7...90,
                step: 7,
                format: { "\($0) days" }
            )
        }
    }

    // MARK: - Phase 7 — Automation groups

    private var activeHouseholdMembers: [HouseholdMember] {
        allHouseholdMembers.filter(\.isActive)
    }

    @ViewBuilder
    private var automationRecurringGroup: some View {
        SettingsRowGroup(
            "Recurring pipeline",
            icon: "repeat.circle.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Centmond learns from your ledger and turns repeating charges into managed templates. All of this runs on-device."
        ) {
            SettingsRow.toggle(
                "Auto-detect recurring transactions",
                systemImage: "sparkles",
                help: "Scans for repeating patterns (Netflix, rent, utilities) and suggests templates.",
                isOn: $recurringDetectionEnabled
            )
            SettingsRow.slider(
                "Auto-add confidence",
                systemImage: "gauge.medium",
                help: "Patterns at or above this score are added without asking. Lower catches more, but adds some false positives.",
                value: $recurringAutoConfirmThreshold,
                range: 0.70...0.95,
                step: 0.05,
                format: { "\(Int($0 * 100))%" }
            )
            SettingsRow.stepper(
                "Auto-approve after",
                systemImage: "checkmark.seal",
                help: "Auto-created transactions sit in the review queue for this many days, then quietly mark themselves reviewed.",
                value: $recurringAutoApproveDays,
                range: 0...30,
                format: { $0 == 0 ? "Off" : "\($0) day\($0 == 1 ? "" : "s")" }
            )
            SettingsRow.toggle(
                "Auto-update template amount when prices change",
                systemImage: "arrow.up.arrow.down",
                help: "When 3 consecutive linked transactions all land at a new price, bump the template to match.",
                isOn: $recurringDriftEnabled
            )
            SettingsRow.slider(
                "Drift sensitivity",
                systemImage: "wand.and.rays",
                help: "Minimum price change that counts as drift.",
                value: $recurringDriftThreshold,
                range: 0.05...0.25,
                step: 0.01,
                format: { "\(Int($0 * 100))%" }
            )
            SettingsRow.toggle(
                "Auto-pause templates with no recent activity",
                systemImage: "pause.circle",
                help: "Templates that miss too many expected cycles pause themselves.",
                isOn: $recurringStaleAutoPauseEnabled
            )
            SettingsRow.stepper(
                "Pause after missed cycles",
                systemImage: "number",
                help: "How many consecutive no-shows before a template auto-pauses.",
                value: $recurringStaleMissCount,
                range: 2...12,
                format: { "\($0)" }
            )
        }
    }

    @ViewBuilder
    private var automationNetWorthGroup: some View {
        SettingsRowGroup(
            "Net-worth history",
            icon: "chart.line.uptrend.xyaxis",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Snapshots fire on launch, midnight, and when the app comes back to the foreground."
        ) {
            SettingsRow.toggle(
                "Daily snapshot",
                systemImage: "camera.aperture",
                help: "Keeps the Net-worth chart up to date automatically.",
                isOn: $netWorthAutoSnapshot
            )
            SettingsRow.stepper(
                "Backfill window",
                systemImage: "calendar",
                help: "How far back first-launch and rebuild reconstruct history. Capped at 5 years.",
                value: $netWorthBackfillDays,
                range: 30...1825,
                step: 30,
                format: { "\($0) days" }
            )
            SettingsRow.action(
                "Snapshot now",
                systemImage: "camera.fill",
                help: "Capture a snapshot for today without waiting for the next automatic run.",
                buttonLabel: "Capture",
                buttonSystemImage: "bolt.fill",
                action: {
                    NetWorthHistoryService.snapshotNow(context: modelContext)
                    automationActionMessage = "Snapshot written for today."
                }
            )
            SettingsRow.action(
                "Export history as CSV",
                systemImage: "square.and.arrow.up",
                help: "Columns: date, assets, liabilities, net_worth, source.",
                buttonLabel: "Export\u{2026}",
                action: {
                    let ok = NetWorthCSVExporter.exportSnapshots(context: modelContext)
                    automationActionMessage = ok ? "Exported snapshot history." : "No snapshots to export, or save was cancelled."
                }
            )
            SettingsRow.action(
                "Rebuild history from transactions",
                systemImage: "arrow.counterclockwise.circle",
                help: "Wipes every snapshot and per-account balance point, then rebuilds the backfill window from your current balances and transaction deltas.",
                buttonLabel: "Rebuild\u{2026}",
                role: .destructive,
                action: { showNetWorthRebuildConfirm = true }
            )
        }
    }

    @ViewBuilder
    private var automationHouseholdGroup: some View {
        SettingsRowGroup(
            "Household defaults",
            icon: "person.2.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: activeHouseholdMembers.isEmpty
                ? "Add household members from the Household hub to unlock per-person attribution."
                : "New manual transactions inherit these defaults unless you override them at entry."
        ) {
            if activeHouseholdMembers.isEmpty {
                SettingsRow.status(
                    "No household members",
                    systemImage: "person.crop.circle.badge.questionmark",
                    help: "Open Household → Members to add people.",
                    value: "—"
                )
            } else {
                SettingsRow.picker(
                    "Default payer",
                    systemImage: "person.fill",
                    help: "New manual and AI-added transactions are attributed to this member unless overridden.",
                    selection: $householdDefaultPayerID,
                    options: [("", "Ask each time")] + activeHouseholdMembers.map { ($0.id.uuidString, $0.name) },
                    width: 180
                )
                SettingsRow.toggle(
                    "Auto-split new expenses across the household",
                    systemImage: "rectangle.split.3x1",
                    help: "New transactions with no explicit split get equal ExpenseShare rows for every active member.",
                    isOn: $householdAutoSplit
                )
            }
        }
    }

    // MARK: - Phase 8 — Privacy & Security groups

    private var lockTimeoutLabel: String {
        switch lockTimeoutMinutes {
        case 0: return "Never"
        case 1: return "1 minute"
        default: return "\(lockTimeoutMinutes) minutes"
        }
    }

    private var storageLocationPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let path = (appSupport?.path as NSString?)?.abbreviatingWithTildeInPath ?? "~/Library/Application Support"
        return path
    }

    private var aiModelPresenceLabel: String {
        aiManager.isModelDownloaded ? "Downloaded on this Mac" : "Not downloaded"
    }

    @ViewBuilder
    private var securityAppLockGroup: some View {
        SettingsRowGroup(
            "App lock",
            icon: "lock.shield.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Your passcode is stored locally and never transmitted. Forgetting it means erasing your data to reset."
        ) {
            SettingsRow.toggle(
                "Require passcode to open Centmond",
                systemImage: "lock.fill",
                help: "Centmond asks for a 4-digit passcode when you launch or unlock.",
                isOn: Binding(
                    get: { appLockEnabled },
                    set: { newValue in
                        if newValue && storedPasscode.isEmpty {
                            // Can't enable without a passcode — open the setter
                            // and leave the toggle off until it's saved.
                            newPasscode = ""
                            confirmPasscode = ""
                            passcodeError = ""
                            showSetPasscodeSheet = true
                            return
                        }
                        appLockEnabled = newValue
                        if !newValue { storedPasscode = "" }
                    }
                )
            )
            if appLockEnabled {
                SettingsRow.toggle(
                    "Lock when Mac sleeps",
                    systemImage: "moon.zzz.fill",
                    help: "Re-prompt for the passcode when the Mac wakes up.",
                    isOn: $lockOnSleep
                )
                SettingsRow.picker(
                    "Auto-lock after inactivity",
                    systemImage: "timer",
                    help: "Centmond re-locks after this many minutes of no interaction.",
                    selection: $lockTimeoutMinutes,
                    options: [
                        (0, "Never"),
                        (1, "1 minute"),
                        (5, "5 minutes"),
                        (15, "15 minutes"),
                        (30, "30 minutes")
                    ],
                    width: 170
                )
                SettingsRow.action(
                    "Change passcode",
                    systemImage: "key.fill",
                    help: "Pick a new 4-digit code. The old one is replaced immediately.",
                    buttonLabel: "Change\u{2026}",
                    action: {
                        newPasscode = ""
                        confirmPasscode = ""
                        passcodeError = ""
                        showSetPasscodeSheet = true
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var securityStorageGroup: some View {
        SettingsRowGroup(
            "What's stored on this Mac",
            icon: "internaldrive.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Everything lives on-device. No cloud sync, no analytics, no telemetry."
        ) {
            SettingsRow.status(
                "Database",
                systemImage: "cylinder.split.1x2",
                help: "SwiftData store containing every account, transaction, and budget.",
                value: "SwiftData (local)"
            )
            SettingsRow.status(
                "Location",
                systemImage: "folder",
                help: "Path on this Mac where the store and caches live.",
                value: storageLocationPath
            )
            SettingsRow.status(
                "AI model",
                systemImage: "cpu",
                help: "Gemma weights used by the assistant. Runs fully on-device via llama.cpp.",
                value: aiModelPresenceLabel
            )
            SettingsRow.status(
                "AI learned items",
                systemImage: "brain",
                help: "Merchant aliases, preferences, and approval history the assistant has built up.",
                value: "\(AIMemoryStore.shared.totalCount)"
            )
        }
    }

    @ViewBuilder
    private var securityResetGroup: some View {
        SettingsRowGroup(
            "Reset",
            icon: "arrow.counterclockwise.circle.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Resetting AI memory does not touch your transactions, accounts, or budgets."
        ) {
            SettingsRow.action(
                "Reset AI memory",
                systemImage: "brain",
                help: "Erases learned preferences, merchant memory, and approval history.",
                buttonLabel: "Reset\u{2026}",
                role: .destructive,
                action: { showResetMemoryConfirm = true }
            )
        }
    }

    // MARK: - Passcode sheet (Phase 8)

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
                    showSetPasscodeSheet = false
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
        showSetPasscodeSheet = false
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
                    .font(CentmondTheme.Typography.bodyLarge.weight(.medium))
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

    // MARK: - Phase 2 shell — sidebar + detail pane

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// Tokenised lowercase search — every whitespace-separated chunk must
    /// appear somewhere in the key's haystack. Typing "ai push" finds the
    /// critical-push row; typing "csv export" finds both net-worth + reports.
    private var searchTokens: [String] {
        trimmedQuery
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func matches(_ haystack: String, tokens: [String]) -> Bool {
        tokens.allSatisfy { haystack.contains($0) }
    }

    /// Domains that have a match in the current search (used to dim non-matching
    /// rows in the sidebar so the user can see where their query lives).
    private var domainsMatchingSearch: Set<SettingsDomain> {
        guard isSearching else { return Set(SettingsDomain.allCases) }
        let tokens = searchTokens
        return Set(SettingsCatalog.searchIndex()
            .filter { matches($0.haystack, tokens: tokens) }
            .map { $0.key.domain })
    }

    private var searchMatches: [SettingsKey] {
        guard isSearching else { return [] }
        let tokens = searchTokens
        return SettingsCatalog.searchIndex()
            .filter { matches($0.haystack, tokens: tokens) }
            .map { $0.key }
    }

    private func jumpToFirstMatch() {
        guard let first = searchMatches.first else { return }
        selectedDomainRaw = first.domain.rawValue
        searchQuery = ""
        isSearchFocused = false
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title block
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text("Customize Centmond")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.top, CentmondTheme.Spacing.xl)
            .padding(.bottom, CentmondTheme.Spacing.md)

            // Search field (\u{2318}F focuses, Return jumps to top match, Esc clears)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(isSearchFocused ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textQuaternary)
                TextField("Search settings  \u{2318}F", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.body)
                    .focused($isSearchFocused)
                    .onSubmit { jumpToFirstMatch() }
                if isSearching {
                    Button {
                        searchQuery = ""
                        isSearchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(CentmondTheme.Colors.bgTertiary, in: RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                    .stroke(isSearchFocused ? CentmondTheme.Colors.accent.opacity(0.5) : CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.bottom, CentmondTheme.Spacing.md)

            // Domain list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SettingsDomain.allCases) { domain in
                        sidebarRow(domain)
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.sm)
            }

            Spacer(minLength: 0)

            // Version footer keeps the left pane grounded
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                Text("Centmond \(version) (\(build))")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .padding(.horizontal, CentmondTheme.Spacing.lg)
                    .padding(.bottom, CentmondTheme.Spacing.md)
            }
        }
    }

    private func sidebarRow(_ domain: SettingsDomain) -> some View {
        let isSelected = (domain == selectedDomain) && !isSearching
        let dimmed = isSearching && !domainsMatchingSearch.contains(domain)
        return Button {
            selectedDomainRaw = domain.rawValue
            if isSearching { searchQuery = "" }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: domain.icon)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
                Text(domain.title)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(isSelected ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                    .fill(isSelected ? CentmondTheme.Colors.accent.opacity(0.12) : Color.clear)
            )
            // Tap the whole row, not just the text. Spacer() alone isn't
            // hit-testable under .buttonStyle(.plain); contentShape makes
            // the full padded rectangle clickable.
            .contentShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .opacity(dimmed ? 0.42 : 1.0)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        ScrollView {
            VStack(spacing: CentmondTheme.Spacing.xxl) {
                SectionTutorialStrip(screen: .settings)

                if isSearching {
                    searchResultsPane
                } else {
                    domainPane(selectedDomain)
                }

                Spacer(minLength: CentmondTheme.Spacing.xxxl)
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.top, CentmondTheme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func domainPane(_ domain: SettingsDomain) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: domain.icon)
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                Text(domain.title)
                    .font(CentmondTheme.Typography.heading1)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            .padding(.bottom, CentmondTheme.Spacing.sm)

            // Per-domain content
            VStack(spacing: CentmondTheme.Spacing.lg) {
                switch domain {
                case .workspace:
                    workspaceGettingStartedGroup
                    workspaceLocaleGroup
                    workspaceLayoutGroup
                    workspaceBehaviorGroup
                    workspaceQuickAddGroup
                case .ai:
                    aiModelGroup
                    aiBehaviorGroup
                    aiNotificationsGroup
                    aiShortcutsGroup
                    aiMemoryGroup
                    aiMutedGroup
                case .alerts:
                    alertsSubscriptionsGroup
                    alertsRecurringGroup
                    alertsForecastGroup
                    alertsHouseholdGroup
                case .automation:
                    automationRecurringGroup
                    automationNetWorthGroup
                    automationHouseholdGroup
                    if let msg = automationActionMessage {
                        SettingsRowGroup("Last action", icon: "checkmark.seal.fill") {
                            SettingsRowContainerShim(
                                label: SettingsRowLabel(msg, systemImage: "info.circle")
                            ) { EmptyView() }
                        }
                    }
                case .security:
                    securityAppLockGroup
                    securityStorageGroup
                    securityResetGroup
                case .reports:
                    reportsDefaultsGroup
                    reportsActivityGroup
                    reportsResetGroup
                case .data:
                    dataExportsGroup
                    dataResetGroup
                    dangerZoneGroup
                case .about:
                    aboutVersionGroup
                    aboutShortcutsGroup
                }
            }
        }
    }

    private var searchResultsPane: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(CentmondTheme.Colors.accent)
                Text("\(searchMatches.count) match\(searchMatches.count == 1 ? "" : "es") for \u{201C}\(trimmedQuery)\u{201D}")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Spacer()
                if !searchMatches.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .semibold))
                        Text("jumps to top match")
                            .font(CentmondTheme.Typography.caption)
                    }
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
            .padding(.bottom, CentmondTheme.Spacing.sm)

            if searchMatches.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No matches")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("Try a shorter query, or check the spelling. Multi-word searches look for every word (e.g. \u{201C}ai critical\u{201D}).")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
                .padding(CentmondTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CentmondTheme.Colors.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                        .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(searchMatches.enumerated()), id: \.element.id) { idx, match in
                        searchResultRow(match, isTop: idx == 0)
                    }
                }
            }
        }
    }

    private func searchResultRow(_ key: SettingsKey, isTop: Bool = false) -> some View {
        Button {
            selectedDomainRaw = key.domain.rawValue
            searchQuery = ""
        } label: {
            HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
                Image(systemName: key.domain.icon)
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .frame(width: 22, height: 22)
                    .background(CentmondTheme.Colors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.title)
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    if let help = key.helpText {
                        Text(help)
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(key.domain.title.uppercased())
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .tracking(0.5)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(CentmondTheme.Typography.captionSmallSemibold)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .padding(.top, 4)
            }
            .padding(CentmondTheme.Spacing.md)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                    .stroke(
                        isTop ? CentmondTheme.Colors.accent.opacity(0.55) : CentmondTheme.Colors.strokeSubtle,
                        lineWidth: isTop ? 1.5 : 1
                    )
            )
            // Whole card clickable, not just the title text.
            .contentShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func notYetMigratedNote(_ message: String) -> some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
            Image(systemName: "arrow.up.forward.circle.fill")
                .font(CentmondTheme.Typography.subheading.weight(.regular))
                .foregroundStyle(CentmondTheme.Colors.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Open it with \u{2318}, from the Centmond menu.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
            Spacer(minLength: 0)
        }
        .padding(CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    // MARK: - Phase 4 — Workspace groups (built on SettingsRowKit)

    private var workspaceGettingStartedGroup: some View {
        SettingsRowGroup(
            "Getting Started",
            icon: "sparkles",
            iconColor: CentmondTheme.Colors.accent
        ) {
            SettingsRow.action(
                "Replay onboarding",
                systemImage: "play.circle",
                help: "Walk through the tour again. Nothing in your data changes.",
                buttonLabel: "Start tour",
                buttonSystemImage: "play.fill",
                action: { router.replayOnboarding() }
            )
        }
    }

    private var workspaceLocaleGroup: some View {
        SettingsRowGroup(
            "Locale",
            icon: "globe",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Changes take effect immediately across the dashboard, reports, and exports."
        ) {
            SettingsRow.picker(
                "Default currency",
                systemImage: "dollarsign.circle",
                help: "Used everywhere amounts are formatted.",
                selection: $defaultCurrency,
                options: [
                    ("USD", "USD ($)"),
                    ("EUR", "EUR (\u{20AC})"),
                    ("GBP", "GBP (\u{00A3})"),
                    ("JPY", "JPY (\u{00A5})"),
                    ("CAD", "CAD (C$)"),
                    ("AUD", "AUD (A$)")
                ],
                width: 150
            )
            SettingsRow.picker(
                "Start of week",
                systemImage: "calendar",
                help: "Drives every week-aware chart and date picker.",
                selection: $startOfWeek,
                options: [(1, "Sunday"), (2, "Monday")],
                width: 150
            )
        }
    }

    private var workspaceLayoutGroup: some View {
        SettingsRowGroup(
            "Layout",
            icon: "rectangle.split.3x1",
            iconColor: CentmondTheme.Colors.projected
        ) {
            SettingsRow.picker(
                "Table density",
                systemImage: "line.3.horizontal",
                help: "How tightly transactions and reports pack their rows.",
                selection: $tableDensity,
                options: [("default", "Default"), ("compact", "Compact")],
                width: 150
            )
            SettingsRow.toggle(
                "Compact sidebar",
                systemImage: "sidebar.left",
                help: "Show only icons to reclaim horizontal space.",
                isOn: $sidebarIconOnly
            )
            SettingsRow.status(
                "Color scheme",
                systemImage: "moon.fill",
                help: "Centmond is dark-only today. Light mode is planned for a later release.",
                value: "Dark"
            )
        }
    }

    private var workspaceBehaviorGroup: some View {
        SettingsRowGroup(
            "Behavior",
            icon: "gearshape",
            iconColor: CentmondTheme.Colors.accent
        ) {
            SettingsRow.toggle(
                "Auto-open inspector on selection",
                systemImage: "sidebar.right",
                help: "Opens the right-hand detail panel whenever you select a row.",
                isOn: $autoOpenInspector
            )
            SettingsRow.toggle(
                "Haptic feedback",
                systemImage: "waveform.path",
                help: "Subtle trackpad feedback on hover, selection, and actions. Requires a Force Touch trackpad.",
                isOn: $hapticsEnabled
            )
        }
    }

    // MARK: - Quick Add (menu bar + global hotkey)

    @ViewBuilder
    private var workspaceQuickAddGroup: some View {
        SettingsRowGroup(
            "Quick Add",
            icon: "plus.circle.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "The menu bar item and the shortcut both open the same three-step Quick Add popup — usable even when Centmond isn't in the foreground."
        ) {
            SettingsRow.toggle(
                "Show menu bar icon",
                systemImage: "menubar.rectangle",
                help: "Adds a Centmond icon to the macOS menu bar with a Quick Add shortcut.",
                isOn: $menuBarEnabled
            )
            SettingsRowContainerShim(
                label: SettingsRowLabel(
                    "Keyboard shortcut",
                    systemImage: "keyboard",
                    help: "Press this combination from anywhere to open the Quick Add popup."
                )
            ) {
                HStack(spacing: 8) {
                    KeyboardShortcuts.Recorder(for: .quickAddTransaction)
                    Button("Reset") {
                        KeyboardShortcuts.reset(.quickAddTransaction)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Restore the default ⌃⌘A shortcut.")
                }
            }
        }
    }

    // MARK: - Phase 9 — Reports groups

    @ViewBuilder
    private var reportsDefaultsGroup: some View {
        SettingsRowGroup(
            "Export defaults",
            icon: "doc.richtext.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Defaults apply when you click Export in the Reports toolbar — you can still override per-export."
        ) {
            SettingsRow.picker(
                "Default format",
                systemImage: "tray.and.arrow.down",
                help: "Which format the Export button picks first.",
                selection: $reportsDefaultFormatRaw,
                options: ReportExportFormat.allCases.map { ($0.rawValue, $0.displayName) },
                width: 180
            )
            SettingsRow.toggle(
                "Include raw transactions in CSV",
                systemImage: "tablecells",
                help: "Adds a second sheet with the full row-level breakdown.",
                isOn: $reportsCsvIncludeRaw
            )
            SettingsRow.toggle(
                "Auto-generate AI narrative on open",
                systemImage: "wand.and.stars",
                help: "Runs the on-device model over each report to generate a cover-page summary.",
                isOn: $reportsAutoSummarize
            )
        }
    }

    @ViewBuilder
    private var reportsActivityGroup: some View {
        SettingsRowGroup(
            "Your activity",
            icon: "chart.bar.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Activity counts are local only and never leave your Mac."
        ) {
            SettingsRow.status(
                "Reports opened",
                systemImage: "eye",
                value: "\(reportsTelemetry.totalRuns())"
            )
            SettingsRow.status(
                "Files exported",
                systemImage: "square.and.arrow.up",
                value: "\(reportsTelemetry.totalExports())"
            )
        }
    }

    @ViewBuilder
    private var reportsResetGroup: some View {
        SettingsRowGroup(
            "Reset",
            icon: "arrow.counterclockwise.circle.fill",
            iconColor: CentmondTheme.Colors.accent
        ) {
            SettingsRow.action(
                "Reset activity counters",
                systemImage: "arrow.counterclockwise",
                help: "Clears run and export counts. Saved presets and files are not affected.",
                buttonLabel: "Reset\u{2026}",
                role: .destructive,
                action: { showResetReportsActivityConfirm = true }
            )
        }
    }

    // MARK: - Phase 9 — Data groups

    @ViewBuilder
    private var dataExportsGroup: some View {
        SettingsRowGroup(
            "Export",
            icon: "square.and.arrow.up.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "All exports are written locally — nothing is uploaded anywhere."
        ) {
            SettingsRow.action(
                "Export net-worth history as CSV",
                systemImage: "chart.line.uptrend.xyaxis",
                help: "Columns: date, assets, liabilities, net_worth, source.",
                buttonLabel: "Export\u{2026}",
                action: {
                    let ok = NetWorthCSVExporter.exportSnapshots(context: modelContext)
                    automationActionMessage = ok ? "Exported net-worth snapshot history." : "No snapshots to export, or save was cancelled."
                }
            )
            SettingsRow.navigation(
                "Export a report",
                systemImage: "doc.richtext",
                help: "Opens the Reports screen. Use the toolbar Export button to choose format and range.",
                trailing: "Open Reports",
                action: { router.navigate(to: .reports) }
            )
        }
    }

    @ViewBuilder
    private var dataResetGroup: some View {
        SettingsRowGroup(
            "Reset",
            icon: "arrow.counterclockwise.circle.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Resets here are scoped — only the erase action below touches your ledger."
        ) {
            SettingsRow.action(
                "Replay onboarding",
                systemImage: "play.circle",
                help: "Show the welcome tour next time you launch Centmond.",
                buttonLabel: "Replay\u{2026}",
                action: { showResetOnboardingConfirm = true }
            )
        }
    }

    @ViewBuilder
    private var dangerZoneGroup: some View {
        SettingsRowGroup(
            "Danger zone",
            icon: "exclamationmark.octagon.fill",
            iconColor: CentmondTheme.Colors.negative,
            footer: "There is no undo and no backup. If you want a copy of your data, export first and try Reports \u{2192} CSV."
        ) {
            SettingsRow.action(
                "Erase all data",
                systemImage: "trash.slash.fill",
                help: "Wipes every account, transaction, budget, goal, subscription, and setting. Onboarding runs fresh on next launch.",
                buttonLabel: "Erase\u{2026}",
                buttonSystemImage: "trash",
                role: .destructive,
                action: {
                    eraseConfirmationPhrase = ""
                    showEraseAllSheet = true
                }
            )
        }
    }

    // MARK: - Phase 9 — About groups

    private var appVersionLabel: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    @ViewBuilder
    private var aboutVersionGroup: some View {
        SettingsRowGroup(
            "Centmond",
            icon: "info.circle.fill",
            iconColor: CentmondTheme.Colors.accent,
            footer: "Your personal finance command center. Built on SwiftData + on-device AI."
        ) {
            SettingsRow.status(
                "Version",
                systemImage: "number",
                value: appVersionLabel
            )
        }
    }

    @ViewBuilder
    private var aboutShortcutsGroup: some View {
        SettingsRowGroup(
            "Keyboard shortcuts",
            icon: "keyboard.fill",
            iconColor: CentmondTheme.Colors.accent
        ) {
            SettingsRow.status("Command palette", systemImage: "command", value: "\u{2318}K")
            SettingsRow.status("New transaction", systemImage: "plus.circle", value: "\u{2318}N")
            SettingsRow.status("Toggle inspector", systemImage: "sidebar.right", value: "\u{2318}I")
            SettingsRow.status("Navigate screens", systemImage: "arrow.up.arrow.down", value: "\u{2318}1\u{2013}9")
        }
    }
}
