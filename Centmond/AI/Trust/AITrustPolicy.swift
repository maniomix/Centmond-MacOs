import Foundation

// ============================================================
// MARK: - AI Trust Policy
// ============================================================
//
// Core types for the trust layer:
//   - TrustLevel — auto / confirm / neverAuto
//   - RiskScore  — 0.0-1.0 continuous risk assessment
//   - TrustDecision — the full result of evaluating one action
//   - RiskAssessment — financial risk signals for an action
//   - AIUserTrustPreferences — user-configurable trust settings
//
// macOS Centmond: Decimal amounts instead of cents (Int).
// AssistantMode enum defined here; full extension in AIAssistantModes.swift.
//
// ============================================================

// MARK: - Assistant Mode

/// The assistant's operating mode, chosen by the user.
enum AssistantMode: String, Codable, CaseIterable, Identifiable {
    case advisor    = "advisor"
    case assistant  = "assistant"
    case autopilot  = "autopilot"
    case cfo        = "cfo"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .advisor:   return "Advisor"
        case .assistant:  return "Assistant"
        case .autopilot:  return "Autopilot"
        case .cfo:        return "CFO"
        }
    }

    var titleFarsi: String {
        switch self {
        case .advisor:   return "مشاور"
        case .assistant:  return "دستیار"
        case .autopilot:  return "خودکار"
        case .cfo:        return "مدیرمالی"
        }
    }
}

// MARK: - Trust Level

/// Three-tier trust classification for any AI action.
enum AITrustLevel: String, Codable, CaseIterable, Identifiable {
    case auto      = "auto"
    case confirm   = "confirm"
    case neverAuto = "neverAuto"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:      return "Auto-execute"
        case .confirm:   return "Ask first"
        case .neverAuto: return "Block"
        }
    }

    var labelFarsi: String {
        switch self {
        case .auto:      return "اجرای خودکار"
        case .confirm:   return "تأیید بگیر"
        case .neverAuto: return "مسدود"
        }
    }

    var icon: String {
        switch self {
        case .auto:      return "bolt.fill"
        case .confirm:   return "hand.raised.fill"
        case .neverAuto: return "xmark.shield.fill"
        }
    }

    var severity: Int {
        switch self {
        case .auto:      return 0
        case .confirm:   return 1
        case .neverAuto: return 2
        }
    }

    func stricter(than other: AITrustLevel) -> AITrustLevel {
        self.severity >= other.severity ? self : other
    }
}

// MARK: - Risk Score

struct RiskScore: Comparable, Equatable {
    let value: Double
    let factors: [RiskFactor]

    static func == (lhs: RiskScore, rhs: RiskScore) -> Bool {
        lhs.value == rhs.value
    }

    static func < (lhs: RiskScore, rhs: RiskScore) -> Bool {
        lhs.value < rhs.value
    }

    static let zero = RiskScore(value: 0, factors: [])

    var level: RiskLevel {
        switch value {
        case ..<0.15:    return .none
        case ..<0.35:    return .low
        case ..<0.60:    return .medium
        case ..<0.80:    return .high
        default:         return .critical
        }
    }

    enum RiskLevel: String, Codable, Comparable {
        case none     = "none"
        case low      = "low"
        case medium   = "medium"
        case high     = "high"
        case critical = "critical"

        static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
            lhs.order < rhs.order
        }

        private var order: Int {
            switch self {
            case .none: return 0
            case .low: return 1
            case .medium: return 2
            case .high: return 3
            case .critical: return 4
            }
        }
    }
}

struct RiskFactor: Codable {
    let name: String
    let weight: Double
    let description: String
}

// MARK: - Trust Decision

struct TrustDecision: Identifiable {
    let id: UUID
    let actionType: AIAction.ActionType
    let level: AITrustLevel
    let reason: String
    let riskScore: RiskScore
    let confidenceUsed: Double
    let preferenceInfluenced: Bool
    let blockMessage: String?

