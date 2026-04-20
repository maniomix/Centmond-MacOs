import Foundation

// ============================================================
// MARK: - AI Data Models
// ============================================================
//
// Shared types for the AI layer: messages, actions, insights.
// These flow between AIManager -> AIActionParser -> AIActionExecutor.
//
// Centmond macOS port: amounts are Double (dollars) not Int (cents).
// The executor converts to Decimal when writing to SwiftData.
//
// ============================================================

// MARK: - Chat Message

struct AIMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    var actions: [AIAction]?

    enum Role: String, Codable, Equatable {
        case user
        case assistant
        case system
    }

    init(role: Role, content: String, actions: [AIAction]? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.actions = actions
    }
}

// MARK: - AI Action

struct AIAction: Identifiable, Equatable, Codable {
    let id: UUID
    let type: ActionType
    let params: ActionParams
    var status: ConfirmationStatus = .pending

    init(type: ActionType, params: ActionParams) {
        self.id = UUID()
        self.type = type
        self.params = params
    }

    enum ConfirmationStatus: String, Codable, Equatable {
        case pending
        case confirmed
        case rejected
        case executed
    }

    // -- Action Types --

    enum ActionType: String, Codable, Equatable {
        // Transactions
        case addTransaction = "add_transaction"
        case editTransaction = "edit_transaction"
        case deleteTransaction = "delete_transaction"
        case splitTransaction = "split_transaction"

        // Transfers
        case transfer = "transfer"

        // Recurring
        case addRecurring = "add_recurring"
        case editRecurring = "edit_recurring"
        case cancelRecurring = "cancel_recurring"

        // Budget
        case setBudget = "set_budget"
        case adjustBudget = "adjust_budget"
        case setCategoryBudget = "set_category_budget"

        // Goals
        case createGoal = "create_goal"
        case addContribution = "add_contribution"
        case updateGoal = "update_goal"

        // Subscriptions
        case addSubscription = "add_subscription"
        case cancelSubscription = "cancel_subscription"
        case pauseSubscription = "pause_subscription"
        case resumeSubscription = "resume_subscription"
        case detectSubscriptions = "detect_subscriptions"

        // Accounts
        case updateBalance = "update_balance"

        // Household
        case assignMember = "assign_member"

        // Analysis (no mutation)
        case analyze = "analyze"
        case compare = "compare"
        case forecast = "forecast"
        case advice = "advice"

        var isMutation: Bool {
            switch self {
            case .analyze, .compare, .forecast, .advice, .detectSubscriptions:
                return false
            default:
                return true
            }
        }

        var riskLevel: RiskLevel {
            switch self {
            case .analyze, .compare, .forecast, .advice, .detectSubscriptions:
                return .none
            case .addTransaction, .splitTransaction, .addRecurring,
                 .addSubscription, .addContribution, .createGoal,
                 .transfer, .assignMember,
                 .pauseSubscription, .resumeSubscription:
                return .low
            case .setBudget, .adjustBudget, .setCategoryBudget,
                 .updateGoal, .updateBalance, .editTransaction,
                 .editRecurring:
                return .medium
            case .deleteTransaction, .cancelSubscription,
                 .cancelRecurring:
                return .high
            }
        }

        enum RiskLevel: Int, Comparable {
            case none = 0
            case low = 1
            case medium = 2
            case high = 3

            static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }
    }

    // -- Action Parameters --
    //
    // Flat struct — each action type uses only its relevant fields.
    // Amounts are in DOLLARS (Double), not cents. The executor
    // converts to Decimal when writing to SwiftData.

    struct ActionParams: Codable, Equatable {
        // Transaction fields
        var amount: Double?
        var category: String?
        var note: String?
        var date: String?
        var transactionType: String?
        var transactionId: String?

        // Split fields
        var splitWith: String?
        var splitRatio: Double?

        // Budget fields
        var budgetAmount: Double?
        var budgetMonth: String?
        var budgetCategory: String?

