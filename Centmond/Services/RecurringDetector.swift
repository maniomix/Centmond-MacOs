import Foundation
import SwiftData

/// Candidate recurring transaction surfaced by `RecurringDetector`. Lives
/// only in memory until `confirm` mints a `RecurringTransaction` row, or
/// `dismiss` writes a `DismissedDetection` so it stops resurfacing.
///
/// Mirrors `DetectedSubscriptionCandidate` but covers BOTH income and
/// expense — so the salary that lands every two weeks gets a template,
/// not just rent and utilities.
struct DetectedRecurringCandidate: Identifiable, Hashable {
    let id: UUID
    let merchantKey: String
    let displayName: String
    let amount: Decimal
    let isIncome: Bool
    let frequency: RecurrenceFrequency
    let confidence: Double
    let nextOccurrence: Date
    let firstSeen: Date
    let lastSeen: Date
    let occurrenceCount: Int
    let matchingTransactionIDs: [UUID]
    let suggestedCategoryName: String?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Pure-heuristic detector for `RecurringTransaction` patterns. Distinct
/// from `SubscriptionDetector` because:
///   - it covers income AND expense (subscription detector is expense-only)
///   - it emits `RecurrenceFrequency` (no `.semiannual` / `.custom`)
///   - it explicitly steps around merchant keys already owned by a
///     `Subscription` row, so the two pipelines never fight over the
///     same merchant
///
/// Dismissals piggy-back on the existing `DismissedDetection` table with
/// a `"recurring:"` key prefix so a user dismissing "Spotify" as a
/// subscription doesn't also silence "Spotify" as a recurring template
/// (and vice versa).
enum RecurringDetector {

    // MARK: - Tunables (kept together for easy "too noisy / too quiet" tweaks)

    static let minOccurrenceCount: Int = 3
    static let amountVarianceCeiling: Double = 0.10   // recurring is tighter than subs
    static let intervalVarianceCeiling: Double = 0.25
    /// Templates above this confidence are minted automatically by the
    /// scheduler. Below it they show up in the "detected" chip waiting
    /// for the user to accept or dismiss.
    static let autoConfirmThreshold: Double = 0.85
    /// Ignore tiny income amounts — cashback, refunds, peer-to-peer
    /// transfers all show up as income but aren't real recurring streams.
    static let minIncomeAmount: Decimal = 50

    private static let dismissalKeyPrefix = "recurring:"

    // MARK: - Public API

    @MainActor
    static func detect(context: ModelContext) -> [DetectedRecurringCandidate] {
        let txns = fetchTransactions(context: context)
        let claimedTxIDs = txnIDsAlreadyOwned(context: context)
        let claimedKeys = merchantKeysAlreadyOwned(context: context)
        let dismissed = dismissedRecurringKeys(context: context)

        return analyze(
            transactions: txns,
            excludeTransactionIDs: claimedTxIDs
        )
        .filter { !claimedKeys.contains($0.merchantKey) }
        .filter { !dismissed.contains($0.merchantKey) }
        .sorted { $0.confidence > $1.confidence }
    }

    /// Mint a `RecurringTransaction` from the candidate, tag every
    /// matching historical transaction with the new template ID so the
    /// linker doesn't create duplicates on the next tick, and return the
    /// new template for UI navigation.
    @MainActor
    @discardableResult
    static func confirm(
        _ candidate: DetectedRecurringCandidate,
        in context: ModelContext
    ) -> RecurringTransaction {
        // Guess account & category from the most-recent matching transaction.
        let txns = fetchTransactions(ids: candidate.matchingTransactionIDs, context: context)
        let mostRecent = txns.max(by: { $0.date < $1.date })

        let template = RecurringTransaction(
            name: candidate.displayName,
            amount: candidate.amount,
            isIncome: candidate.isIncome,
            frequency: candidate.frequency,
            nextOccurrence: candidate.nextOccurrence,
            autoCreate: true,
            account: mostRecent?.account,
            category: mostRecent?.category,
            householdMember: mostRecent?.householdMember
                ?? HouseholdService.resolveMember(forPayee: candidate.displayName, in: context)
        )
        context.insert(template)

        for tx in txns where tx.recurringTemplateID == nil {
            tx.recurringTemplateID = template.id
            tx.updatedAt = .now
        }
        template.lastMaterializedDate = candidate.lastSeen
        return template
    }

    @MainActor
    static func dismiss(_ candidate: DetectedRecurringCandidate, in context: ModelContext) {
        let row = DismissedDetection(
            merchantKey: dismissalKeyPrefix + candidate.merchantKey,
            lastDetectedAmount: candidate.amount,
            lastDetectedCycle: .monthly
        )
        context.insert(row)
    }

