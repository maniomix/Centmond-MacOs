import Foundation

// ============================================================
// MARK: - AI Intent Model
// ============================================================
//
// High-level intent types for user requests. Sits between
// raw user input and the action/parser/execution layer.
//
// Design principles:
//   - Coarse categories, not action types
//   - Ambiguity is first-class (multiple interpretations)
//   - Confidence + reason on every classification
//   - Clarification path built in
//
// ============================================================

// MARK: - Intent Type

/// High-level category of what the user wants to do.
/// Intentionally coarser than action types — one intent can map
/// to multiple possible action types depending on context.
enum IntentType: String, Codable, CaseIterable {
    case askQuestion             // "how much did I spend?", "what's my balance?"
    case addData                 // "add $50 lunch", "log income"
    case editData                // "change the amount to 30", "fix the category"
    case deleteData              // "delete the last transaction", "remove that"
    case analyze                 // "spending breakdown", "how am I doing?"
    case forecast                // "predict next month", "at this rate..."
    case compare                 // "compare to last month", "vs March"
    case plan                    // "set a better budget", "help me save"
    case automate                // "handle bills automatically", "set up recurring"
    case correctPreviousAction   // "no I meant 50", "undo", "cancel that"
    case reviewItems             // "clean up transactions", "fix categories"
    case monthlyClose            // "close this month", "month-end review"
    case onboarding              // "what can you do?", "help"
    case clarify                 // user is answering a previous clarification question

    /// Human-readable label for display/logging.
    var label: String {
        switch self {
        case .askQuestion:           return "Ask Question"
        case .addData:               return "Add Data"
        case .editData:              return "Edit Data"
        case .deleteData:            return "Delete Data"
        case .analyze:               return "Analyze"
        case .forecast:              return "Forecast"
        case .compare:               return "Compare"
        case .plan:                  return "Plan"
        case .automate:              return "Automate"
        case .correctPreviousAction: return "Correct / Undo"
        case .reviewItems:           return "Review Items"
        case .monthlyClose:          return "Monthly Close"
        case .onboarding:            return "Onboarding / Help"
        case .clarify:               return "Clarification Answer"
        }
    }

    /// Whether this intent typically requires data mutation.
    var isMutation: Bool {
        switch self {
        case .addData, .editData, .deleteData, .automate, .correctPreviousAction:
            return true
        case .askQuestion, .analyze, .forecast, .compare, .plan,
             .reviewItems, .monthlyClose, .onboarding, .clarify:
            return false
        }
    }
}

// MARK: - Data Domain

/// What area of the app the intent targets.
/// Used to decide which context to load for the LLM.
enum IntentDomain: String, Codable {
    case transactions
    case budget
    case goals
    case subscriptions
    case accounts
    case general      // cross-cutting or unclear
    case none         // no domain needed (greeting, help)
}

// MARK: - Interpretation

/// One possible reading of the user's message.
/// The classifier may produce several of these when ambiguity exists.
struct Interpretation: Identifiable {
    let id = UUID()
    let intentType: IntentType
    let domain: IntentDomain
    let confidence: Double         // 0.0–1.0
    let reason: String             // short explanation of why this interpretation
    let suggestedActionHint: String? // e.g. "add_transaction", "add_contribution" — optional hint for downstream

    init(intentType: IntentType, domain: IntentDomain, confidence: Double,
         reason: String, suggestedActionHint: String? = nil) {
        self.intentType = intentType
        self.domain = domain
        self.confidence = confidence
        self.reason = reason
        self.suggestedActionHint = suggestedActionHint
    }
}

// MARK: - Clarification Result

/// Returned when the classifier detects ambiguity or missing info.
struct ClarificationResult {
    let question: String                 // short, practical question for the user
    let interpretations: [Interpretation] // the competing readings, ranked by confidence
    let missingFields: [String]          // what's specifically missing (if applicable)

    /// Build a user-facing summary of options.
    var optionsSummary: String {
        let options = interpretations.prefix(4).map { interp -> String in
            switch (interp.intentType, interp.domain) {
            case (.addData, .transactions):  return "record a transaction"
            case (.addData, .goals):         return "contribute to a goal"
            case (.addData, .budget):        return "set a budget"
            case (.addData, .subscriptions): return "add a subscription"
            case (.editData, _):             return "edit existing data"
            case (.deleteData, _):           return "delete something"
            case (.plan, .budget):           return "plan your budget"
            case (.plan, _):                 return "plan ahead"
            case (.analyze, _):              return "analyze your spending"
            case (.reviewItems, _):          return "review and clean up"
            case (.monthlyClose, _):         return "do a monthly review"
            case (.automate, _):             return "set up automation"
            default:                         return interp.reason
            }
        }
        return options.joined(separator: ", ")
    }
}

// MARK: - Intent Classification

/// The full result of classifying a user message.
/// This is the primary output of the intent layer.
struct IntentClassification {

    /// The most likely interpretation.
    let primary: Interpretation

    /// Second-most-likely, if meaningfully different from primary.
    let secondary: Interpretation?

    /// All plausible interpretations, ranked by confidence.
    let allInterpretations: [Interpretation]

    /// Whether clarification is needed before proceeding.
    let clarificationNeeded: Bool

    /// The clarification to present, if needed.
    let clarification: ClarificationResult?

    /// Entities extracted from the message (amount, category, etc.).
    let extractedEntities: [String: String]

    /// Whether multiple distinct intents were detected (e.g. "add lunch and check budget").
    let isMultiIntent: Bool

    /// Which context to include for the LLM.
    let contextHint: ContextHint

    /// Hints for what context to load for the LLM prompt.
    enum ContextHint: String {
        case full
        case budgetOnly
        case transactionsOnly
        case goalsOnly
        case subscriptionsOnly
        case accountsOnly
        case minimal
        case none
    }

    // MARK: - Convenience

    /// Primary intent type (shorthand).
    var intentType: IntentType { primary.intentType }

    /// Primary confidence (shorthand).
    var confidence: Double { primary.confidence }

    /// Primary domain (shorthand).
    var domain: IntentDomain { primary.domain }

    /// The gap between primary and secondary confidence.
    /// Small gap = high ambiguity.
    var ambiguityGap: Double {
        guard let sec = secondary else { return primary.confidence }
        return primary.confidence - sec.confidence
    }

    /// Whether the primary interpretation is confident enough to act on.
    var isConfident: Bool {
        primary.confidence >= 0.6 && ambiguityGap >= 0.15
    }
}