        // Goal fields
        var goalName: String?
        var goalTarget: Double?
        var goalDeadline: String?
        var contributionAmount: Double?

        // Subscription fields
        var subscriptionName: String?
        var subscriptionAmount: Double?
        var subscriptionFrequency: String?

        // Account fields
        var accountName: String?
        var accountBalance: Double?

        // Transfer fields
        var fromAccount: String?
        var toAccount: String?

        // Recurring fields
        var recurringName: String?
        var recurringFrequency: String?
        var recurringEndDate: String?

        // Household fields
        var memberName: String?

        // Analysis fields
        var analysisText: String?
    }
}

// MARK: - AI Insight

struct AIInsight: Identifiable, Equatable {
    let id: UUID
    let kind: Kind
    let domain: Domain
    let severity: Severity
    let title: String
    let warning: String
    let advice: String?
    let cause: String?
    let timestamp: Date
    let expiresAt: Date?
    let dedupeKey: String
    var suggestedAction: AIAction?
    var deeplink: Deeplink?

    // Discriminator — what kind of signal this is.
    enum Kind: String, Codable, Equatable, CaseIterable {
        case budgetWarning
        case spendingAnomaly
        case savingsOpportunity
        case recurringDetected
        case weeklyReport
        case goalProgress
        case patternDetected
        case morningBriefing
        case subscriptionRenewal
        case subscriptionUnused
        case cashflowRisk
        case duplicateTransaction

        var domain: Domain {
            switch self {
            case .budgetWarning:        return .budget
            case .spendingAnomaly:      return .anomaly
            case .savingsOpportunity:   return .cashflow
            case .recurringDetected:    return .recurring
            case .weeklyReport,
                 .morningBriefing:      return .cashflow
            case .goalProgress:         return .goal
            case .patternDetected:      return .anomaly
            case .subscriptionRenewal,
                 .subscriptionUnused:   return .subscription
            case .cashflowRisk:         return .cashflow
            case .duplicateTransaction: return .duplicate
            }
        }
    }

    // Which area of the app the insight lives in. Drives filter chips + routing.
    enum Domain: String, Codable, Equatable, CaseIterable {
        case budget, subscription, goal, recurring, anomaly, cashflow, duplicate
    }

    // 4-tier: critical (act now) / warning (act soon) / watch (keep an eye) / positive.
    enum Severity: String, Codable, Equatable, Comparable {
        case critical
        case warning
        case watch
        case positive

        private var order: Int {
            switch self {
            case .critical: return 0
            case .warning:  return 1
            case .watch:    return 2
            case .positive: return 3
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.order < rhs.order }
    }

    // Where tapping the card sends the user.
    enum Deeplink: Equatable {
        case dashboard
        case budgets
        case subscriptions(UUID?)
        case goals(UUID?)
        case recurring(UUID?)
        case transactions(UUID?)
        case cashflow
        case netWorth
    }

    /// Verb-first label for the primary CTA button. Prefers the structured
    /// action type when one is attached; otherwise falls back to the deeplink
    /// destination; otherwise empty (no primary action — the card is
    /// informational and the user can only dismiss).
    var primaryActionLabel: String {
        if let action = suggestedAction {
            switch action.type {
            case .addContribution:                                     return "Add contribution"
            case .cancelSubscription:                                  return "Cancel subscription"
            case .pauseSubscription:                                   return "Pause subscription"
            case .resumeSubscription:                                  return "Resume subscription"
            case .setBudget, .adjustBudget, .setCategoryBudget:        return "Set budget"
            case .createGoal:                                          return "Create goal"
            case .updateGoal:                                          return "Update goal"
            case .transfer:                                            return "Transfer funds"
            case .addTransaction:                                      return "Add transaction"
            case .editTransaction:                                     return "Edit transaction"
            case .deleteTransaction:                                   return "Delete transaction"
            case .addRecurring:                                        return "Add recurring"
            case .editRecurring:                                       return "Edit recurring"
            case .cancelRecurring:                                     return "Cancel recurring"
            case .addSubscription:                                     return "Add subscription"
            case .detectSubscriptions:                                 return "Scan subscriptions"
            case .updateBalance:                                       return "Update balance"
            case .splitTransaction:                                    return "Split transaction"
            case .assignMember:                                        return "Assign"
            case .analyze, .compare, .forecast, .advice:               return "Open"
            }
        }
        switch deeplink {
        case .budgets:          return "Review budget"
        case .subscriptions:    return "Open subscription"
        case .goals:            return "Open goal"
        case .recurring:        return "Review recurring"
        case .transactions:     return "View transaction"
        case .cashflow:         return "See forecast"
        case .dashboard:        return "Open dashboard"
        case .netWorth:         return "Open net worth"
        case .none:             return ""
        }
    }

