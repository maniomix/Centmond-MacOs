import Foundation

// ============================================================
// MARK: - AI Audit Log
// ============================================================
//
// Records the full lifecycle of every AI interaction:
// prompt -> intent -> actions -> confirmation -> execution -> outcome.
//
// Provides transparency, debugging, and trust-building.
// Persisted to UserDefaults so it survives app restarts.
//
// macOS Centmond: @Observable instead of ObservableObject,
// amounts in dollars (Double) instead of cents (Int).
//
// ============================================================

/// A single audit entry capturing one complete AI interaction.
struct AIAuditEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date

    // Input
    let userMessage: String
    let detectedIntent: String
    let intentConfidence: Double
    let isMultiIntent: Bool

    // Processing
    let contextHint: String
    let clarificationNeeded: Bool
    let clarificationReason: String?

    // Output
    let aiResponseText: String
    let proposedActions: [AuditAction]

    // Trust & Confirmation
    let trustDecisions: [AuditTrustDecision]

    // Execution
    var executionResults: [AuditExecutionResult]
    var completedAt: Date?

    // Error
    var errorDescription: String?

    init(
        userMessage: String,
        detectedIntent: String,
        intentConfidence: Double,
        isMultiIntent: Bool = false,
        contextHint: String,
        clarificationNeeded: Bool = false,
        clarificationReason: String? = nil,
        aiResponseText: String = "",
        proposedActions: [AuditAction] = [],
        trustDecisions: [AuditTrustDecision] = [],
        executionResults: [AuditExecutionResult] = [],
        errorDescription: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.userMessage = userMessage
        self.detectedIntent = detectedIntent
        self.intentConfidence = intentConfidence
        self.isMultiIntent = isMultiIntent
        self.contextHint = contextHint
        self.clarificationNeeded = clarificationNeeded
        self.clarificationReason = clarificationReason
        self.aiResponseText = aiResponseText
        self.proposedActions = proposedActions
        self.trustDecisions = trustDecisions
        self.executionResults = executionResults
        self.completedAt = nil
        self.errorDescription = errorDescription
    }
}

/// Lightweight action representation for audit.
struct AuditAction: Codable {
    let type: String
    let summary: String
    let amount: Double?

    init(from action: AIAction) {
        self.type = action.type.rawValue
        self.summary = AuditAction.describeAction(action)
        self.amount = action.params.amount ?? action.params.budgetAmount ??
                      action.params.goalTarget ?? action.params.subscriptionAmount ??
                      action.params.contributionAmount
    }

    private static func describeAction(_ action: AIAction) -> String {
        let p = action.params
        switch action.type {
        case .addTransaction:
            let amount = p.amount.map { fmt($0) } ?? "?"
            return "Add \(p.transactionType ?? "expense"): \(amount) [\(p.category ?? "?")]"
        case .editTransaction:
            return "Edit transaction \(p.transactionId?.prefix(8) ?? "?")"
        case .deleteTransaction:
            return "Delete transaction \(p.transactionId?.prefix(8) ?? "?")"
        case .splitTransaction:
            let amount = p.amount.map { fmt($0) } ?? "?"
            return "Split \(amount) with \(p.splitWith ?? "?")"
        case .setBudget, .adjustBudget:
            let amount = p.budgetAmount.map { fmt($0) } ?? "?"
            return "Set budget to \(amount)"
        case .setCategoryBudget:
            let amount = p.budgetAmount.map { fmt($0) } ?? "?"
            return "Set \(p.budgetCategory ?? "?") budget to \(amount)"
        case .createGoal:
            return "Create goal: \(p.goalName ?? "?")"
        case .addContribution:
            let amount = p.contributionAmount.map { fmt($0) } ?? "?"
            return "Add \(amount) to \(p.goalName ?? "?")"
        case .updateGoal:
            return "Update goal: \(p.goalName ?? "?")"
        case .addSubscription:
            return "Add subscription: \(p.subscriptionName ?? "?")"
        case .cancelSubscription:
            return "Cancel: \(p.subscriptionName ?? "?")"
        case .updateBalance:
            return "Update balance: \(p.accountName ?? "?")"
        case .transfer:
            let amount = p.amount.map { fmt($0) } ?? "?"
            return "Transfer \(amount) from \(p.fromAccount ?? "?") to \(p.toAccount ?? "?")"
        case .addRecurring:
            return "Add recurring: \(p.recurringName ?? "?")"
        case .editRecurring:
            return "Edit recurring: \(p.recurringName ?? "?")"
        case .cancelRecurring:
            return "Cancel recurring: \(p.recurringName ?? "?")"
        case .analyze, .compare, .forecast, .advice:
            return "Analysis: \(action.type.rawValue)"
        case .assignMember:
            return "Assign member: \(p.memberName ?? "?")"
        }
    }

