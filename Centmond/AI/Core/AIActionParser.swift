import Foundation

// ============================================================
// MARK: - AI Action Parser
// ============================================================
//
// Splits the raw AI response at the "---ACTIONS---" delimiter,
// extracts the text portion and decodes the JSON actions array.
//
// Centmond macOS: amounts stay as Double (dollars). No toCents()
// conversion — the executor converts to Decimal when writing
// to SwiftData.
//
// ============================================================

enum AIActionParser {

    struct ParsedResponse {
        let text: String
        let actions: [AIAction]
    }

    private static let separator = "---ACTIONS---"

    /// Parse a raw AI response into text + actions.
    /// Gracefully handles missing separator or malformed JSON.
    static func parse(_ raw: String) -> ParsedResponse {
        // Normalize the separator — LLM sometimes adds extra dashes or spaces
        let normalized = normalizeSeparator(raw)

        // Split at the separator
        let parts = normalized.components(separatedBy: separator)
        let text = cleanText(parts[0])

        guard parts.count >= 2 else {
            // No separator found — try to extract JSON from the text itself
            if let fallbackActions = extractJSONFallback(raw) {
                let cleanedText = removeJSONFromText(raw)
                return ParsedResponse(text: cleanedText, actions: fallbackActions)
            }
            return ParsedResponse(text: text, actions: [])
        }

        // Take everything after the first separator (in case LLM emits multiple)
        let jsonPart = parts.dropFirst().joined(separator: separator)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = decodeActions(jsonPart)
        return ParsedResponse(text: text, actions: actions)
    }

    // MARK: - Separator Normalization

