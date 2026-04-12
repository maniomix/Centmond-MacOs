import Foundation
import SwiftData

// ============================================================
// MARK: - AI User Preferences
// ============================================================
//
// Learns and remembers user behavior patterns to personalize
// AI responses. Persisted in UserDefaults.
//
// macOS Centmond: @Observable instead of ObservableObject,
// Decimal amounts instead of cents, SwiftData instead of Store.
//
// ============================================================

@MainActor @Observable
final class AIUserPreferences {
    static let shared = AIUserPreferences()

    // MARK: - State

    private(set) var preferredLanguage: String
    private(set) var topCategories: [String]
    private(set) var averageExpense: Decimal
    private(set) var typicalBudget: Decimal
    private(set) var commonPrompts: [String]
    private(set) var spendingPeakDay: Int?

    // MARK: - Internal Counters

    private var languageCounts: [String: Int]
    private var categoryCounts: [String: Int]
    private var totalExpenseAmount: Decimal
    private var expenseCount: Int
    private var dayOfWeekCounts: [Int: Int]

    private let key = "ai.userPreferences"

    // MARK: - Init

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(StoredPreferences.self, from: data) {
            self.preferredLanguage = saved.preferredLanguage
            self.topCategories = saved.topCategories
            self.averageExpense = Decimal(saved.averageExpenseDouble)
            self.typicalBudget = Decimal(saved.typicalBudgetDouble)
            self.commonPrompts = saved.commonPrompts
            self.spendingPeakDay = saved.spendingPeakDay
            self.languageCounts = saved.languageCounts
            self.categoryCounts = saved.categoryCounts
            self.totalExpenseAmount = Decimal(saved.totalExpenseDouble)
            self.expenseCount = saved.expenseCount
            self.dayOfWeekCounts = saved.dayOfWeekCounts
        } else {
            self.preferredLanguage = "en"
            self.topCategories = []
            self.averageExpense = 0
            self.typicalBudget = 0
            self.commonPrompts = []
            self.spendingPeakDay = nil
            self.languageCounts = [:]
            self.categoryCounts = [:]
            self.totalExpenseAmount = 0
            self.expenseCount = 0
            self.dayOfWeekCounts = [:]
        }
    }

    // MARK: - Learning

    /// Learn from a user's chat message.
    func learnFromMessage(_ text: String) {
        let lang = detectLanguage(text)
        languageCounts[lang, default: 0] += 1
        preferredLanguage = languageCounts.max(by: { $0.value < $1.value })?.key ?? "en"

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 5 && !commonPrompts.contains(trimmed) {
            commonPrompts.append(trimmed)
            if commonPrompts.count > 20 {
                commonPrompts.removeFirst()
            }
        }

        save()
    }

    /// Learn from transaction data in SwiftData.
    func learnFromTransactions(context: ModelContext) {
        categoryCounts = [:]
        totalExpenseAmount = 0
        expenseCount = 0
        dayOfWeekCounts = [:]

        let descriptor = FetchDescriptor<Transaction>()
        guard let txns = try? context.fetch(descriptor) else { return }

        for txn in txns where BalanceService.isSpendingExpense(txn) {
            let catName = txn.category?.name ?? "other"
            categoryCounts[catName, default: 0] += 1

            totalExpenseAmount += txn.amount
            expenseCount += 1

            let weekday = Calendar.current.component(.weekday, from: txn.date)
            dayOfWeekCounts[weekday, default: 0] += 1
        }

        topCategories = categoryCounts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)

        averageExpense = expenseCount > 0 ? totalExpenseAmount / Decimal(expenseCount) : 0

        spendingPeakDay = dayOfWeekCounts
            .max(by: { $0.value < $1.value })?.key

        // Budget learning
        let cal = Calendar.current
        let year = cal.component(.year, from: Date())
        let month = cal.component(.month, from: Date())
        let budgetDescriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        if let budget = try? context.fetch(budgetDescriptor).first, budget.amount > 0 {
            typicalBudget = budget.amount
        }

        save()
    }

    // MARK: - Context for AI

    /// Generate a preferences summary for the system prompt.
    func contextSummary() -> String {
        var parts: [String] = []

        parts.append("User language: \(preferredLanguage)")

        if !topCategories.isEmpty {
            parts.append("Top spending categories: \(topCategories.joined(separator: ", "))")
        }
        if averageExpense > 0 {
            let avg = NSDecimalNumber(decimal: averageExpense).doubleValue
            parts.append("Average expense: \(String(format: "$%.2f", avg))")
        }
        if typicalBudget > 0 {
            let budget = NSDecimalNumber(decimal: typicalBudget).doubleValue
            parts.append("Typical monthly budget: \(String(format: "$%.2f", budget))")
        }
        if let peak = spendingPeakDay {
            let dayName = Calendar.current.weekdaySymbols[peak - 1]
            parts.append("Spends most on: \(dayName)s")
        }

        return parts.isEmpty ? "" : "USER PREFERENCES\n" + parts.joined(separator: "\n")
    }

    // MARK: - Language Detection

    private func detectLanguage(_ text: String) -> String {
        let farsiRange = text.unicodeScalars.filter {
            (0x0600...0x06FF).contains($0.value) || (0xFB50...0xFDFF).contains($0.value)
        }
        if farsiRange.count > text.count / 3 { return "fa" }

        let germanWords = ["ich", "und", "der", "die", "das", "ist", "nicht", "haben", "werden"]
        let words = text.lowercased().split(separator: " ")
        let germanCount = words.filter { germanWords.contains(String($0)) }.count
        if germanCount >= 2 { return "de" }

        return "en"
    }

    // MARK: - Persistence

    private func save() {
        let stored = StoredPreferences(
            preferredLanguage: preferredLanguage,
            topCategories: topCategories,
            averageExpenseDouble: NSDecimalNumber(decimal: averageExpense).doubleValue,
            typicalBudgetDouble: NSDecimalNumber(decimal: typicalBudget).doubleValue,
            commonPrompts: commonPrompts,
            spendingPeakDay: spendingPeakDay,
            languageCounts: languageCounts,
            categoryCounts: categoryCounts,
            totalExpenseDouble: NSDecimalNumber(decimal: totalExpenseAmount).doubleValue,
            expenseCount: expenseCount,
            dayOfWeekCounts: dayOfWeekCounts
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private struct StoredPreferences: Codable {
        var preferredLanguage: String
        var topCategories: [String]
        var averageExpenseDouble: Double
        var typicalBudgetDouble: Double
        var commonPrompts: [String]
        var spendingPeakDay: Int?
        var languageCounts: [String: Int]
        var categoryCounts: [String: Int]
        var totalExpenseDouble: Double
        var expenseCount: Int
        var dayOfWeekCounts: [Int: Int]
    }
}
