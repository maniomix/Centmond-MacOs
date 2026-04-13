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
}

enum InspectorContext: Equatable {
    case none
    case transaction(UUID)
    case account(UUID)
    case budgetCategory(UUID)
    case goal(UUID)
    case subscription(UUID)
}

@Observable
final class AppRouter {
    var selectedScreen: Screen = .dashboard
    var inspectorContext: InspectorContext = .none
    var activeSheet: SheetType?
    var isInspectorVisible: Bool = false
    var reviewQueueCount: Int = 0
    var selectedMonth: Date = .now

    var selectedMonthStart: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: selectedMonth))!
    }

    var selectedMonthEnd: Date {
        Calendar.current.date(byAdding: .month, value: 1, to: selectedMonthStart)!
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

    func showSheet(_ sheet: SheetType) {
        activeSheet = sheet
    }

    func inspectTransaction(_ id: UUID) {
        inspectorContext = .transaction(id)
        isInspectorVisible = true
    }

    func inspectAccount(_ id: UUID) {
        inspectorContext = .account(id)
        isInspectorVisible = true
    }

    func inspectBudgetCategory(_ id: UUID) {
        inspectorContext = .budgetCategory(id)
        isInspectorVisible = true
    }

    func inspectGoal(_ id: UUID) {
        inspectorContext = .goal(id)
        isInspectorVisible = true
    }

    func inspectSubscription(_ id: UUID) {
        inspectorContext = .subscription(id)
        isInspectorVisible = true
    }
}
