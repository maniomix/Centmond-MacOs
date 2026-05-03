import Foundation

// Phase 1 of the Settings redesign. This file is the single source of truth
// for every user-facing preference key in Centmond. Nothing consumes it yet —
// future phases (shell, search, deeplink, subpanes) build on top of this
// registry so there is exactly one list of keys, defaults, and domains.
//
// Rules going forward:
//  • Every new @AppStorage key MUST be declared here first, then referenced
//    from views/services via `SettingsKey.<name>.rawKey`.
//  • If a service already owns a `static let fooKey = "..."` (notification
//    schedulers, NetWorthHistoryService), the registry points AT that
//    constant instead of duplicating the string literal — the scheduler
//    stays the owner, the registry is just the catalog.
//  • `SettingsDomain` is the Phase 2 navigation taxonomy. Each key tags
//    exactly one domain so the left-pane list and search index can be
//    built mechanically.

// MARK: - Domain taxonomy

enum SettingsDomain: String, CaseIterable, Identifiable {
    case workspace      // locale, layout, behavior, haptics
    case account        // signed-in user, sync status, sign out, delete account
    case ai             // model, mode, ai notifications, memory
    case alerts         // subs + recurring + household reminders + forecast
    case automation     // recurring pipeline, net-worth snapshot, household auto-split
    case security       // app lock, passcode, lock timeout
    case reports        // default format, csv flags
    case data           // export, reset onboarding, danger zone
    case about          // version, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace:  return "Workspace"
        case .account:    return "Account"
        case .ai:         return "AI Assistant"
        case .alerts:     return "Alerts"
        case .automation: return "Automation"
        case .security:   return "Privacy & Security"
        case .reports:    return "Reports"
        case .data:       return "Data"
        case .about:      return "About"
        }
    }

    var icon: String {
        switch self {
        case .workspace:  return "slider.horizontal.3"
        case .account:    return "person.crop.circle.fill"
        case .ai:         return "brain.head.profile.fill"
        case .alerts:     return "bell.badge.fill"
        case .automation: return "gearshape.2.fill"
        case .security:   return "lock.shield.fill"
        case .reports:    return "doc.richtext.fill"
        case .data:       return "internaldrive.fill"
        case .about:      return "info.circle.fill"
        }
    }
}

// MARK: - Value kinds

enum SettingsValueKind {
    case bool(defaultValue: Bool)
    case int(defaultValue: Int)
    case double(defaultValue: Double)
    case string(defaultValue: String)
}

// MARK: - Registry entry

struct SettingsKey: Identifiable {
    let id: String            // stable internal id, used for search + deeplink
    let rawKey: String        // the UserDefaults key literal
    let domain: SettingsDomain
    let title: String         // human-readable label ("Default currency")
    let helpText: String?     // short caption shown under the row
    let kind: SettingsValueKind
    let owner: Owner          // who writes the key at runtime

    enum Owner {
        case settingsUI       // only the Settings screen touches it
        case service(String)  // a service reads/writes it (name for docs)
    }
}

// MARK: - Catalog

enum SettingsCatalog {