    init(
        kind: Kind,
        title: String,
        warning: String,
        severity: Severity = .watch,
        advice: String? = nil,
        cause: String? = nil,
        expiresAt: Date? = nil,
        dedupeKey: String? = nil,
        suggestedAction: AIAction? = nil,
        deeplink: Deeplink? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.domain = kind.domain
        self.title = title
        self.warning = warning
        self.severity = severity
        self.advice = advice
        self.cause = cause
        self.timestamp = Date()
        self.expiresAt = expiresAt
        self.dedupeKey = dedupeKey ?? "\(kind.rawValue):\(title)"
        self.suggestedAction = suggestedAction
        self.deeplink = deeplink
    }
}

// MARK: - AI Conversation

@Observable
final class AIConversation {
    var messages: [AIMessage] = []
    var pendingActions: [AIAction] = []

    func addUserMessage(_ text: String) {
        messages.append(AIMessage(role: .user, content: text))
    }

    func addAssistantMessage(_ text: String, actions: [AIAction]? = nil) {
        if let actions, !actions.isEmpty {
            for old in pendingActions where old.status == .pending {
                updateActionStatus(old.id, to: .rejected)
            }
        }
        messages.append(AIMessage(role: .assistant, content: text, actions: actions))
        if let actions {
            pendingActions = actions.filter { $0.status == .pending }
        }
    }

    func confirmAction(_ id: UUID) {
        updateActionStatus(id, to: .confirmed)
    }

    func rejectAction(_ id: UUID) {
        updateActionStatus(id, to: .rejected)
    }

    func markExecuted(_ id: UUID) {
        updateActionStatus(id, to: .executed)
    }

    func confirmAll() {
        for i in pendingActions.indices {
            if pendingActions[i].status == .pending {
                pendingActions[i].status = .confirmed
            }
        }
        syncActionsToMessages()
    }

    private func updateActionStatus(_ id: UUID, to status: AIAction.ConfirmationStatus) {
        if let i = pendingActions.firstIndex(where: { $0.id == id }) {
            pendingActions[i].status = status
        }
        syncActionsToMessages()
    }

    private func syncActionsToMessages() {
        for mi in messages.indices {
            guard var actions = messages[mi].actions else { continue }
            var changed = false
            for ai in actions.indices {
                if let pending = pendingActions.first(where: { $0.id == actions[ai].id }),
                   pending.status != actions[ai].status {
                    actions[ai].status = pending.status
                    changed = true
                }
            }
            if changed {
                messages[mi].actions = actions
            }
        }
    }

    /// Edit a user message and remove all messages after it (for re-generation)
    func editUserMessage(_ id: UUID, newContent: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id && $0.role == .user }) else { return }
        messages[idx].content = newContent
        // Remove all messages after the edited one
        if idx + 1 < messages.count {
            messages.removeSubrange((idx + 1)...)
        }
        pendingActions.removeAll()
    }

    func clear() {
        messages.removeAll()
        pendingActions.removeAll()
    }
}