    /// Auto-mint templates for every candidate at or above the user's
    /// configured threshold. Called by `RecurringScheduler.tick` so
    /// detection happens silently in the background — the user only sees
    /// the lower-confidence stragglers in the "detected" chip.
    /// User can disable detection entirely via `recurringDetectionEnabled`.
    @MainActor
    @discardableResult
    static func autoConfirmHighConfidence(in context: ModelContext) -> Int {
        guard isDetectionEnabled else { return 0 }
        let threshold = effectiveAutoConfirmThreshold
        let candidates = detect(context: context)
        var minted = 0
        for c in candidates where c.confidence >= threshold {
            confirm(c, in: context)
            minted += 1
        }
        return minted
    }

    // MARK: - Settings-backed tunables

    /// Whether the scheduler should auto-mint high-confidence templates.
    /// User-toggleable in Settings → Recurring; defaults to true so the
    /// "fully automatic" promise holds for new users out of the box.
    static var isDetectionEnabled: Bool {
        UserDefaults.standard.object(forKey: "recurringDetectionEnabled") as? Bool ?? true
    }

    /// Confidence threshold at or above which the scheduler auto-confirms
    /// a candidate. Stored as `Double` 0...1 in UserDefaults; clamped to
    /// 0.5...0.99 so a misconfigured value never floods the store with
    /// junk templates or silently disables detection.
    static var effectiveAutoConfirmThreshold: Double {
        let raw = UserDefaults.standard.object(forKey: "recurringAutoConfirmThreshold") as? Double
            ?? autoConfirmThreshold
        return min(max(raw, 0.5), 0.99)
    }

    // MARK: - Pipeline

