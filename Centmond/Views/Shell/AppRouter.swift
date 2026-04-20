import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    // AI
    case aiChat
    case aiPredictions

    // Core
    case dashboard
    case transactions
    case budget
    case accounts

    // Planning
    case goals
    case subscriptions
    case recurring
    case forecasting

    // Analysis
    case insights
    case netWorth
    case reports

    // Manage
    case reviewQueue
    case household

    // Settings
    case settings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aiChat: "AI Chat"
        case .aiPredictions: "AI Predictions"
        case .dashboard: "Dashboard"
        case .transactions: "Transactions"
        case .budget: "Budget"
        case .accounts: "Accounts"
        case .goals: "Goals"
        case .subscriptions: "Subscriptions"
        case .recurring: "Recurring"
        case .forecasting: "Forecasting"
        case .insights: "Insights"
        case .netWorth: "Net Worth"
        case .reports: "Reports"
        case .reviewQueue: "Review Queue"
        case .household: "Household"
        case .settings: "Settings"
        }
    }

    /// Screens that are still in beta. Surfaced as a small "BETA"
    /// capsule next to the sidebar row and a banner at the top of the
    /// screen body itself. Remove from this list once the screen
    /// stabilises.
    var isBeta: Bool {
        switch self {
        case .aiChat, .aiPredictions: return true
        default: return false
        }
    }

    var iconName: String {
        switch self {
        case .aiChat: "brain.head.profile.fill"
        case .aiPredictions: "chart.line.text.clipboard.fill"
        case .dashboard: "house.fill"
        case .transactions: "list.bullet.rectangle.fill"
        case .budget: "chart.pie.fill"
        case .accounts: "building.columns.fill"
        case .goals: "target"
        case .subscriptions: "arrow.triangle.2.circlepath"
        case .recurring: "repeat"
        case .forecasting: "chart.line.uptrend.xyaxis"
        case .insights: "lightbulb.fill"
        case .netWorth: "chart.bar.fill"
        case .reports: "doc.text.fill"
        case .reviewQueue: "tray.fill"
        case .household: "person.2.fill"
        case .settings: "gearshape.fill"
        }
    }

    var section: SidebarSection {
        switch self {
        case .aiChat, .aiPredictions:
            return .ai
        case .dashboard, .transactions, .budget, .accounts:
            return .core
        case .goals, .subscriptions, .recurring, .forecasting:
            return .planning
        case .insights, .netWorth, .reports:
            return .analysis
        case .reviewQueue, .household:
            return .manage
        case .settings:
            return .settings
        }
    }

    var requiresPro: Bool {
        switch self {
        case .goals, .forecasting, .netWorth, .reports, .household, .aiChat, .aiPredictions:
            true
        default:
            false
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case ai
    case core
    case planning
    case analysis
    case manage
    case settings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ai: "AI"
        case .core: "CORE"
        case .planning: "PLANNING"
        case .analysis: "ANALYSIS"
        case .manage: "MANAGE"
        case .settings: "SETTINGS"
        }
    }

    var screens: [Screen] {
        Screen.allCases.filter { $0.section == self }
    }
}

enum SheetType: Identifiable {
    case newTransaction
    case newTransfer
    case newAccount
    case newGoal
    case newSubscription
    case detectedSubscriptions
    case detectedRecurring
    case newBudgetCategory
    case newRecurring
    case importCSV
    case splitTransaction(Transaction)
    case proUpgrade
    case export
    case editAccount(Account)
    case editGoal(Goal)
    case editSubscription(Subscription)
    case editRecurring(RecurringTransaction)
    case budgetPlanner

    var id: String {
        switch self {
        case .newTransaction: "newTransaction"
        case .newTransfer: "newTransfer"
        case .newAccount: "newAccount"
        case .newGoal: "newGoal"
        case .newSubscription: "newSubscription"
        case .detectedSubscriptions: "detectedSubscriptions"
        case .detectedRecurring: "detectedRecurring"
        case .newBudgetCategory: "newBudgetCategory"
        case .newRecurring: "newRecurring"
        case .importCSV: "importCSV"
        case .splitTransaction: "splitTransaction"
        case .proUpgrade: "proUpgrade"
        case .export: "export"
        case .editAccount: "editAccount"
        case .editGoal: "editGoal"
        case .editSubscription: "editSubscription"
        case .editRecurring: "editRecurring"
        case .budgetPlanner: "budgetPlanner"
        }
    }

