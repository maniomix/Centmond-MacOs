import Foundation

// ============================================================
// MARK: - AI Clarification Engine
// ============================================================
//
// Two jobs:
//   1. PRE-LLM: Check if classified intent needs more info
//      before we spend a model call.
//   2. POST-PARSE: Validate parsed actions from LLM output.
//
// ============================================================

/// Failure taxonomy for structured error handling.
enum AIFailure {
    case lowConfidence(score: Double, rawInput: String)
    case missingData(fields: [String])
    case conflictingData(description: String)
    case unsafeAction(reason: String)
    case unsupportedAction(description: String)
    case malformedOutput(rawOutput: String)
    case modelUnavailable
    case contextTooLarge

    var userMessage: String {
        switch self {
        case .lowConfidence:
            return "I'm not sure I understood that correctly. Could you rephrase?"
        case .missingData(let fields):
            return "I need a bit more info: \(fields.joined(separator: ", "))."
        case .conflictingData(let desc):
            return "That seems contradictory — \(desc). Could you clarify?"
        case .unsafeAction(let reason):
            return "I can't do that automatically — \(reason)."
        case .unsupportedAction(let desc):
            return "I don't support that yet: \(desc)."
        case .malformedOutput:
            return "Something went wrong processing that. Let me try again — could you rephrase?"
        case .modelUnavailable:
            return "The AI model isn't loaded yet. Please wait for it to finish loading."
        case .contextTooLarge:
            return "There's too much data to process at once. Try a more specific request."
        }
    }

    var farsiMessage: String {
        switch self {
        case .lowConfidence:
            return "مطمئن نیستم درست متوجه شدم. میتونی دوباره بگی؟"
        case .missingData:
            return "یکم اطلاعات بیشتر لازم دارم."
        case .conflictingData:
            return "این یکم متناقض به نظر میاد. میتونی توضیح بدی؟"
        case .unsafeAction:
            return "این کار رو نمیتونم خودکار انجام بدم."
        case .unsupportedAction:
            return "فعلاً این قابلیت رو ندارم."
        case .malformedOutput:
            return "یه مشکلی پیش اومد. میتونی دوباره بگی؟"
        case .modelUnavailable:
            return "مدل هوش مصنوعی هنوز آماده نیست. لطفاً صبر کنید."
        case .contextTooLarge:
            return "اطلاعات زیادی هست. لطفاً درخواست دقیق‌تری بدید."
        }
    }
}

// ClarificationStyle is defined in AIMemory.swift (P8)

enum AIClarificationEngine {

    // MARK: - Pre-LLM Check

    static func check(
        classification: IntentClassification,
        rawInput: String
    ) -> ClarificationResult? {

        let lower = rawInput.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // TODO: P8 — Wire AIMemoryRetrieval.clarificationStyle
        let style: ClarificationStyle = .balanced

        // TODO: P8 — Wire AIAssistantModeManager.shared.currentMode

        // 1. Router-flagged ambiguity
        if classification.clarificationNeeded, let c = classification.clarification {
            return adaptClarification(c, style: style)
        }

        // 2. Too-vague input
        if isTooVague(lower) {
            let question: String
            switch style {
            case .concise:
                question = "What would you like me to do?"
            case .balanced:
                question = "I'd like to help! What would you like me to do? (e.g., add an expense, check your budget, analyze spending)"
            case .detailed:
                question = "I'd love to help! Could you tell me what you'd like? I can add expenses or income, check your budget, analyze spending patterns, manage goals, review subscriptions, and more."
            }
            return ClarificationResult(
                question: question,
                interpretations: classification.allInterpretations,
                missingFields: ["details"]
            )
        }

        // 3. Intent-specific field checks
        let entities = classification.extractedEntities

        switch classification.intentType {
        case .addData:
            return checkAddData(classification: classification, input: lower, entities: entities)
        case .editData:
            return checkEditData(input: lower)
        case .deleteData:
            return checkDeleteData(input: lower)
        case .automate:
            return checkAutomate(input: lower)
        case .plan:
            return checkPlan(input: lower)
        default:
            break
        }

        // 4. Very low confidence — only for truly empty/meaningless input.
        // The AI model should handle ambiguous requests, not canned responses.
        if classification.confidence < 0.1 {
            return ClarificationResult(
                question: "I'm not sure what you'd like me to do. Could you be more specific?",
                interpretations: classification.allInterpretations,
                missingFields: ["intent"]
            )
        }

        return nil
    }