    private static func fmt(_ dollars: Double) -> String {
        String(format: "$%.2f", dollars)
    }
}

/// Trust decision for a single action.
struct AuditTrustDecision: Codable {
    let actionType: String
    let trustLevel: String
    let riskScore: Double
    let riskLevel: String
    let reason: String
    let confidenceUsed: Double
    let preferenceInfluenced: Bool
    let userDecision: String?

    init(
        actionType: String,
        trustLevel: String,
        riskScore: Double = 0,
        riskLevel: String = "none",
        reason: String = "",
        confidenceUsed: Double = 0,
        preferenceInfluenced: Bool = false,
        userDecision: String? = nil
    ) {
        self.actionType = actionType
        self.trustLevel = trustLevel
        self.riskScore = riskScore
        self.riskLevel = riskLevel
        self.reason = reason
        self.confidenceUsed = confidenceUsed
        self.preferenceInfluenced = preferenceInfluenced
        self.userDecision = userDecision
    }
}

/// Result of executing a single action.
struct AuditExecutionResult: Codable {
    let actionType: String
    let success: Bool
    let summary: String
    let undoable: Bool
}

// MARK: - Audit Log Manager

@MainActor @Observable
final class AIAuditLog {
    static let shared = AIAuditLog()

    private(set) var entries: [AIAuditEntry] = []

    private let maxEntries = 500
    private let storageKey = "ai.auditLog"

    private init() {
        load()
    }

    // MARK: - Recording

    func beginEntry(
        userMessage: String,
        classification: IntentClassification,
        clarification: ClarificationResult? = nil
    ) -> UUID {
        let entry = AIAuditEntry(
            userMessage: userMessage,
            detectedIntent: classification.intentType.rawValue,
            intentConfidence: classification.confidence,
            isMultiIntent: classification.isMultiIntent,
            contextHint: classification.contextHint.rawValue,
            clarificationNeeded: clarification != nil,
            clarificationReason: clarification?.missingFields.first
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        return entry.id
    }

    func recordResponse(entryId: UUID, responseText: String, actions: [AIAction]) {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return }
        let old = entries[idx]
        entries[idx] = AIAuditEntry(
            userMessage: old.userMessage,
            detectedIntent: old.detectedIntent,
            intentConfidence: old.intentConfidence,
            isMultiIntent: old.isMultiIntent,
            contextHint: old.contextHint,
            clarificationNeeded: old.clarificationNeeded,
            clarificationReason: old.clarificationReason,
            aiResponseText: responseText,
            proposedActions: actions.map { AuditAction(from: $0) },
            trustDecisions: old.trustDecisions,
            executionResults: old.executionResults,
            errorDescription: old.errorDescription
        )
    }

    func recordTrustDecisions(entryId: UUID, decisions: [AuditTrustDecision]) {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return }
        let old = entries[idx]
        entries[idx] = AIAuditEntry(
            userMessage: old.userMessage,
            detectedIntent: old.detectedIntent,
            intentConfidence: old.intentConfidence,
            isMultiIntent: old.isMultiIntent,
            contextHint: old.contextHint,
            clarificationNeeded: old.clarificationNeeded,
            clarificationReason: old.clarificationReason,
            aiResponseText: old.aiResponseText,
            proposedActions: old.proposedActions,
            trustDecisions: decisions,
            executionResults: old.executionResults,
            errorDescription: old.errorDescription
        )
    }

    func recordExecution(entryId: UUID, results: [AuditExecutionResult]) {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[idx].executionResults = results
        entries[idx].completedAt = Date()
        save()
    }

    func recordError(entryId: UUID, error: String) {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[idx].errorDescription = error
        entries[idx].completedAt = Date()
        save()
    }

    // MARK: - Queries

    func recent(_ count: Int = 20) -> [AIAuditEntry] {
        Array(entries.prefix(count))
    }

    var errorEntries: [AIAuditEntry] {
        entries.filter { $0.errorDescription != nil }
    }

    var successRate: Double {
        let recent = Array(entries.prefix(100))
        guard !recent.isEmpty else { return 1.0 }
        let successful = recent.filter { $0.errorDescription == nil && !$0.executionResults.isEmpty }
        return Double(successful.count) / Double(recent.count)
    }

    var blockedActions: [AuditTrustDecision] {
        entries.flatMap { $0.trustDecisions }.filter { $0.trustLevel == "neverAuto" }
    }

    var rejectedActions: [AuditTrustDecision] {
        entries.flatMap { $0.trustDecisions }.filter { $0.userDecision == "rejected" }
    }

    func clear() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([AIAuditEntry].self, from: data) {
            entries = saved
        }
    }
}
