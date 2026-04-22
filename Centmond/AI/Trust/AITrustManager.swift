import Foundation

// ============================================================
// MARK: - AI Trust Manager
// ============================================================
//
// The single source of truth for AI action approval policy.
//
// Evaluates each proposed action against:
//   1. Base action risk rules (action type -> default level)
//   2. Financial risk assessment (amount, destructive, balance)
//   3. User trust preferences (toggles, thresholds)
//   4. Assistant mode (advisor/assistant/autopilot/cfo)
//   5. Model/intent confidence
//
// Returns a TrustDecision per action.
// Must be called BEFORE execution.
//
// macOS Centmond: @Observable instead of ObservableObject,
// amounts in dollars (Double) instead of cents (Int).
//
// ============================================================

@MainActor @Observable
final class AITrustManager {
    static let shared = AITrustManager()

    var preferences: AIUserTrustPreferences {
        didSet { preferences.save() }
    }

    private init() {
        self.preferences = AIUserTrustPreferences.load()
    }

    // MARK: - Public API

    func classify(
        _ actions: [AIAction],
        classification: IntentClassification? = nil,
        mode: AssistantMode = .assistant
    ) -> TrustClassifiedActions {
        let confidence = classification?.confidence ?? 0.5

        var auto: [(AIAction, TrustDecision)] = []
        var confirm: [(AIAction, TrustDecision)] = []
        var blocked: [(AIAction, TrustDecision)] = []

        for action in actions {
            let decision = evaluate(
                action: action,
                confidence: confidence,
                mode: mode
            )

            switch decision.level {
            case .auto:      auto.append((action, decision))
            case .confirm:   confirm.append((action, decision))
            case .neverAuto: blocked.append((action, decision))
            }
        }

        return TrustClassifiedActions(auto: auto, confirm: confirm, blocked: blocked)
    }

    func evaluate(
        action: AIAction,
        confidence: Double = 0.5,
        mode: AssistantMode = .assistant
    ) -> TrustDecision {
        let risk = assessRisk(action: action)
        let riskScore = computeRiskScore(action: action, risk: risk)
        let baseLevel = baseActionRule(for: action.type)
        let modeLevel = applyMode(base: baseLevel, action: action, mode: mode)
        let riskLevel = applyRiskEscalation(base: modeLevel, risk: risk, riskScore: riskScore)
        let confLevel = applyConfidenceGate(base: riskLevel, confidence: confidence)
        let (finalLevel, prefInfluenced) = applyUserPreferences(
            base: confLevel, action: action, risk: risk
        )

        let reason = buildReason(
            action: action, finalLevel: finalLevel, baseLevel: baseLevel,
            riskScore: riskScore, risk: risk, confidence: confidence,
            prefInfluenced: prefInfluenced, mode: mode
        )

        let blockMessage: String? = finalLevel == .neverAuto
            ? buildBlockMessage(action: action, risk: risk)
            : nil

        return TrustDecision(
            id: action.id,
            actionType: action.type,
            level: finalLevel,
            reason: reason,
            riskScore: riskScore,
            confidenceUsed: confidence,
            preferenceInfluenced: prefInfluenced,
            blockMessage: blockMessage
        )
    }

    // MARK: - Preference Management

    func updatePreferences(_ prefs: AIUserTrustPreferences) {
        preferences = prefs
    }

    func resetPreferences() {
        preferences = AIUserTrustPreferences()
    }

    // MARK: - Step 1: Risk Assessment

    private func assessRisk(action: AIAction) -> RiskAssessment {
        let p = action.params

        let amount = p.amount ?? p.budgetAmount ?? p.goalTarget ??
                     p.subscriptionAmount ?? p.contributionAmount ??
                     p.accountBalance

        let isDestructive = action.type == .deleteTransaction

        let affectsBalance: Bool = {
            switch action.type {
            case .updateBalance, .transfer: return true
            default: return false
            }
        }()

        let affectsMultiple = action.type == .splitTransaction

        let affectsLongTerm: Bool = {
            switch action.type {
            case .setBudget, .adjustBudget, .setCategoryBudget,
                 .createGoal, .updateGoal,
                 .addRecurring, .editRecurring:
                return true
            default: return false
            }
        }()

        let isRecurring: Bool = {
            switch action.type {
            case .addRecurring, .editRecurring, .cancelRecurring,
                 .addSubscription, .cancelSubscription:
                return true
            default: return false
            }
        }()

        let isHighValue = action.type == .updateBalance

        return RiskAssessment(
            amount: amount,
            isDestructive: isDestructive,
            affectsBalance: affectsBalance,
            affectsMultipleRecords: affectsMultiple,
            affectsLongTermPlanning: affectsLongTerm,
            isRecurringChange: isRecurring,
            isHighValueTarget: isHighValue
        )
    }