    private static func adaptClarification(_ result: ClarificationResult, style: ClarificationStyle) -> ClarificationResult {
        switch style {
        case .concise:
            let shortened = result.question.count > 80
                ? String(result.question.prefix(77)) + "..."
                : result.question
            return ClarificationResult(
                question: shortened,
                interpretations: result.interpretations,
                missingFields: result.missingFields
            )
        case .balanced:
            return result
        case .detailed:
            guard !result.interpretations.isEmpty else { return result }
            let hints = result.interpretations.prefix(2).map { "- \($0.reason)" }.joined(separator: "\n")
            let enriched = result.question + "\n\nDid you mean:\n" + hints
            return ClarificationResult(
                question: enriched,
                interpretations: result.interpretations,
                missingFields: result.missingFields
            )
        }
    }

    // MARK: - Post-Parse Validation

    static func validateActions(_ actions: [AIAction]) -> AIFailure? {
        for action in actions {
            let p = action.params

            switch action.type {
            case .addTransaction, .splitTransaction:
                if p.amount == nil || p.amount == 0 {
                    return .missingData(fields: ["amount"])
                }
            case .setBudget, .adjustBudget:
                if p.budgetAmount == nil || p.budgetAmount == 0 {
                    return .missingData(fields: ["budget amount"])
                }
            case .createGoal:
                if p.goalName == nil || (p.goalName?.isEmpty ?? true) {
                    return .missingData(fields: ["goal name"])
                }
                if p.goalTarget == nil || p.goalTarget == 0 {
                    return .missingData(fields: ["goal target"])
                }
            case .addContribution:
                if p.goalName == nil { return .missingData(fields: ["goal name"]) }
                if p.contributionAmount == nil { return .missingData(fields: ["contribution amount"]) }
            case .deleteTransaction:
                if p.transactionId == nil { return .missingData(fields: ["transaction to delete"]) }
            case .editTransaction:
                if p.transactionId == nil { return .missingData(fields: ["transaction to edit"]) }
            case .addSubscription:
                if p.subscriptionName == nil { return .missingData(fields: ["subscription name"]) }
                if p.subscriptionAmount == nil { return .missingData(fields: ["subscription amount"]) }
            default:
                break
            }

            if let amount = p.amount, amount < 0 {
                return .conflictingData(description: "Amount can't be negative")
            }
            if let amount = p.amount, amount > 100_000_000 {
                return .conflictingData(description: "Amount seems unusually large (\(formatDollars(amount)))")
            }
        }

        return nil
    }

    // MARK: - Private Checks

