import Foundation
import SwiftData

// ============================================================
// MARK: - AI Category Suggester
// ============================================================
//
// Rule-based auto-categorization engine.
// Suggests a category name based on transaction note/merchant.
//
// Two layers:
// 1. User history — learns from past categorizations.
// 2. Keyword rules — built-in patterns for common merchants.
//
// No LLM call needed — instant, offline, deterministic.
//
// macOS Centmond: returns category name (String) instead of
// iOS Category enum. The caller resolves to BudgetCategory.
//
// ============================================================

@MainActor
class AICategorySuggester {
    static let shared = AICategorySuggester()

    /// Persisted merchant -> category name mapping.
    private var merchantMap: [String: String] {
        didSet { save() }
    }

    private let key = "ai.merchantCategoryMap"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            self.merchantMap = saved
        } else {
            self.merchantMap = [:]
        }
    }

    // MARK: - Suggestion

    /// Suggest a category name for a given note/merchant text.
    func suggest(note: String) -> String? {
        let lower = note.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        // 1. Learned merchant map (user patterns > built-in)
        for (merchant, catName) in merchantMap {
            if lower.contains(merchant) {
                return catName
            }
        }

        // 2. Built-in keyword rules
        return keywordMatch(lower)
    }

    /// Suggest with confidence score (0.0-1.0).
    func suggestWithConfidence(note: String) -> (category: String, confidence: Double)? {
        let lower = note.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        for (merchant, catName) in merchantMap {
            if lower.contains(merchant) {
                return (catName, 0.9)
            }
        }

        if let cat = keywordMatch(lower) {
            return (cat, 0.7)
        }

        return nil
    }

    // MARK: - Learning

    /// Learn from a confirmed transaction.
    func learn(note: String, categoryName: String) {
        let lower = note.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.count >= 3 else { return }

        let words = lower.split(separator: " ").prefix(3)
        let merchantKey = words.joined(separator: " ")
        guard !merchantKey.isEmpty else { return }

        merchantMap[merchantKey] = categoryName
    }

    /// Learn from all existing transactions in SwiftData.
    func learnFromHistory(context: ModelContext) {
        let descriptor = FetchDescriptor<Transaction>()
        guard let txns = try? context.fetch(descriptor) else { return }

        for txn in txns where !txn.isIncome {
            guard let catName = txn.category?.name else { continue }
            let note = txn.payee.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard note.count >= 3 else { continue }
            let words = note.split(separator: " ").prefix(3)
            let merchantKey = words.joined(separator: " ")
            merchantMap[merchantKey] = catName
        }
    }

    // MARK: - Built-in Keyword Rules

    private func keywordMatch(_ text: String) -> String? {
        let groceryKeywords = [
            "grocery", "supermarket", "aldi", "lidl", "rewe", "edeka", "penny",
            "netto", "kaufland", "carrefour", "tesco", "whole foods", "trader joe",
            "سوپرمارکت", "میوه", "نون"
        ]
        if groceryKeywords.contains(where: { text.contains($0) }) { return "groceries" }

        let diningKeywords = [
            "restaurant", "cafe", "coffee", "starbucks", "mcdonald", "burger",
            "pizza", "sushi", "kebab", "bakery", "lunch", "dinner", "breakfast",
            "uber eats", "deliveroo", "lieferando", "just eat", "doordash",
            "رستوران", "کافه", "ناهار", "شام", "صبحانه", "قهوه"
        ]
        if diningKeywords.contains(where: { text.contains($0) }) { return "dining" }

        let transportKeywords = [
            "uber", "lyft", "taxi", "bus", "train", "metro", "subway",
            "gas", "fuel", "petrol", "shell", "bp", "parking",
            "toll", "flight", "airline", "ryanair", "lufthansa",
            "تاکسی", "بنزین", "مترو", "اسنپ"
        ]
        if transportKeywords.contains(where: { text.contains($0) }) { return "transport" }

        let shoppingKeywords = [
            "amazon", "ebay", "zalando", "h&m", "zara", "ikea",
            "apple store", "clothing", "shoes", "electronics",
            "لباس", "کفش", "خرید"
        ]
        if shoppingKeywords.contains(where: { text.contains($0) }) { return "shopping" }

        let healthKeywords = [
            "pharmacy", "doctor", "hospital", "clinic",
            "dental", "gym", "fitness", "medicine", "health",
            "دکتر", "دارو", "داروخانه", "بیمارستان", "باشگاه"
        ]
        if healthKeywords.contains(where: { text.contains($0) }) { return "health" }

        let billKeywords = [
            "electricity", "water", "internet", "phone", "mobile",
            "insurance", "netflix", "spotify", "disney", "youtube", "subscription",
            "قبض", "برق", "آب", "گاز", "اینترنت", "موبایل"
        ]
        if billKeywords.contains(where: { text.contains($0) }) { return "bills" }

        let rentKeywords = ["rent", "mortgage", "landlord", "housing", "اجاره", "رهن"]
        if rentKeywords.contains(where: { text.contains($0) }) { return "rent" }

        let educationKeywords = [
            "university", "college", "school", "course", "udemy", "book",
            "tuition", "library", "کتاب", "دانشگاه", "کلاس"
        ]
        if educationKeywords.contains(where: { text.contains($0) }) { return "education" }

        return nil
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(merchantMap) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