    // MARK: - Step 2: Risk Score

    private func computeRiskScore(action: AIAction, risk: RiskAssessment) -> RiskScore {
        var score: Double = 0
        var factors: [RiskFactor] = []

        let baseRisk: Double = {
            switch action.type.riskLevel {
            case .none:   return 0.0
            case .low:    return 0.15
            case .medium: return 0.35
            case .high:   return 0.60
            }
        }()
        if baseRisk > 0 {
            factors.append(RiskFactor(name: "action_type", weight: baseRisk,
                                      description: "Base risk for \(action.type.rawValue)"))
        }
        score += baseRisk

        if let dollars = risk.amount {
            let amountFactor: Double
            if dollars >= preferences.veryLargeAmountThreshold {
                amountFactor = 0.30
            } else if dollars >= preferences.largeAmountThreshold {
                amountFactor = 0.20
            } else if dollars >= 50 {
                amountFactor = 0.05
            } else {
                amountFactor = 0.0
            }
            if amountFactor > 0 {
                factors.append(RiskFactor(name: "large_amount", weight: amountFactor,
                                          description: String(format: "Amount $%.2f", dollars)))
                score += amountFactor
            }
        }

        if risk.isDestructive {
            let w = 0.25
            factors.append(RiskFactor(name: "destructive", weight: w, description: "Destructive action"))
            score += w
        }

        if risk.affectsBalance {
            let w = 0.15
            factors.append(RiskFactor(name: "balance_impact", weight: w, description: "Directly affects account balance"))
            score += w
        }

        if risk.affectsMultipleRecords {
            let w = 0.10
            factors.append(RiskFactor(name: "multi_record", weight: w, description: "Affects multiple records"))
            score += w
        }

        if risk.affectsLongTermPlanning {
            let w = 0.10
            factors.append(RiskFactor(name: "long_term", weight: w, description: "Affects long-term planning state"))
            score += w
        }

        if risk.isRecurringChange {
            let w = 0.10
            factors.append(RiskFactor(name: "recurring", weight: w, description: "Modifies recurring rules"))
            score += w
        }

        if risk.isHighValueTarget {
            let w = 0.15
            factors.append(RiskFactor(name: "high_value_target", weight: w, description: "High-value target (account)"))
            score += w
        }

        return RiskScore(value: min(score, 1.0), factors: factors)
    }

    // MARK: - Step 3: Base Action Rules

    private func baseActionRule(for type: AIAction.ActionType) -> AITrustLevel {
        switch type {
        case .analyze, .compare, .forecast, .advice, .detectSubscriptions, .simulatePayoff:
            return .auto
        case .addTransaction, .splitTransaction, .transfer,
             .editTransaction, .editRecurring,
             .setBudget, .adjustBudget, .setCategoryBudget,
             .createGoal, .addContribution, .updateGoal,
             .addSubscription, .addRecurring,
             .updateBalance,
             .cancelSubscription, .cancelRecurring,
             .pauseSubscription, .resumeSubscription,
             .assignMember:
            return .confirm
        case .deleteTransaction:
            return .neverAuto
        }
    }

    // MARK: - Step 4: Mode Adjustments

    private func applyMode(
        base: AITrustLevel,
        action: AIAction,
        mode: AssistantMode
    ) -> AITrustLevel {
        let risk = action.type.riskLevel

        switch mode {
        case .advisor:
            if base == .auto && risk != .none { return .confirm }
            return base
        case .assistant:
            return base
        case .autopilot:
            if base == .confirm {
                switch risk {
                case .none, .low, .medium: return .auto
                case .high: return .confirm
                }
            }
            return base
        case .cfo:
            if base == .confirm { return .auto }
            return base
        }
    }

    // MARK: - Step 5: Risk Escalation

    private func applyRiskEscalation(
        base: AITrustLevel,
        risk: RiskAssessment,
        riskScore: RiskScore
    ) -> AITrustLevel {
        if riskScore.level == .critical && base != .neverAuto {
            return .neverAuto
        }
        if riskScore.level >= .high && base == .auto {
            return .confirm
        }
        if let dollars = risk.amount {
            if dollars >= preferences.largeAmountThreshold && base == .auto {
                return .confirm
            }
        }
        if risk.affectsBalance, let dollars = risk.amount,
           dollars >= preferences.largeAmountThreshold, base == .auto {
            return .confirm
        }
        return base
    }

    // MARK: - Step 6: Confidence Gate

