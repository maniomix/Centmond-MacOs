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
    let content: String
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
            case .analyze, .compare, .forecast, .advice:
                return false
            default:
                return true
            }
        }

        var riskLevel: RiskLevel {
            switch self {
            case .analyze, .compare, .forecast, .advice:
                return .none
            case .addTransaction, .splitTransaction, .addRecurring,
                 .addSubscription, .addContribution, .createGoal,
                 .transfer, .assignMember:
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
    let type: InsightType
    let title: String
    let body: String
    let severity: Severity
    let timestamp: Date
    var suggestedAction: AIAction?

    enum InsightType: String, Equatable {
        case budgetWarning
        case spendingAnomaly
        case savingsOpportunity
        case recurringDetected
        case weeklyReport
        case goalProgress
        case patternDetected
        case morningBriefing
    }

    enum Severity: String, Equatable {
        case info
        case warning
        case critical
        case positive
    }

    init(type: InsightType, title: String, body: String,
         severity: Severity = .info, suggestedAction: AIAction? = nil) {
        self.id = UUID()
        self.type = type
        self.title = title
        self.body = body
        self.severity = severity
        self.timestamp = Date()
        self.suggestedAction = suggestedAction
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

    func clear() {
        messages.removeAll()
        pendingActions.removeAll()
    }
}
