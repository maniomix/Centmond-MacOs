import SwiftUI
import KeyboardShortcuts
import UniformTypeIdentifiers

struct InAppSettingsView: View {
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
                    // Getting started (replay onboarding) — first card so
                    // returning users can find it quickly.
                    settingsCard(title: "Getting Started", icon: "sparkles", iconColor: CentmondTheme.Colors.accent) {
                        settingsRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Replay onboarding", systemImage: "play.circle")
                                Text("Walk through the tour again. Nothing in your data changes.")
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            }
                            Spacer()
                            Button("Start tour") {
                                router.replayOnboarding()
                            }
                            .buttonStyle(AccentChipButtonStyle())
                        }
                    }

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

                    // AI Assistant
                    aiSettingsCard

                    // Subscriptions notifications
                    subscriptionNotificationsCard

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
    }

    // MARK: - AI Settings Card

    private var aiSettingsCard: some View {
        settingsCard(title: "AI Assistant", icon: "brain.head.profile.fill", iconColor: DS.Colors.accent) {

            // ── Model Status ──
            settingsRow {
                Label("Model", systemImage: "cpu")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(aiStatusColor)
                        .frame(width: 7, height: 7)
                    Text(aiStatusLabel)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // ── Active Model ──
            Button {
                showModelPicker = true
            } label: {
                settingsRow {
                    Label("Active Model", systemImage: "sparkle")
                    Spacer()
                    HStack(spacing: 6) {
                        if let active = aiManager.availableModels.first(where: { $0.filename == AIManager.modelFilename }) {
                            Text(active.quantization)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            Text(active.formattedSize)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        } else {
                            Text(AIManager.modelFilename.replacingOccurrences(of: ".gguf", with: ""))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                }
            }
            .buttonStyle(.plain)

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // ── Mode ──
            settingsRow {
                Label("Assistant Mode", systemImage: "dial.medium.fill")
                Spacer()
                Picker("", selection: Binding(
                    get: { modeManager.currentMode },
                    set: { modeManager.currentMode = $0 }
                )) {
                    ForEach(AssistantMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // ── Notifications ──
            settingsRow {
                Label("Morning Insights", systemImage: "sun.max.fill")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { insightEngine.isMorningNotificationEnabled },
                    set: { insightEngine.isMorningNotificationEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            settingsRow {
                Label("Weekly Review", systemImage: "calendar.badge.clock")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { insightEngine.isWeeklyReviewEnabled },
                    set: { insightEngine.isWeeklyReviewEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            settingsRow {
                Label("Critical Push", systemImage: "exclamationmark.bubble.fill")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { insightEngine.isCriticalPushEnabled },
                    set: { insightEngine.isCriticalPushEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            settingsRow {
                Label("AI Advice Polish", systemImage: "wand.and.stars")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { insightEngine.isInsightEnrichmentEnabled },
                    set: { insightEngine.isInsightEnrichmentEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            MutedDetectorsSection()

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // ── AI Chat Shortcut ──
            settingsRow {
                Label("AI Chat Shortcut", systemImage: "keyboard")
                Spacer()
                KeyboardShortcuts.Recorder("", name: .toggleAIChat)
                    .frame(width: 160)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // ── Memory Info ──
            settingsRow {
                Label("AI Memory", systemImage: "brain")
                Spacer()
                Text("\(AIMemoryStore.shared.totalCount) items")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // ── Actions ──
            VStack(spacing: 10) {
                // Download / Import
                if !aiManager.isModelDownloaded {
                    HStack(spacing: 10) {
                        Button {
                            showModelPicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 14))
                                Text("Download Model")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showModelImporter = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 14))
                                Text("Import .gguf")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(DS.Colors.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(DS.Colors.accent.opacity(0.3), lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else if case .downloading(let progress, _) = aiManager.status {
                    HStack(spacing: 12) {
                        ProgressView(value: progress)
                            .tint(DS.Colors.accent)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .frame(width: 40)
                        Button("Cancel") {
                            aiManager.cancelDownload()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.danger)
                    }
                }

                // Danger zone
                if aiManager.isModelDownloaded {
                    HStack(spacing: 10) {
                        Button {
                            showModelImporter = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12))
                                Text("Replace Model")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(CentmondTheme.Colors.bgTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showDeleteModelConfirm = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                Text("Delete Model")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(DS.Colors.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(DS.Colors.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showResetMemoryConfirm = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "memories")
                                    .font(.system(size: 12))
                                Text("Reset Memory")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(DS.Colors.warning)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(DS.Colors.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
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

    // MARK: - Subscription Notifications card

    private var subscriptionNotificationsCard: some View {
        settingsCard(title: "Subscription Alerts", icon: "bell.badge.fill", iconColor: CentmondTheme.Colors.accent) {
            settingsRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Enable subscription alerts", systemImage: "power")
                    Text("Master toggle — turning off cancels every pending alert")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
                Spacer()
                Toggle("", isOn: $subNotifEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: subNotifEnabled) { _, newValue in
                        if newValue {
                            SubscriptionNotificationScheduler.requestAuthorization { _ in
                                SubscriptionNotificationScheduler.rescheduleAll(context: modelContext)
                            }
                        } else {
                            SubscriptionNotificationScheduler.rescheduleAll(context: modelContext)
                        }
                    }
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            settingsRow {
                Label("Trial-ends lead time", systemImage: "clock")
                Spacer()
                Picker("", selection: $subTrialLeadDays) {
                    Text("Same day").tag(0)
                    Text("1 day before").tag(1)
                    Text("2 days before").tag(2)
                    Text("3 days before").tag(3)
                    Text("7 days before").tag(7)
                }
                .labelsHidden()
                .frame(width: 160)
                .disabled(!subNotifEnabled)
                .onChange(of: subTrialLeadDays) { _, _ in
                    SubscriptionNotificationScheduler.rescheduleAll(context: modelContext)
                }
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            settingsRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Charge tomorrow", systemImage: "calendar.badge.exclamationmark")
                    Text("Notify the morning before a charge over the threshold")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
                Spacer()
                Toggle("", isOn: $subChargeEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!subNotifEnabled)
                    .onChange(of: subChargeEnabled) { _, _ in
                        SubscriptionNotificationScheduler.rescheduleAll(context: modelContext)
                    }
            }

            settingsRow {
                Label("Charge alert threshold", systemImage: "dollarsign.circle")
                Spacer()
                Picker("", selection: $subChargeThreshold) {
                    Text("Any amount").tag(0.0)
                    Text("$5+").tag(5.0)
                    Text("$10+").tag(10.0)
                    Text("$25+").tag(25.0)
                    Text("$50+").tag(50.0)
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(!subNotifEnabled || !subChargeEnabled)
                .onChange(of: subChargeThreshold) { _, _ in
                    SubscriptionNotificationScheduler.rescheduleAll(context: modelContext)
                }
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            settingsRow {
                Label("Price hikes", systemImage: "arrow.up.right.circle")
                Spacer()
                Toggle("", isOn: $subPriceHikeEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!subNotifEnabled)
                    .onChange(of: subPriceHikeEnabled) { _, _ in
                        SubscriptionNotificationScheduler.rescheduleAll(context: modelContext)
                    }
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            settingsRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Unused subscriptions", systemImage: "moon.zzz")
                    Text("Nudge after 60+ days without changes")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
                Spacer()
                Toggle("", isOn: $subUnusedEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!subNotifEnabled)
                    .onChange(of: subUnusedEnabled) { _, _ in
                        SubscriptionNotificationScheduler.rescheduleAll(context: modelContext)
                    }
            }
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