    private static func isTooVague(_ input: String) -> Bool {
        let vaguePatterns = [
            "^(add something|add|اضافه کن)$",
            "^(do something|fix|fix this|درستش کن)$",
            "^(help me|کمکم کن)$",
            "^\\.$",
            "^[?؟]+$"
        ]
        for pattern in vaguePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil {
                return true
            }
        }
        return input.count < 3 && !input.isEmpty
    }

    private static func checkAddData(
        classification: IntentClassification,
        input: String,
        entities: [String: String]
    ) -> ClarificationResult? {
        let hasAmount = entities["amount"] != nil

        switch classification.domain {
        case .transactions:
            return checkTransactionFields(input: input, hasAmount: hasAmount)
        case .goals:
            return checkGoalFields(input: input, hasAmount: hasAmount)
        case .subscriptions:
            return checkSubscriptionFields(input: input, hasAmount: hasAmount)
        case .budget:
            if !hasAmount {
                return ClarificationResult(
                    question: "What would you like your budget to be?",
                    interpretations: classification.allInterpretations,
                    missingFields: ["budget amount"]
                )
            }
        default:
            break
        }
        return nil
    }

    private static func checkTransactionFields(input: String, hasAmount: Bool) -> ClarificationResult? {
        if !hasAmount {
            if containsCategory(input) {
                return ClarificationResult(
                    question: "How much was that?",
                    interpretations: [],
                    missingFields: ["amount"]
                )
            }
            if input.count < 15 {
                return ClarificationResult(
                    question: "What did you spend on, and how much was it?",
                    interpretations: [],
                    missingFields: ["amount", "description"]
                )
            }
        }

        let isSplit = input.contains("split") || input.contains("تقسیم") || input.contains("نصف")
        let hasPerson = input.contains("with") || input.contains("با")
        if isSplit && !hasPerson {
            return ClarificationResult(
                question: "Who do you want to split this with?",
                interpretations: [],
                missingFields: ["person"]
            )
        }
        return nil
    }

    private static func checkGoalFields(input: String, hasAmount: Bool) -> ClarificationResult? {
        let isCreation = input.contains("create") || input.contains("new") || input.contains("save for")
            || input.contains("بساز") || input.contains("ایجاد")
        if isCreation {
            let hasName = input.contains("for ") || input.contains("called ") || input.contains("برای") || input.contains("بنام")
            if !hasName && !hasAmount {
                return ClarificationResult(
                    question: "What's the goal for, and what's your target amount?",
                    interpretations: [],
                    missingFields: ["goal name", "target amount"]
                )
            }
        }
        if !hasAmount {
            return ClarificationResult(
                question: "How much do you want to add to your goal?",
                interpretations: [],
                missingFields: ["amount"]
            )
        }
        return nil
    }

    private static func checkSubscriptionFields(input: String, hasAmount: Bool) -> ClarificationResult? {
        let hasName = input.count > 20 || input.contains("netflix") || input.contains("spotify")
            || input.contains("اشتراک")
        if !hasName && !hasAmount {
            return ClarificationResult(
                question: "Which subscription, and how much per month?",
                interpretations: [],
                missingFields: ["subscription name", "amount"]
            )
        }
        return nil
    }

    private static func checkEditData(input: String) -> ClarificationResult? {
        if input.count < 20 && !input.contains("to ") && !input.contains("به ") {
            return ClarificationResult(
                question: "What would you like to change, and to what?",
                interpretations: [],
                missingFields: ["what to change"]
            )
        }
        return nil
    }

    private static func checkDeleteData(input: String) -> ClarificationResult? {
        let hasSpecifier = input.contains("last") || input.contains("آخری")
            || input.contains("today") || input.contains("امروز")
            || input.count > 30
        if !hasSpecifier {
            return ClarificationResult(
                question: "Which transaction do you want to delete? The most recent one?",
                interpretations: [],
                missingFields: ["which transaction"]
            )
        }
        return nil
    }

    private static func checkAutomate(input: String) -> ClarificationResult? {
        let hasSpecific = input.contains("recurring") || input.contains("subscription")
            || input.contains("bill") || input.contains("تکرار")
            || input.contains("اشتراک") || input.contains("قبض")
        if !hasSpecific {
            return ClarificationResult(
                question: "What would you like to automate? (e.g., recurring bills, subscription payments)",
                interpretations: [],
                missingFields: ["what to automate"]
            )
        }
        return nil
    }

    private static func checkPlan(input: String) -> ClarificationResult? {
        if input.count < 10 {
            return ClarificationResult(
                question: "What would you like to plan? (e.g., next month's budget, a savings strategy)",
                interpretations: [],
                missingFields: ["planning scope"]
            )
        }
        return nil
    }

    // MARK: - Helpers

    private static func containsCategory(_ input: String) -> Bool {
        let categoryKeywords = [
            "lunch", "dinner", "coffee", "groceries", "taxi", "uber", "rent",
            "gym", "netflix", "doctor", "shopping", "gas", "bus",
            "ناهار", "شام", "قهوه", "سوپرمارکت", "تاکسی", "اجاره",
            "باشگاه", "دکتر", "خرید", "بنزین"
        ]
        return categoryKeywords.contains { input.contains($0) }
    }

    private static func formatDollars(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }
}
