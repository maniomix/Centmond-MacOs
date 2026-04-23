import Foundation
import SwiftUI
import SwiftData
import os

// ============================================================
// MARK: - AI-Native Onboarding
// ============================================================
//
// Structured, conversational onboarding that helps a new user
// set up their finances through AI-guided suggestions instead
// of heavy forms.
//
// Supports two paths:
//   - Quick Start -- minimal friction, starter setup
//   - Guided Setup -- fuller conversational walkthrough
//
// Produces a reviewable setup plan, then applies changes
// through ModelContext + AIActionExecutor.
//
// macOS Centmond: @Observable, ModelContext, Decimal amounts,
// no AccountManager/GoalManager singletons.
//
// ============================================================

private let logger = Logger(subsystem: "com.centmond", category: "AIOnboarding")

// MARK: - Onboarding Model

enum OnboardingPath: String, Codable {
    case quickStart  = "quick_start"
    case guided      = "guided"

    var title: String {
        switch self {
        case .quickStart: return "Quick Start"
        case .guided:     return "Guided Setup"
        }
    }

    var icon: String {
        switch self {
        case .quickStart: return "hare.fill"
        case .guided:     return "map.fill"
        }
    }

    var description: String {
        switch self {
        case .quickStart:
            return "Answer a few questions and get a practical starter setup in under a minute."
        case .guided:
            return "Walk through a fuller setup with AI help -- accounts, bills, budgets, goals, and preferences."
        }
    }
}

enum OnboardingStage: Int, Codable, CaseIterable, Comparable {
    case welcome            = 0
    case pathChoice         = 1
    case financialProfile   = 2
    case accountsSetup      = 3
    case recurringSetup     = 4
    case budgetSetup        = 5
    case goalsSetup         = 6
    case aiPreferences      = 7
    case review             = 8
    case applying           = 9
    case complete           = 10

    static func < (lhs: OnboardingStage, rhs: OnboardingStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .welcome:          return "Welcome"
        case .pathChoice:       return "Choose Path"
        case .financialProfile: return "Your Finances"
        case .accountsSetup:    return "Accounts"
        case .recurringSetup:   return "Bills & Subscriptions"
        case .budgetSetup:      return "Budget"
        case .goalsSetup:       return "Goals"
        case .aiPreferences:    return "AI Preferences"
        case .review:           return "Review"
        case .applying:         return "Setting Up"
        case .complete:         return "All Done"
        }
    }

    var icon: String {
        switch self {
        case .welcome:          return "hand.wave.fill"
        case .pathChoice:       return "arrow.triangle.branch"
        case .financialProfile: return "person.text.rectangle.fill"
        case .accountsSetup:    return "building.columns.fill"
        case .recurringSetup:   return "repeat"
        case .budgetSetup:      return "chart.bar.fill"
        case .goalsSetup:       return "target"
        case .aiPreferences:    return "dial.medium.fill"
        case .review:           return "checkmark.shield.fill"
        case .applying:         return "gearshape.2.fill"
        case .complete:         return "party.popper.fill"
        }
    }

    static var quickStartStages: [OnboardingStage] {
        [.welcome, .pathChoice, .financialProfile, .budgetSetup, .aiPreferences, .review, .applying, .complete]
    }

    static var guidedStages: [OnboardingStage] {
        OnboardingStage.allCases
    }
}

// MARK: - Setup Items

struct OnboardingSetupItem: Identifiable {
    let id = UUID()
    let category: SetupCategory
    let title: String
    let detail: String
    var icon: String
    var isIncluded: Bool = true

    var action: AIAction?
    var accountSpec: AccountSpec?
    var goalSpec: GoalSpec?

    enum SetupCategory: String {
        case account       = "Account"
        case budget        = "Budget"
        case categoryBudget = "Category Budget"
        case recurring     = "Recurring Bill"
        case subscription  = "Subscription"
        case goal          = "Goal"
        case aiPreference  = "AI Preference"
    }
}

struct AccountSpec {
    var name: String
    var typeName: String      // "bank", "savings", "creditCard"
    var balance: Double
    var currency: String = "USD"
}

struct GoalSpec {
    var name: String
    var targetAmount: Decimal
    var deadline: Date?
    var icon: String = "target"
}

// MARK: - Answers