    @MainActor
    private static func fetchTransactions(context: ModelContext) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isTransfer }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    private static func fetchTransactions(ids: [UUID], context: ModelContext) -> [Transaction] {
        guard !ids.isEmpty else { return [] }
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { idSet.contains($0.id) }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Transactions already attributed to a Subscription charge OR an
    /// existing recurring template. Excluding them prevents the detector
    /// from re-suggesting a template we've already created.
    @MainActor
    private static func txnIDsAlreadyOwned(context: ModelContext) -> Set<UUID> {
        var owned: Set<UUID> = []
        let chargeDescriptor = FetchDescriptor<SubscriptionCharge>()
        for charge in (try? context.fetch(chargeDescriptor)) ?? [] {
            if let id = charge.transactionID { owned.insert(id) }
        }
        let txDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.recurringTemplateID != nil }
        )
        for tx in (try? context.fetch(txDescriptor)) ?? [] {
            owned.insert(tx.id)
        }
        return owned
    }

    /// Merchant keys claimed by an existing Subscription or active
    /// RecurringTransaction. We never re-detect these — Subscriptions
    /// own subscription patterns, and a template that already exists
    /// shouldn't be shadowed by a duplicate.
    @MainActor
    private static func merchantKeysAlreadyOwned(context: ModelContext) -> Set<String> {
        var keys: Set<String> = []
        let subDescriptor = FetchDescriptor<Subscription>()
        for sub in (try? context.fetch(subDescriptor)) ?? [] {
            let key = sub.merchantKey.isEmpty
                ? Subscription.merchantKey(for: sub.serviceName)
                : sub.merchantKey
            keys.insert(key)
        }
        let recurDescriptor = FetchDescriptor<RecurringTransaction>()
        for r in (try? context.fetch(recurDescriptor)) ?? [] {
            keys.insert(Subscription.merchantKey(for: r.name))
        }
        return keys
    }

    @MainActor
    private static func dismissedRecurringKeys(context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<DismissedDetection>()
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(
            rows.compactMap { row in
                row.merchantKey.hasPrefix(dismissalKeyPrefix)
                    ? String(row.merchantKey.dropFirst(dismissalKeyPrefix.count))
                    : nil
            }
        )
    }

    // MARK: - Analysis (pure)

    static func analyze(
        transactions: [Transaction],
        excludeTransactionIDs: Set<UUID> = []
    ) -> [DetectedRecurringCandidate] {
        // Group by (normalized merchant key, isIncome) so a payee that
        // appears as both refund and charge doesn't get collapsed into a
        // single (and meaningless) bucket.
        var groups: [GroupKey: [Transaction]] = [:]
        for tx in transactions {
            if excludeTransactionIDs.contains(tx.id) { continue }
            let key = Subscription.merchantKey(for: tx.payee)
            guard !key.isEmpty else { continue }
            if tx.isIncome && tx.amount < minIncomeAmount { continue }
            let gk = GroupKey(merchantKey: key, isIncome: tx.isIncome)
            groups[gk, default: []].append(tx)
        }

        var out: [DetectedRecurringCandidate] = []
        for (gk, bucket) in groups {
            guard bucket.count >= minOccurrenceCount else { continue }
            let sorted = bucket.sorted { $0.date < $1.date }
            guard let candidate = makeCandidate(groupKey: gk, sorted: sorted) else { continue }
            out.append(candidate)
        }
        return out
    }

    private struct GroupKey: Hashable {
        let merchantKey: String
        let isIncome: Bool
    }

    private static func makeCandidate(
        groupKey: GroupKey,
        sorted: [Transaction]
    ) -> DetectedRecurringCandidate? {
        let intervals = consecutiveDayDeltas(sorted)
        guard !intervals.isEmpty else { return nil }

        let intervalStats = stats(of: intervals.map(Double.init))
        guard intervalStats.coefficientOfVariation <= intervalVarianceCeiling else { return nil }

        let amounts = sorted.map { NSDecimalNumber(decimal: $0.amount).doubleValue }
        let amountStats = stats(of: amounts)
        guard amountStats.coefficientOfVariation <= amountVarianceCeiling else { return nil }

        let medianInterval = Int(intervalStats.median.rounded())
        guard let frequency = mapIntervalToFrequency(medianInterval) else { return nil }

        let amountDecimal = Decimal(amountStats.median)
        let lastDate = sorted.last?.date ?? .now
        let firstDate = sorted.first?.date ?? .now
        let nextDate = frequency.nextDate(after: lastDate)

        let confidence = scoreConfidence(
            occurrenceCount: sorted.count,
            amountCov: amountStats.coefficientOfVariation,
            intervalCov: intervalStats.coefficientOfVariation
        )

        return DetectedRecurringCandidate(
            id: UUID(),
            merchantKey: groupKey.merchantKey,
            displayName: bestDisplayName(from: sorted),
            amount: amountDecimal,
            isIncome: groupKey.isIncome,
            frequency: frequency,
            confidence: confidence,
            nextOccurrence: nextDate,
            firstSeen: firstDate,
            lastSeen: lastDate,
            occurrenceCount: sorted.count,
            matchingTransactionIDs: sorted.map(\.id),
            suggestedCategoryName: mostCommonCategoryName(in: sorted)
        )
    }

    private static func consecutiveDayDeltas(_ sorted: [Transaction]) -> [Int] {
        guard sorted.count >= 2 else { return [] }
        var out: [Int] = []
        let cal = Calendar.current
        for i in 1..<sorted.count {
            let d = cal.dateComponents([.day], from: sorted[i - 1].date, to: sorted[i].date).day ?? 0
            if d > 0 { out.append(d) }
        }
        return out
    }

    /// Map a median interval (days) to the closest standard frequency.
    /// Unlike Subscriptions we have no `.custom` escape hatch, so a
    /// candidate that doesn't fit any cadence within ±20% is rejected
    /// rather than forced into a wrong bucket.
    private static func mapIntervalToFrequency(_ days: Int) -> RecurrenceFrequency? {
        let targets: [(RecurrenceFrequency, Int)] = [
            (.weekly, 7),
            (.biweekly, 14),
            (.monthly, 30),
            (.quarterly, 91),
            (.annual, 365)
        ]
        for (freq, target) in targets {
            let tolerance = Double(target) * 0.20
            if abs(Double(days) - Double(target)) <= tolerance {
                return freq
            }
        }
        return nil
    }

    private static func scoreConfidence(
        occurrenceCount: Int,
        amountCov: Double,
        intervalCov: Double
    ) -> Double {
        var score = 0.45
        if occurrenceCount >= 3 { score += 0.10 }
        if occurrenceCount >= 5 { score += 0.10 }
        if occurrenceCount >= 8 { score += 0.05 }
        if amountCov <= 0.05 { score += 0.15 } else if amountCov <= 0.10 { score += 0.05 }
        if intervalCov <= 0.10 { score += 0.15 } else if intervalCov <= 0.20 { score += 0.05 }
        return min(score, 0.95)
    }

    private static func bestDisplayName(from txns: [Transaction]) -> String {
        var counts: [String: Int] = [:]
        for tx in txns {
            let payee = tx.payee.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payee.isEmpty else { continue }
            counts[payee, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
            ?? txns.first?.payee
            ?? ""
    }

    private static func mostCommonCategoryName(in txns: [Transaction]) -> String? {
        var counts: [String: Int] = [:]
        for tx in txns {
            guard let name = tx.category?.name else { continue }
            counts[name, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Statistics

    private struct Summary {
        let mean: Double
        let median: Double
        let stddev: Double
        var coefficientOfVariation: Double { mean > 0 ? stddev / mean : .infinity }
    }

    private static func stats(of values: [Double]) -> Summary {
        guard !values.isEmpty else { return Summary(mean: 0, median: 0, stddev: 0) }
        let mean = values.reduce(0, +) / Double(values.count)
        let med = median(of: values)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
        return Summary(mean: mean, median: med, stddev: sqrt(variance))
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