    // All keys in one flat list. Grouped by domain via comments for readability;
    // domain filtering is done at the call-site via `.filter { $0.domain == ... }`.
    static let all: [SettingsKey] = [

        // ── Workspace ───────────────────────────────────────────────────
        .init(id: "workspace.defaultCurrency",
              rawKey: "defaultCurrency",
              domain: .workspace,
              title: "Default currency",
              helpText: "Used everywhere amounts are formatted — dashboard, reports, exports.",
              kind: .string(defaultValue: "USD"),
              owner: .service("CurrencyFormatter, ReportScheduleService")),
        .init(id: "workspace.startOfWeek",
              rawKey: "startOfWeek",
              domain: .workspace,
              title: "Start of week",
              helpText: "Sunday = 1, Monday = 2. Drives every week-aware chart and date picker.",
              kind: .int(defaultValue: 1),
              owner: .service("ModernCalendarPicker")),
        .init(id: "workspace.tableDensity",
              rawKey: "tableDensity",
              domain: .workspace,
              title: "Table density",
              helpText: "Default or compact row height in transactions and reports.",
              kind: .string(defaultValue: "default"),
              owner: .service("TransactionsView")),
        .init(id: "workspace.sidebarIconOnly",
              rawKey: "sidebarIconOnly",
              domain: .workspace,
              title: "Compact sidebar",
              helpText: "Show icons only in the sidebar to reclaim horizontal space.",
              kind: .bool(defaultValue: false),
              owner: .service("SidebarView")),
        .init(id: "workspace.autoOpenInspector",
              rawKey: "autoOpenInspector",
              domain: .workspace,
              title: "Auto-open inspector on selection",
              helpText: "Opens the right-hand detail panel whenever you select a row.",
              kind: .bool(defaultValue: true),
              owner: .service("AppRouter")),
        .init(id: "workspace.themeMode",
              rawKey: "appearance.themeMode",
              domain: .workspace,
              title: "Appearance",
              helpText: "Light, Dark, or Black (pure #000 for OLED). Drives the whole app's color palette.",
              kind: .string(defaultValue: "dark"),
              owner: .service("Theme / CentmondTheme.Colors")),
        .init(id: "workspace.hapticsEnabled",
              rawKey: "hapticsEnabled",
              domain: .workspace,
              title: "Haptic feedback",
              helpText: "Subtle trackpad feedback on hover, selection, and actions. Requires a Force Touch trackpad.",
              kind: .bool(defaultValue: true),
              owner: .service("Haptics")),

        // ── AI Assistant ────────────────────────────────────────────────
        .init(id: "ai.morningNotification",
              rawKey: "ai.morningNotification",
              domain: .ai,
              title: "Morning insights",
              helpText: "A short daily digest pushed at 9am.",
              kind: .bool(defaultValue: false),
              owner: .service("AIInsightEngine")),
        .init(id: "ai.weeklyReview",
              rawKey: "ai.weeklyReview",
              domain: .ai,
              title: "Weekly review",
              helpText: "A Sunday-evening summary of spending, goals, and anomalies.",
              kind: .bool(defaultValue: false),
              owner: .service("AIInsightEngine")),
        .init(id: "ai.criticalPush",
              rawKey: "ai.criticalPush",
              domain: .ai,
              title: "Critical push",
              helpText: "Interrupts you only for high-severity findings (e.g. fraud-like activity, budget blown).",
              kind: .bool(defaultValue: true),
              owner: .service("AIInsightEngine")),
        .init(id: "ai.insightEnrichment",
              rawKey: "ai.insightEnrichment",
              domain: .ai,
              title: "AI advice polish",
              helpText: "Uses the on-device model to rewrite detector output into plain-English advice.",
              kind: .bool(defaultValue: false),
              owner: .service("AIInsightEngine")),
        .init(id: "ai.assistantMode",
              rawKey: "ai.assistantMode",
              domain: .ai,
              title: "Assistant mode",
              helpText: "Controls how chatty the assistant is and how confidently it takes actions on your behalf.",
              kind: .string(defaultValue: ""),
              owner: .service("AIAssistantModeManager")),
        .init(id: "ai.activeModel",
              rawKey: "ai.activeModel",
              domain: .ai,
              title: "Active model",
              helpText: "Which .gguf weights are loaded. Swap via the model picker.",
              kind: .string(defaultValue: "gemma-4-E4B-it-Q6_K.gguf"),
              owner: .service("AIManager")),
        .init(id: "ai.onboarding.completed",
              rawKey: "ai.onboarding.completed",
              domain: .ai,
              title: "AI onboarding complete",
              helpText: nil,
              kind: .bool(defaultValue: false),
              owner: .service("AIOnboarding")),

        // ── Alerts — Subscriptions ─────────────────────────────────────
        .init(id: "alerts.subs.master",
              rawKey: "subscriptionNotificationsEnabled",
              domain: .alerts,
              title: "Subscription alerts",
              helpText: "Master toggle — turning off cancels every pending alert.",
              kind: .bool(defaultValue: true),
              owner: .service("SubscriptionNotificationScheduler")),
        .init(id: "alerts.subs.trialLead",
              rawKey: "subscriptionTrialAlertDays",
              domain: .alerts,
              title: "Trial-ends lead time",
              helpText: "How many days before a free trial ends to notify you.",
              kind: .int(defaultValue: 2),
              owner: .service("SubscriptionNotificationScheduler")),
        .init(id: "alerts.subs.charge",
              rawKey: "subscriptionChargeAlertEnabled",
              domain: .alerts,
              title: "Charge tomorrow",
              helpText: "Notify the morning before a charge over the threshold lands.",
              kind: .bool(defaultValue: true),
              owner: .service("SubscriptionNotificationScheduler")),
        .init(id: "alerts.subs.chargeThreshold",
              rawKey: "subscriptionChargeAlertThreshold",
              domain: .alerts,
              title: "Charge alert threshold",
              helpText: "Skip charges under this amount so alerts stay rare.",
              kind: .double(defaultValue: 10),
              owner: .service("SubscriptionNotificationScheduler")),
        .init(id: "alerts.subs.priceHike",
              rawKey: "subscriptionPriceHikeAlertEnabled",
              domain: .alerts,
              title: "Price hikes",
              helpText: "Surface when a subscription bills more than the typical historical amount.",
              kind: .bool(defaultValue: true),
              owner: .service("SubscriptionNotificationScheduler")),
        .init(id: "alerts.subs.unused",
              rawKey: "subscriptionUnusedAlertEnabled",
              domain: .alerts,
              title: "Unused subscriptions",
              helpText: "Nudge after 60+ days without changes so you can consider cancelling.",
              kind: .bool(defaultValue: true),
              owner: .service("SubscriptionNotificationScheduler")),

        // ── Alerts — Recurring ─────────────────────────────────────────
        .init(id: "alerts.recurring.master",
              rawKey: "recurringNotificationsEnabled",
              domain: .alerts,
              title: "Recurring reminders",
              helpText: "Notify the day before a recurring expense is due.",
              kind: .bool(defaultValue: false),
              owner: .service("RecurringNotificationScheduler")),
        .init(id: "alerts.recurring.threshold",
              rawKey: "recurringNotificationsThreshold",
              domain: .alerts,
              title: "Recurring alert threshold",
              helpText: "Skip recurring charges below this amount so reminders stay meaningful.",
              kind: .double(defaultValue: 100),
              owner: .service("RecurringNotificationScheduler")),

        // ── Alerts — Forecast ──────────────────────────────────────────
        .init(id: "alerts.forecast.master",
              rawKey: "forecastAlertsEnabled",
              domain: .alerts,
              title: "Forecast alerts",
              helpText: "Notify when forecasting detects runway or cash-flow risk ahead.",
              kind: .bool(defaultValue: true),
              owner: .service("ForecastNotificationScheduler")),

        // ── Alerts — Household ─────────────────────────────────────────
        .init(id: "alerts.household.master",
              rawKey: "householdNotificationsEnabled",
              domain: .alerts,
              title: "Household insights",
              helpText: "Surface unsettled balances and attribution gaps as insights.",
              kind: .bool(defaultValue: true),
              owner: .service("HouseholdInsightDetectors")),
        .init(id: "alerts.household.unsettledDays",
              rawKey: "householdUnsettledReminderDays",
              domain: .alerts,
              title: "Unsettled reminder after",
              helpText: "Shares that stay unpaid past this many days surface as a household insight.",
              kind: .int(defaultValue: 30),
              owner: .service("HouseholdInsightDetectors")),

        // ── Automation — Recurring pipeline ────────────────────────────
        .init(id: "automation.recurring.detection",
              rawKey: "recurringDetectionEnabled",
              domain: .automation,
              title: "Auto-detect recurring transactions",
              helpText: "Scans your ledger for repeating patterns (Netflix, rent, utilities).",
              kind: .bool(defaultValue: true),
              owner: .service("RecurringDetector")),
        .init(id: "automation.recurring.autoConfirm",
              rawKey: "recurringAutoConfirmThreshold",
              domain: .automation,
              title: "Auto-add confidence",
              helpText: "Detected patterns at or above this score are added without asking.",
              kind: .double(defaultValue: 0.85),
              owner: .service("RecurringDetector")),
        .init(id: "automation.recurring.autoApproveDays",
              rawKey: "recurringAutoApproveDays",
              domain: .automation,
              title: "Auto-approve after",
              helpText: "Auto-created transactions sit in review for this many days, then quietly mark themselves reviewed. 0 = require manual approval.",
              kind: .int(defaultValue: 7),
              owner: .service("RecurringService")),
        .init(id: "automation.recurring.drift",
              rawKey: "recurringDriftEnabled",
              domain: .automation,
              title: "Auto-update template amount",
              helpText: "When prices change across 3 linked transactions, update the template amount to match.",
              kind: .bool(defaultValue: true),
              owner: .service("RecurringDriftService")),
        .init(id: "automation.recurring.driftThreshold",
              rawKey: "recurringDriftThreshold",
              domain: .automation,
              title: "Drift sensitivity",
              helpText: "Minimum percent change that counts as drift.",
              kind: .double(defaultValue: 0.10),
              owner: .service("RecurringDriftService")),
        .init(id: "automation.recurring.staleAutoPause",
              rawKey: "recurringStaleAutoPauseEnabled",
              domain: .automation,
              title: "Auto-pause stale templates",
              helpText: "Templates that miss too many expected cycles pause themselves.",
              kind: .bool(defaultValue: true),
              owner: .service("RecurringDriftService")),
        .init(id: "automation.recurring.staleMissCount",
              rawKey: "recurringStaleMissCount",
              domain: .automation,
              title: "Pause after missed cycles",
              helpText: "How many consecutive no-shows before a template auto-pauses.",
              kind: .int(defaultValue: 3),
              owner: .service("RecurringDriftService")),

        // ── Automation — Net worth snapshots ───────────────────────────
        .init(id: "automation.netWorth.autoSnapshot",
              rawKey: "netWorthAutoSnapshotEnabled",
              domain: .automation,
              title: "Daily net-worth snapshot",
              helpText: "Fires on launch, midnight, and when the app comes back to the foreground.",
              kind: .bool(defaultValue: true),
              owner: .service("NetWorthHistoryService")),
        .init(id: "automation.netWorth.backfillDays",
              rawKey: "netWorthBackfillDays",
              domain: .automation,
              title: "Backfill window",
              helpText: "How far back first-launch and rebuild reconstruct history. Capped at 5 years.",
              kind: .int(defaultValue: 365),
              owner: .service("NetWorthHistoryService")),

        // ── Automation — Household ─────────────────────────────────────
        .init(id: "automation.household.defaultPayer",
              rawKey: "householdDefaultPayerID",
              domain: .automation,
              title: "Default payer",
              helpText: "New manual transactions and AI-added expenses are attributed to this member unless overridden.",
              kind: .string(defaultValue: ""),
              owner: .service("NewTransactionSheet")),
        .init(id: "automation.household.autoSplit",
              rawKey: "householdAutoSplitNewExpenses",
              domain: .automation,
              title: "Auto-split new expenses",
              helpText: "Every new transaction with no explicit split gets equal ExpenseShare rows for every active member.",
              kind: .bool(defaultValue: false),
              owner: .service("NewTransactionSheet")),

        // ── Privacy & Security ─────────────────────────────────────────
        .init(id: "security.appLock",
              rawKey: "appLockEnabled",
              domain: .security,
              title: "Require passcode",
              helpText: "Centmond asks for a 4-digit passcode before unlocking your data.",
              kind: .bool(defaultValue: false),
              owner: .service("AppLockController")),
        .init(id: "security.passcode",
              rawKey: "appPasscode",
              domain: .security,
              title: "Passcode",
              helpText: "Stored locally on this Mac. Never transmitted.",
              kind: .string(defaultValue: ""),
              owner: .service("AppLockController")),
        .init(id: "security.lockOnSleep",
              rawKey: "lockOnSleep",
              domain: .security,
              title: "Lock when Mac sleeps",
              helpText: "Re-prompt for the passcode when the Mac wakes up.",
              kind: .bool(defaultValue: true),
              owner: .service("AppLockController")),
        .init(id: "security.lockTimeout",
              rawKey: "lockTimeoutMinutes",
              domain: .security,
              title: "Auto-lock after inactivity",
              helpText: "Minutes of idle before Centmond re-locks. 0 = never.",
              kind: .int(defaultValue: 5),
              owner: .service("AppLockController")),

        // ── Reports ────────────────────────────────────────────────────
        .init(id: "reports.defaultFormat",
              rawKey: "reports.defaultFormat",
              domain: .reports,
              title: "Default export format",
              helpText: "Which format the toolbar Export button picks when you don't override.",
              kind: .string(defaultValue: "pdf"),
              owner: .service("ReportExportSheet")),
        .init(id: "reports.csvIncludeRaw",
              rawKey: "reports.csvIncludeRawTransactions",
              domain: .reports,
              title: "CSV includes raw transactions",
              helpText: "Adds a second sheet with the full row-level breakdown.",
              kind: .bool(defaultValue: false),
              owner: .settingsUI),
        .init(id: "reports.autoSummarize",
              rawKey: "reports.autoSummarize",
              domain: .reports,
              title: "Auto-summarise reports",
              helpText: "Run the on-device model over each report to generate a cover-page narrative.",
              kind: .bool(defaultValue: false),
              owner: .settingsUI),

        // ── Data ───────────────────────────────────────────────────────
        .init(id: "data.hasCompletedOnboarding",
              rawKey: "hasCompletedOnboarding",
              domain: .data,
              title: "Onboarding complete",
              helpText: "Reset to walk through onboarding again.",
              kind: .bool(defaultValue: false),
              owner: .service("AppRouter, StoreNuke")),
        .init(id: "data.isProUnlocked",
              rawKey: "isProUnlocked",
              domain: .data,
              title: "Pro features unlocked",
              helpText: nil,
              kind: .bool(defaultValue: false),
              owner: .service("ProUpgradeSheet")),
    ]

    // MARK: - Lookups

    static func keys(in domain: SettingsDomain) -> [SettingsKey] {
        all.filter { $0.domain == domain }
    }

    static func key(id: String) -> SettingsKey? {
        all.first { $0.id == id }
    }

    /// Phase 2's search index: a flat `(key, haystack)` pair so the search
    /// field can score matches without re-stringifying on every keystroke.
    static func searchIndex() -> [(key: SettingsKey, haystack: String)] {
        all.map { k in
            let hay = [k.title, k.helpText ?? "", k.domain.title]
                .joined(separator: " ")
                .lowercased()
            return (k, hay)
        }
    }
}