struct OnboardingAnswers: Codable {
    var path: OnboardingPath = .quickStart
    var monthlyIncome: Double?
    var hasCheckingAccount: Bool?
    var hasSavingsAccount: Bool?
    var hasCreditCard: Bool?
    var checkingBalance: Double?
    var savingsBalance: Double?
    var creditCardBalance: Double?
    var recurringBills: [RecurringBillAnswer] = []
    var subscriptions: [SubscriptionAnswer] = []
    var monthlyBudget: Double?
    var wantAutoBudget: Bool?
    var goalName: String?
    var goalAmount: Double?
    var goalDeadline: String?
    var secondGoalName: String?
    var secondGoalAmount: Double?
    var selectedMode: AssistantMode = .assistant
    var wantsProactiveAlerts: Bool = true
    var prefersMoreConfirmation: Bool = false
}

struct RecurringBillAnswer: Codable, Identifiable {
    var id = UUID()
    var name: String
    var amount: Double
    var frequency: String
    var category: String
}

struct SubscriptionAnswer: Codable, Identifiable {
    var id = UUID()
    var name: String
    var amount: Double
    var frequency: String
}

// MARK: - Session

struct OnboardingSession: Codable {
    let id: UUID
    var path: OnboardingPath
    var currentStage: OnboardingStage
    var answers: OnboardingAnswers
    var isComplete: Bool
    let startedAt: Date
    var completedAt: Date?

    init(path: OnboardingPath = .quickStart) {
        self.id = UUID()
        self.path = path
        self.currentStage = .welcome
        self.answers = OnboardingAnswers(path: path)
        self.isComplete = false
        self.startedAt = Date()
    }

    var stages: [OnboardingStage] {
        path == .quickStart ? OnboardingStage.quickStartStages : OnboardingStage.guidedStages
    }

    var currentStageIndex: Int {
        stages.firstIndex(of: currentStage) ?? 0
    }

    var totalStages: Int { stages.count }

    var progress: Double {
        guard totalStages > 1 else { return 0 }
        return Double(currentStageIndex) / Double(totalStages - 1)
    }
}

// MARK: - Onboarding Engine

@MainActor @Observable
final class AIOnboardingEngine {
    static let shared = AIOnboardingEngine()

    var session: OnboardingSession = OnboardingSession()
    var setupPlan: [OnboardingSetupItem] = []
    var isApplying: Bool = false
    var applyProgress: Double = 0
    var applyError: String?