    var summary: String {
        let prefix = level == .neverAuto ? "BLOCKED" : level == .confirm ? "CONFIRM" : "AUTO"
        return "\(prefix) \(actionType.rawValue): \(level.rawValue) — \(reason)"
    }
}

// MARK: - Risk Assessment

struct RiskAssessment {
    let amount: Double?
    let isDestructive: Bool
    let affectsBalance: Bool
    let affectsMultipleRecords: Bool
    let affectsLongTermPlanning: Bool
    let isRecurringChange: Bool
    let isHighValueTarget: Bool

    static let empty = RiskAssessment(
        amount: nil,
        isDestructive: false,
        affectsBalance: false,
        affectsMultipleRecords: false,
        affectsLongTermPlanning: false,
        isRecurringChange: false,
        isHighValueTarget: false
    )
}

// MARK: - Classified Actions

struct TrustClassifiedActions {
    let auto: [(AIAction, TrustDecision)]
    let confirm: [(AIAction, TrustDecision)]
    let blocked: [(AIAction, TrustDecision)]

    var allDecisions: [TrustDecision] {
        auto.map(\.1) + confirm.map(\.1) + blocked.map(\.1)
    }
}

// MARK: - Action Group

enum AIActionGroup: String, Codable, CaseIterable, Identifiable {
    case transactions  = "transactions"
    case budgets       = "budgets"
    case goals         = "goals"
    case subscriptions = "subscriptions"
    case accounts      = "accounts"
    case analysis      = "analysis"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transactions:  return "Transactions"
        case .budgets:       return "Budgets"
        case .goals:         return "Goals"
        case .subscriptions: return "Subscriptions"
        case .accounts:      return "Accounts"
        case .analysis:      return "Analysis"
        }
    }

    var icon: String {
        switch self {
        case .transactions:  return "arrow.left.arrow.right"
        case .budgets:       return "chart.pie.fill"
        case .goals:         return "target"
        case .subscriptions: return "repeat"
        case .accounts:      return "banknote.fill"
        case .analysis:      return "chart.bar.fill"
        }
    }

    var defaultTrust: AITrustLevel {
        switch self {
        case .analysis: return .auto
        default:        return .confirm
        }
    }

    var actionTypes: [AIAction.ActionType] {
        switch self {
        case .transactions:
            return [.addTransaction, .editTransaction, .deleteTransaction,
                    .splitTransaction, .transfer,
                    .addRecurring, .editRecurring, .cancelRecurring]
        case .budgets:
            return [.setBudget, .adjustBudget, .setCategoryBudget]
        case .goals:
            return [.createGoal, .addContribution, .updateGoal]
        case .subscriptions:
            return [.addSubscription, .cancelSubscription]
        case .accounts:
            return [.updateBalance]
        case .analysis:
            return [.analyze, .compare, .forecast, .advice]
        }
    }

    static func group(for actionType: AIAction.ActionType) -> AIActionGroup {
        for group in AIActionGroup.allCases {
            if group.actionTypes.contains(actionType) { return group }
        }
        return .analysis
    }
}

// MARK: - User Trust Preferences

struct AIUserTrustPreferences: Codable, Equatable {

    var allowAutoCategorizaton: Bool = true
    var allowAutoTagging: Bool = true
    var allowAutoMerchantCleanup: Bool = true

    var requireConfirmBudgetChanges: Bool = true
    var requireConfirmRecurringSetup: Bool = true
    var requireConfirmGoalChanges: Bool = false

    var neverAutoDestructive: Bool = true
    var neverAutoLargeAmounts: Bool = true

    var largeAmountThreshold: Double = 200.0
    var veryLargeAmountThreshold: Double = 1000.0
    var minAutoConfidence: Double = 0.7

    // MARK: - Persistence

    private static let storageKey = "ai.userTrustPreferences"

    static func load() -> AIUserTrustPreferences {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let prefs = try? JSONDecoder().decode(AIUserTrustPreferences.self, from: data)
        else { return AIUserTrustPreferences() }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AIUserTrustPreferences.storageKey)
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