    var isCompact: Bool {
        switch self {
        case .newTransaction: true
        default: false
        }
    }

    /// Width the sheet container should render at. Individual sheets must NOT
    /// set their own `.frame(width:)` smaller or larger than this — that causes
    /// edge clipping inside the routed container (see DetectedSubscriptionsSheet bug).
    var preferredWidth: CGFloat {
        switch self {
        case .newTransaction: 360
        case .newBudgetCategory: 400
        case .detectedSubscriptions: 640
        case .detectedRecurring: 640
        default: CentmondTheme.Sizing.sheetWidth
        }
    }
}

enum InspectorContext: Equatable {
    case none
    case transaction(UUID)
    case account(UUID)
    case budgetCategory(UUID)
    case goal(UUID)
    case subscription(UUID)
}

extension Notification.Name {
    /// Posted by the Help → "Replay Welcome Tour" menu item. AppShell
    /// observes and calls `router.replayOnboarding()`. A notification is
    /// the cleanest shell-to-router handoff because menu commands live in
    /// `CentmondApp` (the Scene) and can't reach the `@State` router that
    /// AppShell owns.
    static let replayOnboarding = Notification.Name("centmond.replayOnboarding")
}

@Observable
final class AppRouter {
    var selectedScreen: Screen = .dashboard
    var inspectorContext: InspectorContext = .none
    var activeSheet: SheetType?
    var isInspectorVisible: Bool = false
    var reviewQueueCount: Int = 0

    /// Drives the onboarding overlay in `AppShell`. Not persisted — the
    /// persistent flag is `UserDefaults["hasCompletedOnboarding"]`. This
    /// Observable var exists so the overlay can be shown/hidden during a
    /// single session (first launch + replay from Settings).
    var isOnboardingVisible: Bool = false
    var selectedMonth: Date = .now {
        didSet { recomputeMonthBounds() }
    }

    /// Cached month bounds. Views read these inside filter predicates that run
    /// per-transaction; without caching, each access re-ran `Calendar.date(...)`
    /// for every element of a @Query array. With a few-hundred-row array and
    /// ~10 month-filtered properties on the Dashboard, that was thousands of
    /// calendar allocations per month-nav — felt as lag when months had data.
    private(set) var selectedMonthStart: Date
    private(set) var selectedMonthEnd: Date

    init() {
        let now = Date.now
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        self.selectedMonthStart = start
        self.selectedMonthEnd = cal.date(byAdding: .month, value: 1, to: start)!
    }