    var hasCompletedAIOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "ai.onboarding.completed") }
        set { UserDefaults.standard.set(newValue, forKey: "ai.onboarding.completed") }
    }

    private let storageKey = "ai.onboarding.session"

    private init() {
        loadSession()
    }

    // MARK: - Session Management

    func startSession(path: OnboardingPath) {
        session = OnboardingSession(path: path)
        session.answers.path = path
        session.currentStage = .financialProfile
        setupPlan = []
        saveSession()
    }

    func advanceToNextStage() {
        let stages = session.stages
        guard let idx = stages.firstIndex(of: session.currentStage),
              idx + 1 < stages.count else { return }
        session.currentStage = stages[idx + 1]
        saveSession()
    }

    func goToStage(_ stage: OnboardingStage) {
        session.currentStage = stage
        saveSession()
    }

    func goBack() {
        let stages = session.stages
        guard let idx = stages.firstIndex(of: session.currentStage), idx > 0 else { return }
        session.currentStage = stages[idx - 1]
        saveSession()
    }

    var canGoBack: Bool {
        let stages = session.stages
        guard let idx = stages.firstIndex(of: session.currentStage) else { return false }
        return idx > 0 && session.currentStage != .applying && session.currentStage != .complete
    }

    // MARK: - Setup Plan Generation

    func generateSetupPlan() {
        var items: [OnboardingSetupItem] = []
        let answers = session.answers

        // Accounts
        if session.path == .guided {
            if answers.hasCheckingAccount == true {
                items.append(OnboardingSetupItem(
                    category: .account,
                    title: "Checking Account",
                    detail: answers.checkingBalance.map { "Balance: \(fmtDollars($0))" } ?? "No balance set",
                    icon: "building.columns.fill",
                    accountSpec: AccountSpec(name: "Checking", typeName: "bank", balance: answers.checkingBalance ?? 0)
                ))
            }
            if answers.hasSavingsAccount == true {
                items.append(OnboardingSetupItem(
                    category: .account,
                    title: "Savings Account",
                    detail: answers.savingsBalance.map { "Balance: \(fmtDollars($0))" } ?? "No balance set",
                    icon: "banknote.fill",
                    accountSpec: AccountSpec(name: "Savings", typeName: "savings", balance: answers.savingsBalance ?? 0)
                ))
            }
            if answers.hasCreditCard == true {
                items.append(OnboardingSetupItem(
                    category: .account,
                    title: "Credit Card",
                    detail: answers.creditCardBalance.map { "Balance owed: \(fmtDollars($0))" } ?? "No balance set",
                    icon: "creditcard.fill",
                    accountSpec: AccountSpec(name: "Credit Card", typeName: "creditCard", balance: answers.creditCardBalance ?? 0)
                ))
            }
        } else {
            items.append(OnboardingSetupItem(
                category: .account,
                title: "Main Account",
                detail: "Your primary account",
                icon: "building.columns.fill",
                accountSpec: AccountSpec(name: "Main Account", typeName: "bank", balance: 0)
            ))
        }

        // Monthly budget
        let budgetAmount = answers.monthlyBudget ?? suggestBudget(from: answers)
        if budgetAmount > 0 {
            items.append(OnboardingSetupItem(
                category: .budget,
                title: "Monthly Budget: \(fmtDollars(budgetAmount))",
                detail: "Total spending limit for this month",
                icon: "chart.bar.fill",
                action: AIAction(
                    type: .setBudget,
                    params: .init(budgetAmount: budgetAmount, budgetMonth: "this_month")
                )
            ))
        }

        // Category budgets
        if answers.wantAutoBudget == true && budgetAmount > 0 {
            let catSuggestions = suggestCategoryBudgets(total: budgetAmount)
            for (cat, amount) in catSuggestions {
                items.append(OnboardingSetupItem(
                    category: .categoryBudget,
                    title: "\(cat.capitalized): \(fmtDollars(amount))",
                    detail: "Suggested \(cat) budget",
                    icon: categoryIcon(cat),
                    action: AIAction(
                        type: .setCategoryBudget,
                        params: .init(budgetAmount: amount, budgetCategory: cat)
                    )
                ))
            }
        }

        // Recurring bills
        for bill in answers.recurringBills {
            items.append(OnboardingSetupItem(
                category: .recurring,
                title: "\(bill.name): \(fmtDollars(bill.amount))/\(bill.frequency)",
                detail: "Recurring \(bill.category) bill",
                icon: "repeat",
                action: AIAction(
                    type: .addRecurring,
                    params: .init(
                        amount: bill.amount,
                        category: bill.category,
                        recurringName: bill.name,
                        recurringFrequency: bill.frequency
                    )
                )
            ))
        }

        // Subscriptions
        for sub in answers.subscriptions {
            items.append(OnboardingSetupItem(
                category: .subscription,
                title: "\(sub.name): \(fmtDollars(sub.amount))/\(sub.frequency)",
                detail: "Subscription",
                icon: "repeat.circle.fill",
                action: AIAction(
                    type: .addSubscription,
                    params: .init(
                        subscriptionName: sub.name,
                        subscriptionAmount: sub.amount,
                        subscriptionFrequency: sub.frequency
                    )
                )
            ))
        }

        // Goals
        if let goalName = answers.goalName, !goalName.isEmpty {
            items.append(OnboardingSetupItem(
                category: .goal,
                title: goalName,
                detail: answers.goalAmount.map { "Target: \(fmtDollars($0))" } ?? "No target set",
                icon: "target",
                goalSpec: GoalSpec(
                    name: goalName,
                    targetAmount: Decimal(answers.goalAmount ?? 0),
                    deadline: answers.goalDeadline.flatMap { ISO8601DateFormatter().date(from: $0) }
                )
            ))
        }
        if let goalName2 = answers.secondGoalName, !goalName2.isEmpty {
            items.append(OnboardingSetupItem(
                category: .goal,
                title: goalName2,
                detail: answers.secondGoalAmount.map { "Target: \(fmtDollars($0))" } ?? "No target set",
                icon: "star.fill",
                goalSpec: GoalSpec(
                    name: goalName2,
                    targetAmount: Decimal(answers.secondGoalAmount ?? 0)
                )
            ))
        }

        // AI Preferences
        items.append(OnboardingSetupItem(
            category: .aiPreference,
            title: "AI Mode: \(answers.selectedMode.title)",
            detail: answers.selectedMode.tagline,
            icon: answers.selectedMode.icon
        ))

        if !answers.wantsProactiveAlerts {
            items.append(OnboardingSetupItem(
                category: .aiPreference,
                title: "Proactive alerts: Off",
                detail: "AI won't generate proactive notifications",
                icon: "bell.slash.fill"
            ))
        }

        if answers.prefersMoreConfirmation {
            items.append(OnboardingSetupItem(
                category: .aiPreference,
                title: "Extra confirmation: On",
                detail: "AI will ask before most actions",
                icon: "shield.checkered"
            ))
        }

        setupPlan = items
    }

    // MARK: - Apply Setup Plan

    func applySetupPlan(context: ModelContext) async {
        let included = setupPlan.filter(\.isIncluded)
        guard !included.isEmpty else {
            completeOnboarding()
            return
        }

        isApplying = true
        applyProgress = 0
        applyError = nil

        let total = Double(included.count)
        var appliedCount = 0

        for item in included {
            // Accounts
            if let spec = item.accountSpec {
                let accountType: AccountType
                switch spec.typeName {
                case "savings":    accountType = .savings
                case "creditCard": accountType = .creditCard
                default:           accountType = .checking
                }
                let account = Account(
                    name: spec.name,
                    type: accountType,
                    currentBalance: Decimal(spec.balance)
                )
                context.insert(account)
                logger.info("Onboarding: Created account \(spec.name)")
            }

            // Goals
            if let spec = item.goalSpec {
                let goal = Goal(
                    name: spec.name,
                    icon: spec.icon,
                    targetAmount: spec.targetAmount,
                    targetDate: spec.deadline
                )
                context.insert(goal)
                logger.info("Onboarding: Created goal \(spec.name)")
            }

            // Actions (budgets, recurring, subscriptions)
            if let action = item.action {
                let result = await AIActionExecutor.execute(action, context: context)
                if !result.success {
                    logger.warning("Onboarding: Action failed -- \(result.summary)")
                }

                AIActionHistory.shared.record(
                    action: action,
                    result: result,
                    trustDecision: nil,
                    classification: nil,
                    groupId: session.id,
                    groupLabel: "Onboarding Setup",
                    isAutoExecuted: true
                )
            }

            // AI Preferences
            if item.category == .aiPreference {
                applyAIPreferences()
            }

            appliedCount += 1
            applyProgress = Double(appliedCount) / total
        }

        context.persist()

        isApplying = false
        completeOnboarding()
    }

    private func applyAIPreferences() {
        let answers = session.answers
        AIAssistantModeManager.shared.currentMode = answers.selectedMode

        if !answers.wantsProactiveAlerts && answers.selectedMode.proactiveInsights {
            AIAssistantModeManager.shared.currentMode = .advisor
        }

        if answers.prefersMoreConfirmation && answers.selectedMode != .advisor {
            AIAssistantModeManager.shared.currentMode = .advisor
        }
    }

    func completeOnboarding() {
        session.isComplete = true
        session.completedAt = Date()
        session.currentStage = .complete
        hasCompletedAIOnboarding = true
        saveSession()
    }

    func skipOnboarding() {
        hasCompletedAIOnboarding = true
    }

    // MARK: - Suggestion Helpers

    private func suggestBudget(from answers: OnboardingAnswers) -> Double {
        guard let income = answers.monthlyIncome, income > 0 else { return 0 }
        return income * 0.7
    }

    private func suggestCategoryBudgets(total: Double) -> [(String, Double)] {
        let allocations: [(String, Double)] = [
            ("Rent",       0.30),
            ("Groceries",  0.15),
            ("Bills",      0.10),
            ("Transport",  0.10),
            ("Dining",     0.10),
            ("Shopping",   0.08),
            ("Health",     0.05),
            ("Other",      0.12),
        ]
        return allocations.map { (cat, pct) in
            (cat, total * pct)
        }
    }

    private func categoryIcon(_ key: String) -> String {
        switch key.lowercased() {
        case "rent":       return "house.fill"
        case "groceries":  return "cart.fill"
        case "bills":      return "bolt.fill"
        case "transport":  return "car.fill"
        case "dining":     return "fork.knife"
        case "shopping":   return "bag.fill"
        case "health":     return "heart.fill"
        case "education":  return "book.fill"
        default:           return "ellipsis.circle.fill"
        }
    }

    // MARK: - Persistence

    private func saveSession() {
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadSession() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(OnboardingSession.self, from: data),
           !saved.isComplete {
            session = saved
        }
    }

    // MARK: - Helpers

    private func fmtDollars(_ value: Double) -> String {
        let isNeg = value < 0
        let str = String(format: "$%.2f", abs(value))
        return isNeg ? "-\(str)" : str
    }
}