    private func applyConfidenceGate(base: AITrustLevel, confidence: Double) -> AITrustLevel {
        if base == .auto && confidence < preferences.minAutoConfidence {
            return .confirm
        }
        return base
    }

    // MARK: - Step 7: User Preferences

    private func applyUserPreferences(
        base: AITrustLevel,
        action: AIAction,
        risk: RiskAssessment
    ) -> (AITrustLevel, Bool) {
        var level = base
        var influenced = false

        if preferences.neverAutoDestructive && risk.isDestructive && level != .neverAuto {
            level = .neverAuto
            influenced = true
        }

        if preferences.neverAutoLargeAmounts,
           let dollars = risk.amount,
           dollars >= preferences.veryLargeAmountThreshold,
           level == .auto {
            level = .confirm
            influenced = true
        }

        if preferences.requireConfirmBudgetChanges {
            switch action.type {
            case .setBudget, .adjustBudget, .setCategoryBudget:
                if level == .auto { level = .confirm; influenced = true }
            default: break
            }
        }

        if preferences.requireConfirmRecurringSetup {
            switch action.type {
            case .addRecurring, .editRecurring, .cancelRecurring,
                 .addSubscription, .cancelSubscription:
                if level == .auto { level = .confirm; influenced = true }
            default: break
            }
        }

        if preferences.requireConfirmGoalChanges {
            switch action.type {
            case .createGoal, .addContribution, .updateGoal:
                if level == .auto { level = .confirm; influenced = true }
            default: break
            }
        }

        if level == .confirm && action.type == .editTransaction {
            let p = action.params
            let isCategoryOnly = p.category != nil
                && p.amount == nil && p.note == nil
                && p.date == nil && p.transactionType == nil
            if isCategoryOnly && preferences.allowAutoCategorizaton {
                level = .auto; influenced = true
            }

            let isTagOnly = p.note != nil
                && p.amount == nil && p.category == nil
                && p.date == nil && p.transactionType == nil
            if isTagOnly && preferences.allowAutoTagging {
                level = .auto; influenced = true
            }
        }

        if level == .confirm && action.type == .editTransaction && preferences.allowAutoMerchantCleanup {
            let p = action.params
            let isMerchantCleanup = p.note != nil
                && p.amount == nil && p.category == nil
                && p.date == nil && p.transactionType == nil
            if isMerchantCleanup {
                level = .auto; influenced = true
            }
        }

        return (level, influenced)
    }

    // MARK: - Reason Builder

    private func buildReason(
        action: AIAction, finalLevel: AITrustLevel, baseLevel: AITrustLevel,
        riskScore: RiskScore, risk: RiskAssessment, confidence: Double,
        prefInfluenced: Bool, mode: AssistantMode
    ) -> String {
        var parts: [String] = []
        parts.append("Action: \(action.type.rawValue)")
        parts.append("Risk: \(riskScore.level.rawValue) (\(String(format: "%.2f", riskScore.value)))")

        if finalLevel == .auto {
            if action.type.riskLevel == .none {
                parts.append("Read-only action, safe to auto-execute")
            } else if prefInfluenced && baseLevel == .confirm {
                parts.append("User preference allows auto for this low-risk edit")
            } else {
                parts.append("Mode '\(mode.rawValue)' allows auto for this risk level")
            }
        } else if finalLevel == .confirm {
            if prefInfluenced {
                parts.append("User preference requires confirmation")
            } else if confidence < preferences.minAutoConfidence {
                parts.append("Confidence \(String(format: "%.0f%%", confidence * 100)) below threshold")
            } else if risk.amount.map({ $0 >= preferences.largeAmountThreshold }) == true {
                parts.append("Large amount requires confirmation")
            } else {
                parts.append("Mutation action requires confirmation")
            }
        } else {
            if risk.isDestructive {
                parts.append("Destructive action blocked by safety policy")
            } else if riskScore.level == .critical {
                parts.append("Critical risk score blocked action")
            } else {
                parts.append("Action blocked by trust policy")
            }
        }

        return parts.joined(separator: " · ")
    }

    private func buildBlockMessage(action: AIAction, risk: RiskAssessment) -> String {
        if risk.isDestructive {
            return "This action (\(action.type.rawValue)) is destructive and cannot be auto-executed. Please perform it manually from the app."
        }
        if risk.isHighValueTarget {
            return "This action affects your account directly. For safety, it requires manual action."
        }
        return "This action was blocked by your trust policy. You can adjust trust settings if needed."
    }

    // MARK: - Convenience

    func trustLevel(for actionType: AIAction.ActionType) -> AITrustLevel {
        baseActionRule(for: actionType)
    }
}
