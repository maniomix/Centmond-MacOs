import Foundation
import SwiftData

// ============================================================
// MARK: - AI Duplicate Detector
// ============================================================
//
// Detects duplicate and near-duplicate transactions in the
// user's data. Runs heuristically (no LLM) -- checks amount,
// date, category, payee similarity.
//
// macOS Centmond: SwiftData Transaction model (Decimal amounts,
// payee instead of note, category?.name instead of storageKey).
//
// ============================================================

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let transactionIDs: [UUID]
    let amounts: [Decimal]
    let dates: [Date]
    let payees: [String]
    let confidence: Double
    let reason: DuplicateReason

    enum DuplicateReason: String {
        case exactMatch
        case sameDay
        case nearDate
        case samePayee
    }

    var suggestedAction: String {
        switch reason {
        case .exactMatch:
            return "These look identical -- consider deleting one."
        case .sameDay:
            return "Same amount on the same day -- could be a double charge."
        case .nearDate:
            return "Same amount on consecutive days -- possible duplicate."
        case .samePayee:
            return "Similar payees and amounts -- might be the same expense."
        }
    }
}

@MainActor @Observable
final class AIDuplicateDetector {
    static let shared = AIDuplicateDetector()

    private init() {}

    // MARK: - Detect Duplicates

    func detectDuplicates(context: ModelContext, month: Date? = nil) -> [DuplicateGroup] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome }
        )
        guard let allTxns = try? context.fetch(descriptor) else { return [] }

        let txns: [Transaction]
        if let month {
            txns = allTxns.filter {
                Calendar.current.isDate($0.date, equalTo: month, toGranularity: .month)
            }
        } else {
            txns = allTxns
        }

        var groups: [DuplicateGroup] = []

        groups.append(contentsOf: findExactMatches(txns))
        groups.append(contentsOf: findSameDayMatches(txns, excluding: groups))
        groups.append(contentsOf: findNearDateMatches(txns, excluding: groups))
        groups.append(contentsOf: findSimilarPayeeMatches(txns, excluding: groups))

        return groups.sorted { $0.confidence > $1.confidence }
    }

    func duplicateCount(context: ModelContext, month: Date? = nil) -> Int {
        detectDuplicates(context: context, month: month).count
    }

    // MARK: - Detection Passes

    private func findExactMatches(_ txns: [Transaction]) -> [DuplicateGroup] {
        var groups: [String: [Transaction]] = [:]

        for txn in txns {
            let catName = txn.category?.name ?? "none"
            let key = "\(txn.amount)|\(dayKey(txn.date))|\(catName)"
            groups[key, default: []].append(txn)
        }

        return groups.values.compactMap { group in
            guard group.count > 1 else { return nil }
            return DuplicateGroup(
                transactionIDs: group.map(\.id),
                amounts: group.map(\.amount),
                dates: group.map(\.date),
                payees: group.map(\.payee),
                confidence: 0.95, reason: .exactMatch
            )
        }
    }

    private func findSameDayMatches(_ txns: [Transaction], excluding existing: [DuplicateGroup]) -> [DuplicateGroup] {
        let existingIds = Set(existing.flatMap(\.transactionIDs))
        let filtered = txns.filter { !existingIds.contains($0.id) }

        var groups: [String: [Transaction]] = [:]
        for txn in filtered {
            let key = "\(txn.amount)|\(dayKey(txn.date))"
            groups[key, default: []].append(txn)
        }

        return groups.values.compactMap { group in
            guard group.count > 1 else { return nil }
            return DuplicateGroup(
                transactionIDs: group.map(\.id),
                amounts: group.map(\.amount),
                dates: group.map(\.date),
                payees: group.map(\.payee),
                confidence: 0.75, reason: .sameDay
            )
        }
    }

    private func findNearDateMatches(_ txns: [Transaction], excluding existing: [DuplicateGroup]) -> [DuplicateGroup] {
        let existingIds = Set(existing.flatMap(\.transactionIDs))
        let filtered = txns.filter { !existingIds.contains($0.id) }
            .sorted { $0.date < $1.date }

        var groups: [DuplicateGroup] = []
        var used: Set<UUID> = []

        for i in 0..<filtered.count {
            guard !used.contains(filtered[i].id) else { continue }
            for j in (i + 1)..<filtered.count {
                guard !used.contains(filtered[j].id) else { continue }
                let dayDiff = abs(Calendar.current.dateComponents([.day],
                    from: filtered[i].date, to: filtered[j].date).day ?? 99)

                if dayDiff <= 1 && filtered[i].amount == filtered[j].amount {
                    groups.append(DuplicateGroup(
                        transactionIDs: [filtered[i].id, filtered[j].id],
                        amounts: [filtered[i].amount, filtered[j].amount],
                        dates: [filtered[i].date, filtered[j].date],
                        payees: [filtered[i].payee, filtered[j].payee],
                        confidence: 0.6, reason: .nearDate
                    ))
                    used.insert(filtered[i].id)
                    used.insert(filtered[j].id)
                    break
                }
            }
        }

        return groups
    }

    private func findSimilarPayeeMatches(_ txns: [Transaction], excluding existing: [DuplicateGroup]) -> [DuplicateGroup] {
        let existingIds = Set(existing.flatMap(\.transactionIDs))
        let filtered = txns.filter { !existingIds.contains($0.id) && !$0.payee.isEmpty }

        var groups: [DuplicateGroup] = []
        var used: Set<UUID> = []

        for i in 0..<filtered.count {
            guard !used.contains(filtered[i].id) else { continue }
            for j in (i + 1)..<filtered.count {
                guard !used.contains(filtered[j].id) else { continue }

                let payeeSimilarity = stringSimilarity(filtered[i].payee, filtered[j].payee)
                let diff = abs(NSDecimalNumber(decimal: filtered[i].amount - filtered[j].amount).doubleValue)
                let base = NSDecimalNumber(decimal: filtered[i].amount).doubleValue
                let amountSimilar = diff < max(1.0, base * 0.1) // <$1 or <10%

                if payeeSimilarity > 0.7 && amountSimilar {
                    groups.append(DuplicateGroup(
                        transactionIDs: [filtered[i].id, filtered[j].id],
                        amounts: [filtered[i].amount, filtered[j].amount],
                        dates: [filtered[i].date, filtered[j].date],
                        payees: [filtered[i].payee, filtered[j].payee],
                        confidence: 0.5, reason: .samePayee
                    ))
                    used.insert(filtered[i].id)
                    used.insert(filtered[j].id)
                    break
                }
            }
        }

        return groups
    }

    // MARK: - Helpers

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func stringSimilarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.lowercased().split(separator: " ").map(String.init))
        let setB = Set(b.lowercased().split(separator: " ").map(String.init))
        guard !setA.isEmpty || !setB.isEmpty else { return 0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(intersection) / Double(union)
    }
}