    /// Handle common LLM variations of the separator.
    private static func normalizeSeparator(_ raw: String) -> String {
        var result = raw
        // Variations: "--- ACTIONS ---", "---actions---", "--ACTIONS--", "---ACTIONS ---"
        let patterns = [
            "---\\s*ACTIONS\\s*---",
            "--\\s*ACTIONS\\s*--",
            "---\\s*actions\\s*---",
            "—ACTIONS—",         // em-dash variant
            "———ACTIONS———"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: separator
                )
            }
        }
        return result
    }

    // MARK: - Text Cleaning

    /// Clean up the text portion of the response.
    /// Preserves Markdown formatting AND the ---INSIGHTS--- block
    /// (ChatBubbleView needs it to render dashboard cards).
    private static func cleanText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove leading "Text:" or "Response:" labels
        if let range = text.range(of: "^(Text|Response):\\s*", options: .regularExpression) {
            text = String(text[range.upperBound...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON Decoding

    private static func decodeActions(_ json: String) -> [AIAction] {
        // Strip markdown code fences if present
        var cleaned = json
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty, cleaned != "[]" else { return [] }

        // Fix common JSON issues from LLMs
        cleaned = fixCommonJSONIssues(cleaned)

        guard let data = cleaned.data(using: .utf8) else { return [] }

        // Try decoding as array of RawAction first
        do {
            let rawActions = try JSONDecoder().decode([RawAction].self, from: data)
            return rawActions.compactMap { $0.toAIAction() }
        } catch {
            // Try single object wrapped in array
            if let single = try? JSONDecoder().decode(RawAction.self, from: data),
               let action = single.toAIAction() {
                return [action]
            }

            // Try extracting JSON array from within the string
            if let extracted = extractJSONArray(from: cleaned),
               let extractedData = extracted.data(using: .utf8),
               let rawActions = try? JSONDecoder().decode([RawAction].self, from: extractedData) {
                return rawActions.compactMap { $0.toAIAction() }
            }

            print("[AIActionParser] Failed to decode actions: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - JSON Fixing

    /// Fix common JSON issues LLMs produce.
    private static func fixCommonJSONIssues(_ json: String) -> String {
        var result = json

        // Remove trailing commas before ] or }
        result = result.replacingOccurrences(
            of: ",\\s*([\\]\\}])",
            with: "$1",
            options: .regularExpression
        )

        // Fix single quotes → double quotes (only outside of already double-quoted strings)
        if !result.contains("\"") && result.contains("'") {
            result = result.replacingOccurrences(of: "'", with: "\"")
        }

        // Remove any non-JSON text before the first [ or {
        if let firstBracket = result.firstIndex(where: { $0 == "[" || $0 == "{" }) {
            result = String(result[firstBracket...])
        }

        // Remove any non-JSON text after the last ] or }
        if let lastBracket = result.lastIndex(where: { $0 == "]" || $0 == "}" }) {
            result = String(result[...lastBracket])
        }

        return result
    }

    /// Try to extract a JSON array from a string that might contain extra text.
    private static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]") else { return nil }
        guard start < end else { return nil }
        return String(text[start...end])
    }

    // MARK: - Fallback Extraction

    /// If no separator was found, try to find a JSON array anywhere in the response.
    private static func extractJSONFallback(_ raw: String) -> [AIAction]? {
        guard let arrayStr = extractJSONArray(from: raw),
              let data = arrayStr.data(using: .utf8) else { return nil }

        // Only use fallback if it looks like our action format
        guard arrayStr.contains("\"type\"") && arrayStr.contains("\"params\"") else {
            return nil
        }

        if let rawActions = try? JSONDecoder().decode([RawAction].self, from: data) {
            let actions = rawActions.compactMap { $0.toAIAction() }
            return actions.isEmpty ? nil : actions
        }
        return nil
    }

    /// Remove JSON content from text when using fallback extraction.
    private static func removeJSONFromText(_ raw: String) -> String {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]") else { return raw }
        var result = raw
        result.removeSubrange(start...end)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Raw JSON Shape

/// Matches the exact JSON shape the AI outputs, before converting to AIAction.
private struct RawAction: Decodable {
    let type: String
    let params: [String: AnyCodableValue]?

    func toAIAction() -> AIAction? {
        // Normalize type: handle variations like "addTransaction", "ADD_TRANSACTION", etc.
        let normalizedType = normalizeActionType(type)

        guard let actionType = AIAction.ActionType(rawValue: normalizedType) else {
            print("[AIActionParser] Unknown action type: \(type) (normalized: \(normalizedType))")
            return nil
        }

        let p = params ?? [:]

        // macOS Centmond: amounts stay as Double (dollars).
        // No toCents() conversion — the executor converts to Decimal
        // when writing to SwiftData.
        func toDollars(_ key: String) -> Double? {
            guard let val = p[key] else { return nil }
            switch val {
            case .double(let d):
                return abs(d)
            case .int(let i):
                return Double(abs(i))
            case .string(let s):
                let cleaned = s.replacingOccurrences(of: ",", with: "")
                if let d = Double(cleaned) {
                    return abs(d)
                }
                return nil
            default:
                return nil
            }
        }

        // Normalize category value
        let category = normalizeCategory(p["category"]?.stringValue)
        let budgetCategory = normalizeCategory(p["budgetCategory"]?.stringValue)

        let actionParams = AIAction.ActionParams(
            amount: toDollars("amount"),
            category: category,
            note: p["note"]?.stringValue,
            date: normalizeDate(p["date"]?.stringValue),
            transactionType: normalizeTransactionType(p["transactionType"]?.stringValue),
            transactionId: p["transactionId"]?.stringValue,
            splitWith: p["splitWith"]?.stringValue,
            splitRatio: clampSplitRatio(p["splitRatio"]?.doubleValue),
            budgetAmount: toDollars("budgetAmount"),
            budgetMonth: p["budgetMonth"]?.stringValue,
            budgetCategory: budgetCategory,
            goalName: p["goalName"]?.stringValue,
            goalTarget: toDollars("goalTarget"),
            goalDeadline: p["goalDeadline"]?.stringValue,
            contributionAmount: toDollars("contributionAmount"),
            subscriptionName: p["subscriptionName"]?.stringValue,
            subscriptionAmount: toDollars("subscriptionAmount"),
            subscriptionFrequency: normalizeFrequency(p["subscriptionFrequency"]?.stringValue),
            accountName: p["accountName"]?.stringValue,
            accountBalance: toDollars("accountBalance"),
            fromAccount: p["fromAccount"]?.stringValue,
            toAccount: p["toAccount"]?.stringValue,
            recurringName: p["recurringName"]?.stringValue,
            recurringFrequency: normalizeRecurringFrequency(p["recurringFrequency"]?.stringValue),
            recurringEndDate: p["recurringEndDate"]?.stringValue,
            memberName: p["memberName"]?.stringValue,
            analysisText: p["analysisText"]?.stringValue
        )

        return AIAction(type: actionType, params: actionParams)
    }

    // MARK: - Normalization Helpers

    /// Normalize action type strings from various LLM formats to our snake_case format.
    private func normalizeActionType(_ type: String) -> String {
        // Already snake_case? Return as-is
        if type.contains("_") { return type.lowercased() }

        // camelCase → snake_case: "addTransaction" → "add_transaction"
        var result = ""
        for (i, char) in type.enumerated() {
            if char.isUppercase && i > 0 {
                result += "_"
            }
            result += String(char).lowercased()
        }
        return result
    }

    /// Normalize category names to match our expected values.
    private func normalizeCategory(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Map common aliases
        let categoryMap: [String: String] = [
            "food": "dining",
            "restaurant": "dining",
            "cafe": "dining",
            "coffee": "dining",
            "lunch": "dining",
            "dinner": "dining",
            "breakfast": "dining",
            "eating out": "dining",
            "غذا": "dining",
            "ناهار": "dining",
            "شام": "dining",
            "صبحانه": "dining",
            "رستوران": "dining",
            "کافه": "dining",

            "grocery": "groceries",
            "supermarket": "groceries",
            "market": "groceries",
            "سوپرمارکت": "groceries",
            "میوه": "groceries",

            "taxi": "transport",
            "uber": "transport",
            "lyft": "transport",
            "gas": "transport",
            "fuel": "transport",
            "parking": "transport",
            "bus": "transport",
            "metro": "transport",
            "تاکسی": "transport",
            "بنزین": "transport",
            "مترو": "transport",
            "اسنپ": "transport",

            "electric": "bills",
            "water": "bills",
            "internet": "bills",
            "phone": "bills",
            "utility": "bills",
            "utilities": "bills",
            "قبض": "bills",
            "برق": "bills",
            "آب": "bills",
            "گاز": "bills",
            "اینترنت": "bills",
            "موبایل": "bills",

            "doctor": "health",
            "pharmacy": "health",
            "medicine": "health",
            "gym": "health",
            "hospital": "health",
            "دکتر": "health",
            "دارو": "health",
            "داروخانه": "health",
            "بیمارستان": "health",
            "باشگاه": "health",

            "clothes": "shopping",
            "clothing": "shopping",
            "shoes": "shopping",
            "electronics": "shopping",
            "amazon": "shopping",
            "mall": "shopping",
            "لباس": "shopping",
            "کفش": "shopping",
            "خرید": "shopping",

            "mortgage": "rent",
            "اجاره": "rent",
            "رهن": "rent",

            "book": "education",
            "books": "education",
            "course": "education",
            "tuition": "education",
            "school": "education",
            "university": "education",
            "کتاب": "education",
            "دانشگاه": "education",
            "کلاس": "education",
        ]

        if let mapped = categoryMap[lower] {
            return mapped
        }

        // Check if it starts with "custom:"
        if lower.hasPrefix("custom:") { return raw }

        // Check if it's already a valid category
        let validCategories = ["groceries", "rent", "bills", "transport", "health",
                                "education", "dining", "shopping", "other"]
        if validCategories.contains(lower) { return lower }

        // Unknown category — wrap as custom
        return "custom:\(raw.capitalized)"
    }

    /// Normalize transaction type.
    private func normalizeTransactionType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.lowercased()
        if lower.contains("income") || lower.contains("earning") || lower.contains("salary") {
            return "income"
        }
        return "expense"
    }

    /// Normalize date value.
    private func normalizeDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower == "today" || lower == "امروز" { return "today" }
        if lower == "yesterday" || lower == "دیروز" { return "yesterday" }
        return raw
    }

    /// Clamp split ratio to 0.0–1.0 range.
    private func clampSplitRatio(_ ratio: Double?) -> Double? {
        guard let ratio else { return nil }
        if ratio > 1.0 { return min(ratio / 100.0, 1.0) }
        return max(0.0, min(1.0, ratio))
    }

    /// Normalize recurring frequency (daily/weekly/monthly/yearly).
    private func normalizeRecurringFrequency(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.lowercased()
        if lower.contains("daily") || lower.contains("روزانه") { return "daily" }
        if lower.contains("week") || lower.contains("هفتگی") { return "weekly" }
        if lower.contains("year") || lower.contains("annual") || lower.contains("سالانه") { return "yearly" }
        return "monthly"
    }

    /// Normalize subscription frequency.
    private func normalizeFrequency(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.lowercased()
        if lower.contains("year") || lower.contains("annual") || lower.contains("سالانه") {
            return "yearly"
        }
        return "monthly"
    }
}

// MARK: - AnyCodableValue

/// A lightweight type-erased JSON value for flexible param decoding.
enum AnyCodableValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if container.decodeNil() { self = .null }
        else { self = .null }
    }

    var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let v): return Int(v)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .string(let v): return Double(v)
        default: return nil
        }
    }
}
