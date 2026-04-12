import Foundation
import SwiftData

// ============================================================
// MARK: - AI Recurring Transaction Detector
// ============================================================
//
// Scans transaction history for patterns that look like
// recurring payments (subscriptions, bills, installments)
// that haven't been set up as recurring yet.
//
// Pure heuristic -- no LLM needed.
//
// macOS Centmond: ModelContext, Decimal amounts, payee field.
//
// ============================================================

struct DetectedRecurring: Identifiable {
    let id = UUID()
    let merchantName: String
    let amount: Decimal
    let frequency: EstimatedFrequency
    let confidence: Double
    let matchingTransactionIDs: [UUID]
    let suggestedCategory: String

    enum EstimatedFrequency: String {
        case weekly    = "weekly"
        case biweekly  = "biweekly"
        case monthly   = "monthly"
        case quarterly = "quarterly"
        case yearly    = "yearly"

        var dayRange: ClosedRange<Int> {
            switch self {
            case .weekly:    return 5...9
            case .biweekly:  return 12...16
            case .monthly:   return 27...34
            case .quarterly: return 85...100
            case .yearly:    return 350...380
            }
        }
    }
}

@MainActor @Observable
final class AIRecurringDetector {
    static let shared = AIRecurringDetector()

    private init() {}

    // MARK: - Detect

    func detect(context: ModelContext) -> [DetectedRecurring] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome }
        )
        guard let txns = try? context.fetch(descriptor) else { return [] }

        let recurringDescriptor = FetchDescriptor<RecurringTransaction>()
        let existingRecurring = (try? context.fetch(recurringDescriptor)) ?? []

        let groups = groupByMerchant(txns)
        var results: [DetectedRecurring] = []

        for (merchant, merchantTxns) in groups {
            guard merchantTxns.count >= 2 else { continue }

            let sorted = merchantTxns.sorted { $0.date < $1.date }
            let intervals = calculateIntervals(sorted)
            guard !intervals.isEmpty else { continue }

            if let frequency = detectFrequency(intervals) {
                let amounts = sorted.map { NSDecimalNumber(decimal: $0.amount).doubleValue }
                let avgAmount = amounts.reduce(0.0, +) / Double(amounts.count)
                let amountVariance = calculateVariance(amounts)

                let alreadyTracked = existingRecurring.contains { existing in
                    existing.name.lowercased().contains(merchant.lowercased()) ||
                    merchant.lowercased().contains(existing.name.lowercased())
                }
                guard !alreadyTracked else { continue }

                var confidence = 0.5
                if merchantTxns.count >= 4 { confidence += 0.15 }
                if merchantTxns.count >= 6 { confidence += 0.1 }
                if amountVariance < 0.15 { confidence += 0.2 }
                if amountVariance < 0.05 { confidence += 0.1 }
                confidence = min(0.95, confidence)

                let category = sorted.first?.category?.name ?? "Bills"

                results.append(DetectedRecurring(
                    merchantName: merchant,
                    amount: Decimal(avgAmount),
                    frequency: frequency,
                    confidence: confidence,
                    matchingTransactionIDs: sorted.map(\.id),
                    suggestedCategory: category
                ))
            }
        }

        return results.sorted { $0.confidence > $1.confidence }
    }

    func summary(context: ModelContext) -> String {
        let detected = detect(context: context)
        guard !detected.isEmpty else { return "" }

        var lines = ["DETECTED RECURRING PATTERNS (not yet tracked):"]
        for d in detected.prefix(5) {
            let amt = fmtDecimal(d.amount)
            lines.append("  \(d.merchantName): ~\(amt)/\(d.frequency.rawValue) (conf: \(Int(d.confidence * 100))%)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Analysis

    private func groupByMerchant(_ transactions: [Transaction]) -> [String: [Transaction]] {
        var groups: [String: [Transaction]] = [:]

        for txn in transactions where !txn.payee.isEmpty {
            let key = normalizeMerchant(txn.payee)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(txn)
        }

        return groups
    }

    private func normalizeMerchant(_ payee: String) -> String {
        var result = payee.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let removals = ["payment", "charge", "#", "ref:", "invoice", "bill"]
        for removal in removals {
            result = result.replacingOccurrences(of: removal, with: "")
        }

        if let range = result.range(of: "\\s*\\d+\\s*$", options: .regularExpression) {
            result = String(result[..<range.lowerBound])
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func calculateIntervals(_ sorted: [Transaction]) -> [Int] {
        guard sorted.count >= 2 else { return [] }
        var intervals: [Int] = []
        for i in 1..<sorted.count {
            let days = Calendar.current.dateComponents([.day],
                from: sorted[i - 1].date, to: sorted[i].date).day ?? 0
            if days > 0 { intervals.append(days) }
        }
        return intervals
    }

    private func detectFrequency(_ intervals: [Int]) -> DetectedRecurring.EstimatedFrequency? {
        guard !intervals.isEmpty else { return nil }

        let avg = intervals.reduce(0, +) / intervals.count

        let frequencies: [DetectedRecurring.EstimatedFrequency] = [
            .weekly, .biweekly, .monthly, .quarterly, .yearly
        ]

        for freq in frequencies {
            if freq.dayRange.contains(avg) {
                let inRange = intervals.filter { freq.dayRange.contains($0) }.count
                if Double(inRange) / Double(intervals.count) > 0.6 {
                    return freq
                }
            }
        }

        return nil
    }

    private func calculateVariance(_ amounts: [Double]) -> Double {
        guard amounts.count > 1 else { return 0 }
        let avg = amounts.reduce(0, +) / Double(amounts.count)
        guard avg > 0 else { return 0 }
        let variance = amounts.map { pow($0 - avg, 2) }.reduce(0, +) / Double(amounts.count)
        return sqrt(variance) / avg
    }

    private func fmtDecimal(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        return String(format: "$%.2f", d)
    }
}