    private func recomputeMonthBounds() {
        let cal = Calendar.current
        selectedMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: selectedMonth))!
        selectedMonthEnd = cal.date(byAdding: .month, value: 1, to: selectedMonthStart)!
    }

    var isCurrentMonth: Bool {
        Calendar.current.isDate(selectedMonth, equalTo: .now, toGranularity: .month)
    }

    func navigateMonth(by offset: Int) {
        selectedMonth = Calendar.current.date(byAdding: .month, value: offset, to: selectedMonth)!
    }

    func jumpToCurrentMonth() {
        selectedMonth = .now
    }

    /// Inspector hides on full-width screens like Dashboard
    var shouldShowInspector: Bool {
        guard isInspectorVisible else { return false }
        switch selectedScreen {
        case .dashboard, .settings, .aiChat, .aiPredictions:
            return false
        default:
            return true
        }
    }

    func navigate(to screen: Screen) {
        selectedScreen = screen
        inspectorContext = .none
    }

    /// Route an insight `Deeplink` to the right screen. Entity IDs inside the
    /// deeplink are ignored at this layer — the target screen's list resolves
    /// them itself once navigated to. If that changes (per-entity inspector
    /// focus, sheet presentation), extend this switch rather than teach each
    /// caller about the mapping.
    func follow(_ deeplink: AIInsight.Deeplink) {
        let screen: Screen
        switch deeplink {
        case .dashboard:        screen = .dashboard
        case .budgets:          screen = .budget
        case .subscriptions:    screen = .subscriptions
        case .goals:            screen = .goals
        case .recurring:        screen = .recurring
        case .transactions:     screen = .transactions
        case .cashflow:         screen = .forecasting
        case .netWorth:         screen = .netWorth
        }
        navigate(to: screen)
    }

    func showSheet(_ sheet: SheetType) {
        activeSheet = sheet
    }

    // MARK: - Onboarding

    /// UserDefaults keys for onboarding state. Kept as plain `UserDefaults`
    /// reads (not @AppStorage) because AppRouter is an @Observable class,
    /// not a View — property wrappers that depend on DynamicProperty won't
    /// hook in here. Views that need live updates read the @AppStorage
    /// binding themselves; AppRouter just reads/writes the canonical value.
    static let onboardingCompletedKey = "hasCompletedOnboarding"
    static let onboardingCompletedAtKey = "onboardingCompletedAt"
    static let onboardingSkippedAtStepKey = "onboardingSkippedAtStep"
    static let onboardingReplayCountKey = "onboardingReplayCount"

    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
    }

    /// Call from AppShell on first launch. Presents the overlay when the
    /// user hasn't completed (or skipped) onboarding yet AND the store is
    /// empty — returning users with data never see it.
    func presentOnboardingIfNeeded(isEmpty: Bool) {
        guard !hasCompletedOnboarding, isEmpty else { return }
        isOnboardingVisible = true
    }

    /// Manual replay from Settings / Help menu. Does not touch any data,
    /// just re-shows the overlay. Does NOT flip `hasCompletedOnboarding`
    /// back to false — we count replays separately so we can tell the
    /// difference between "first-timer quit mid-flow" and "returning user
    /// opened the tour again."
    func replayOnboarding() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: Self.onboardingReplayCountKey) + 1,
                     forKey: Self.onboardingReplayCountKey)
        isOnboardingVisible = true
    }

    /// Called by the overlay on Skip, Finish, or Esc.
    func completeOnboarding(skipped: Bool, atStep step: Int) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.onboardingCompletedKey)
        // Record the first-time completion timestamp only if not already
        // set; replays don't overwrite so we keep the earliest landmark.
        if defaults.object(forKey: Self.onboardingCompletedAtKey) == nil {
            defaults.set(Date.now, forKey: Self.onboardingCompletedAtKey)
        }
        if skipped {
            defaults.set(step, forKey: Self.onboardingSkippedAtStepKey)
        } else {
            defaults.removeObject(forKey: Self.onboardingSkippedAtStepKey)
        }
        isOnboardingVisible = false
    }

    /// Read the user's "auto-open inspector on click" preference.
    /// When false, `inspect*` still sets the context (so the existing
    /// inspector shows the new target if already open) but doesn't
    /// force the inspector panel open for a fresh click.
    private var shouldAutoOpenInspector: Bool {
        UserDefaults.standard.object(forKey: "autoOpenInspector") as? Bool ?? true
    }

    func inspectTransaction(_ id: UUID) {
        inspectorContext = .transaction(id)
        if shouldAutoOpenInspector { isInspectorVisible = true }
    }

    func inspectAccount(_ id: UUID) {
        inspectorContext = .account(id)
        if shouldAutoOpenInspector { isInspectorVisible = true }
    }

    func inspectBudgetCategory(_ id: UUID) {
        inspectorContext = .budgetCategory(id)
        if shouldAutoOpenInspector { isInspectorVisible = true }
    }

    func inspectGoal(_ id: UUID) {
        inspectorContext = .goal(id)
        if shouldAutoOpenInspector { isInspectorVisible = true }
    }

    func inspectSubscription(_ id: UUID) {
        inspectorContext = .subscription(id)
        if shouldAutoOpenInspector { isInspectorVisible = true }
    }
}
