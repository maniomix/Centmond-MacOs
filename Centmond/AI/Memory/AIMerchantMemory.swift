import Foundation
import SwiftData

// ============================================================
// MARK: - AI Merchant Memory
// ============================================================
//
// Learns from user corrections to build a merchant->category
// mapping that overrides default suggestions. When a user says
// "Starbucks is coffee not dining," this memory persists that
// correction for all future transactions.
//
// Also tracks merchant-specific behavior rules:
//   - Default amount (e.g., "gym membership is always $50")
//   - Preferred note format
//   - Custom category overrides
//
// macOS Centmond: @Observable instead of ObservableObject,
// amounts in dollars (Double) instead of cents (Int),
// ModelContext instead of Store for history learning.
//
// ============================================================

/// A learned merchant pattern from user behavior/corrections.
struct MerchantProfile: Codable, Identifiable {
    var id: String { merchantKey }
    let merchantKey: String
    var displayName: String
    var category: String              // category name (not storageKey)
    var defaultAmount: Double?        // typical amount in dollars
    var preferredNote: String?
    var correctionCount: Int
    var lastUsed: Date
    var transactionCount: Int

    var confidence: Double {
        if correctionCount >= 3 { return 0.95 }
        if correctionCount >= 2 { return 0.85 }
        if correctionCount >= 1 { return 0.75 }
        return Double(min(transactionCount, 10)) / 15.0 + 0.3
    }
}

@MainActor @Observable
final class AIMerchantMemory {
    static let shared = AIMerchantMemory()

    private(set) var merchants: [String: MerchantProfile] = [:]

    private let key = "ai.merchantMemory"

    private init() {
        load()
    }

    // MARK: - Query

    func lookup(_ note: String) -> MerchantProfile? {
        let normalized = normalize(note)
        guard !normalized.isEmpty else { return nil }

        if let profile = merchants[normalized] {
            return profile
        }

        for (key, profile) in merchants {
            if normalized.contains(key) || key.contains(normalized) {
                return profile
            }
        }

        return nil
    }

    func suggestCategory(for note: String) -> (category: String, confidence: Double)? {
        guard let profile = lookup(note) else { return nil }
        return (profile.category, profile.confidence)
    }

    func suggestAmount(for note: String) -> Double? {
        lookup(note)?.defaultAmount
    }

    // MARK: - Learning

    func learnCorrection(merchantNote: String, correctCategory: String) {
        let normalized = normalize(merchantNote)
        guard !normalized.isEmpty else { return }

        if var existing = merchants[normalized] {
            existing.category = correctCategory
            existing.correctionCount += 1
            existing.lastUsed = Date()
            merchants[normalized] = existing
        } else {
            merchants[normalized] = MerchantProfile(
                merchantKey: normalized,
                displayName: merchantNote.trimmingCharacters(in: .whitespacesAndNewlines),
                category: correctCategory,
                defaultAmount: nil,
                preferredNote: nil,
                correctionCount: 1,
                lastUsed: Date(),
                transactionCount: 1
            )
        }

        AICategorySuggester.shared.learn(note: merchantNote, categoryName: correctCategory)
        save()
    }

    func learnFromTransaction(note: String, category: String, amount: Double) {
        let normalized = normalize(note)
        guard !normalized.isEmpty else { return }

        if var existing = merchants[normalized] {
            existing.transactionCount += 1
            existing.lastUsed = Date()
            if let prev = existing.defaultAmount {
                existing.defaultAmount = (prev + amount) / 2.0
            } else {
                existing.defaultAmount = amount
            }
            if existing.correctionCount == 0 {
                existing.category = category
            }
            merchants[normalized] = existing
        } else {
            merchants[normalized] = MerchantProfile(
                merchantKey: normalized,
                displayName: note.trimmingCharacters(in: .whitespacesAndNewlines),
                category: category,
                defaultAmount: amount,
                preferredNote: nil,
                correctionCount: 0,
                lastUsed: Date(),
                transactionCount: 1
            )
        }

        save()
    }

    func learnFromHistory(context: ModelContext) {
        let descriptor = FetchDescriptor<Transaction>()
        guard let txns = try? context.fetch(descriptor) else { return }

        for txn in txns where !txn.payee.isEmpty {
            let catName = txn.category?.name ?? "Uncategorized"
            let amount = NSDecimalNumber(decimal: txn.amount).doubleValue
            learnFromTransaction(note: txn.payee, category: catName, amount: amount)
        }
    }

    // MARK: - Management

    func forget(_ merchantKey: String) {
        merchants.removeValue(forKey: merchantKey)
        save()
    }

    func clearAll() {
        merchants.removeAll()
        save()
    }

    func topMerchants(limit: Int = 20) -> [MerchantProfile] {
        Array(merchants.values
            .sorted { $0.transactionCount > $1.transactionCount }
            .prefix(limit))
    }

    func recentCorrections(limit: Int = 10) -> [MerchantProfile] {
        Array(merchants.values
            .filter { $0.correctionCount > 0 }
            .sorted { $0.lastUsed > $1.lastUsed }
            .prefix(limit))
    }

    // MARK: - Context for System Prompt

    func contextSummary() -> String {
        let corrected = merchants.values
            .filter { $0.correctionCount > 0 }
            .sorted { $0.correctionCount > $1.correctionCount }
            .prefix(10)

        guard !corrected.isEmpty else { return "" }

        var lines = ["MERCHANT MEMORY (user-corrected categories):"]
        for m in corrected {
            lines.append("  \(m.displayName) -> \(m.category) (corrected \(m.correctionCount)x)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func normalize(_ note: String) -> String {
        note.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .prefix(3)
            .joined(separator: " ")
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: MerchantProfile].self, from: data) {
            merchants = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(merchants) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
