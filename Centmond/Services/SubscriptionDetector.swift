import Foundation
import SwiftData

/// Candidate subscription surfaced by `SubscriptionDetector`. NOT a SwiftData
/// entity on purpose — candidates live only in memory until the user confirms
/// or dismisses them. Confirming mints a `Subscription` + `SubscriptionCharge`
/// rows; dismissing writes a `DismissedDetection` row. The review queue
/// regenerates on every open so newly-landed transactions show up without a
/// separate sync step.
struct DetectedSubscriptionCandidate: Identifiable, Hashable {
    let id: UUID
    let merchantKey: String
    let displayName: String
    let amount: Decimal
    let currency: String
    let billingCycle: BillingCycle
    let customCadenceDays: Int?
    let confidence: Double
    let nextPredictedDate: Date
    let firstChargeDate: Date
    let lastChargeDate: Date
    let chargeCount: Int
    let matchingTransactionIDs: [UUID]
    let amountCoefficientOfVariation: Double
    let intervalCoefficientOfVariation: Double
    let suggestedCategory: String?
    let hasPriceChange: Bool
    let priceChangePercent: Double?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Bump confidence +0.15 (capped at 0.98) when the user pre-labelled this
    /// merchant as a subscription via a CSV hint column. Separate from the
    /// heuristic score so we never credit the hint twice for the same row.
    func boostedByHint() -> DetectedSubscriptionCandidate {
        DetectedSubscriptionCandidate(
            id: id, merchantKey: merchantKey, displayName: displayName,
            amount: amount, currency: currency, billingCycle: billingCycle,
            customCadenceDays: customCadenceDays,
            confidence: min(confidence + 0.15, 0.98),
            nextPredictedDate: nextPredictedDate,
            firstChargeDate: firstChargeDate, lastChargeDate: lastChargeDate,
            chargeCount: chargeCount, matchingTransactionIDs: matchingTransactionIDs,
            amountCoefficientOfVariation: amountCoefficientOfVariation,
            intervalCoefficientOfVariation: intervalCoefficientOfVariation,
            suggestedCategory: suggestedCategory,
            hasPriceChange: hasPriceChange, priceChangePercent: priceChangePercent
        )
    }
}

/// Pure-heuristic (no LLM) subscription detection. Replaces the role
/// `AIRecurringDetector` was filling for Subscriptions specifically; the older
/// detector stays because it feeds `RecurringTransaction` in the AI context
/// builder and the two use cases have different surface areas (recurring
/// includes income, subscriptions do not, etc.).
///
/// Flow: fetch expense transactions → subtract anything already linked to an
/// existing Subscription or dismissed → group by normalized merchant key →
/// compute median/stddev of intervals and amounts → map to BillingCycle (or
/// .custom) → score confidence → rank.
enum SubscriptionDetector {

    // Tuning knobs. Kept together so they're easy to find when the user says
    // "detector is too noisy" or "detector misses X" — change the number, not
    // the algorithm.
    static let minChargeCount: Int = 3
    static let amountVarianceCeiling: Double = 0.25   // CoV above this → not a sub
    static let intervalVarianceCeiling: Double = 0.30 // CoV above this → too irregular
    static let priceChangeThreshold: Double = 0.05    // > 5% delta = price hike

    /// Ephemeral handoff for the CSV importer → DetectedSubscriptionsSheet.
    /// The importer writes hinted merchant keys here via `stashHintedKeys`;
    /// the sheet consumes + clears them on load so they survive exactly one
    /// review pass. UserDefaults (not @AppStorage-backed-model) because the
    /// lifetime is one import → one review, never persistent state.
    private static let hintsDefaultsKey = "pendingSubscriptionImportHints"

    static func stashHintedKeys(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        UserDefaults.standard.set(Array(keys), forKey: hintsDefaultsKey)
    }

    static func consumeHintedKeys() -> Set<String> {
        let defaults = UserDefaults.standard
        let raw = defaults.stringArray(forKey: hintsDefaultsKey) ?? []
        if !raw.isEmpty { defaults.removeObject(forKey: hintsDefaultsKey) }
        return Set(raw)
    }

    // MARK: - Public API

    @MainActor
    static func detect(
        context: ModelContext,
        hintedMerchantKeys: Set<String> = []
    ) -> [DetectedSubscriptionCandidate] {
        let txns = fetchExpenseTransactions(context: context)
        let existingKeys = existingSubscriptionKeys(context: context)
        let dismissedKeys = dismissedKeys(context: context)
        let linkedTransactionIDs = linkedChargeTransactionIDs(context: context)

        let candidates = analyze(
            transactions: txns,
            excludeTransactionIDs: linkedTransactionIDs,
            hintedMerchantKeys: hintedMerchantKeys
        )

        return candidates
            .filter { !existingKeys.contains($0.merchantKey) }
            .filter { !dismissedKeys.contains($0.merchantKey) }
            .sorted { $0.confidence > $1.confidence }
    }

    /// Dismiss a candidate — writes a `DismissedDetection` so the next
    /// `detect(...)` call skips this merchant. Keyed on `merchantKey`, not
    /// on the candidate's runtime id, so a freshly re-run detection (which
    /// mints new ids) still matches.
    @MainActor
    static func dismiss(_ candidate: DetectedSubscriptionCandidate, context: ModelContext) {
        let row = DismissedDetection(
            merchantKey: candidate.merchantKey,
            lastDetectedAmount: candidate.amount,
            lastDetectedCycle: candidate.billingCycle
        )
        context.insert(row)
    }

    /// Confirm a candidate — creates a `Subscription` with
    /// `source = .detected`, `autoDetected = true`, the detector's confidence,
    /// and a `SubscriptionCharge` row per matching transaction. Returns the
    /// new Subscription for UI navigation. Does NOT modify the underlying
    /// transactions — reconciliation in P4 will keep them linked going forward.
    @MainActor
    @discardableResult
    static func confirm(
        _ candidate: DetectedSubscriptionCandidate,
        context: ModelContext
    ) -> Subscription {
        let sub = Subscription(
            serviceName: candidate.displayName,
            categoryName: candidate.suggestedCategory ?? "Subscriptions",
            amount: candidate.amount,
            billingCycle: candidate.billingCycle,
            nextPaymentDate: candidate.nextPredictedDate
        )
        sub.merchantKey = candidate.merchantKey
        sub.currency = candidate.currency
        sub.customCadenceDays = candidate.customCadenceDays
        sub.firstChargeDate = candidate.firstChargeDate
        sub.lastChargeDate = candidate.lastChargeDate
        sub.source = .detected
        sub.autoDetected = true
        sub.detectionConfidence = candidate.confidence
        // Carry over attribution from the detected charges — if this merchant
        // has a dominant payer in ledger history the subscription inherits it
        // (P2). Conservative threshold in HouseholdService avoids false picks.
        sub.householdMember = HouseholdService.resolveMember(
            forPayee: candidate.displayName,
            in: context
        )
        context.insert(sub)

        // Backfill charge history so the detail timeline is populated from
        // day one, without waiting for P4 reconciliation to stumble across
        // the same transactions again.
        let txns = fetchTransactions(ids: candidate.matchingTransactionIDs, context: context)
        for tx in txns {
            let charge = SubscriptionCharge(
                date: tx.date,
                amount: tx.amount,
                currency: candidate.currency,
                transactionID: tx.id,
                matchedAutomatically: true,
                matchConfidence: candidate.confidence,
                notes: nil,
                subscription: sub
            )
            context.insert(charge)
        }

        return sub
    }

    // MARK: - Pipeline

    @MainActor
    private static func fetchExpenseTransactions(context: ModelContext) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && !$0.isTransfer }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    private static func existingSubscriptionKeys(context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<Subscription>()
        let subs = (try? context.fetch(descriptor)) ?? []
        return Set(subs.map { $0.merchantKey.isEmpty ? Subscription.merchantKey(for: $0.serviceName) : $0.merchantKey })
    }

    @MainActor
    private static func dismissedKeys(context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<DismissedDetection>()
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map(\.merchantKey))
    }

    @MainActor
    private static func linkedChargeTransactionIDs(context: ModelContext) -> Set<UUID> {
        let descriptor = FetchDescriptor<SubscriptionCharge>()
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.compactMap(\.transactionID))
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

    // MARK: - Analysis (pure)

    /// Pure function — takes transactions, returns candidates. No model
    /// context, no filtering against existing subscriptions. Separated so it
    /// can be unit-tested or replayed against a CSV snapshot without SwiftData.
    static func analyze(
        transactions: [Transaction],
        excludeTransactionIDs: Set<UUID> = [],
        hintedMerchantKeys: Set<String> = []
    ) -> [DetectedSubscriptionCandidate] {
        var groups: [String: [Transaction]] = [:]
        for tx in transactions {
            if excludeTransactionIDs.contains(tx.id) { continue }
            let key = Subscription.merchantKey(for: tx.payee)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(tx)
        }

        var out: [DetectedSubscriptionCandidate] = []
        for (key, bucket) in groups {
            let isHinted = hintedMerchantKeys.contains(key)
            // Hinted merchants (the user flagged them in their CSV) only need
            // 2 charges to surface — the human pre-labelled them, so we trust
            // them more than an arbitrary repeat-purchase group.
            let threshold = isHinted ? max(minChargeCount - 1, 2) : minChargeCount
            guard bucket.count >= threshold else { continue }
            let sorted = bucket.sorted { $0.date < $1.date }
            guard var candidate = makeCandidate(merchantKey: key, sorted: sorted) else { continue }
            if isHinted {
                candidate = candidate.boostedByHint()
            }
            out.append(candidate)
        }
        return out
    }

    private static func makeCandidate(
        merchantKey: String,
        sorted: [Transaction]
    ) -> DetectedSubscriptionCandidate? {
        let intervals = consecutiveDayDeltas(sorted)
        guard !intervals.isEmpty else { return nil }

        let intervalStats = stats(of: intervals.map(Double.init))
        // Interval CoV — if spending is scatter-shot (coffee shop visits),
        // intervalCov will be high and we bail out. This is the single most
        // important filter for false positives.
        guard intervalStats.coefficientOfVariation <= intervalVarianceCeiling else { return nil }

        let amounts = sorted.map { NSDecimalNumber(decimal: $0.amount).doubleValue }
        let amountStats = stats(of: amounts)
        guard amountStats.coefficientOfVariation <= amountVarianceCeiling else { return nil }

        let medianInterval = Int(intervalStats.median.rounded())
        let (cycle, customDays) = mapIntervalToCycle(medianInterval)

        // Use the median rather than the mean amount — protects against a
        // one-off promotional charge dragging the average down.
        let amountDecimal = Decimal(amountStats.median)

        let lastDate = sorted.last?.date ?? .now
        let firstDate = sorted.first?.date ?? .now
        let nextDate = predictNextDate(
            lastCharge: lastDate,
            cycle: cycle,
            customDays: customDays
        )

        // Price-change detection: compare the last charge to the median of
        // everything before it. If the last row is > threshold different,
        // flag it and record the percentage change so the UI can badge it.
        let priceChange: (hasChange: Bool, percent: Double?) = {
            guard sorted.count >= 3 else { return (false, nil) }
            let last = amounts.last ?? 0
            let priorMedian = median(of: amounts.dropLast().map { $0 })
            guard priorMedian > 0 else { return (false, nil) }
            let delta = (last - priorMedian) / priorMedian
            return (abs(delta) >= priceChangeThreshold, delta)
        }()

        let confidence = scoreConfidence(
            chargeCount: sorted.count,
            amountCov: amountStats.coefficientOfVariation,
            intervalCov: intervalStats.coefficientOfVariation,
            cycleIsExact: cycle != .custom
        )

        let displayName = bestDisplayName(from: sorted)
        let category = mostCommonCategoryName(in: sorted)
        let currency = "USD" // P9 will read this from the transaction's account

        return DetectedSubscriptionCandidate(
            id: UUID(),
            merchantKey: merchantKey,
            displayName: displayName,
            amount: amountDecimal,
            currency: currency,
            billingCycle: cycle,
            customCadenceDays: customDays,
            confidence: confidence,
            nextPredictedDate: nextDate,
            firstChargeDate: firstDate,
            lastChargeDate: lastDate,
            chargeCount: sorted.count,
            matchingTransactionIDs: sorted.map(\.id),
            amountCoefficientOfVariation: amountStats.coefficientOfVariation,
            intervalCoefficientOfVariation: intervalStats.coefficientOfVariation,
            suggestedCategory: category,
            hasPriceChange: priceChange.hasChange,
            priceChangePercent: priceChange.percent
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

    /// Maps a median interval (days) onto the closest `BillingCycle`. If no
    /// standard cycle is within 20% tolerance we fall back to `.custom` with
    /// the raw day count — better to surface a weird cadence than to silently
    /// snap it to monthly.
    private static func mapIntervalToCycle(_ days: Int) -> (BillingCycle, Int?) {
        let targets: [(BillingCycle, Int)] = [
            (.weekly, 7),
            (.biweekly, 14),
            (.monthly, 30),
            (.quarterly, 91),
            (.semiannual, 182),
            (.annual, 365)
        ]
        for (cycle, target) in targets {
            let tolerance = Double(target) * 0.20
            if abs(Double(days) - Double(target)) <= tolerance {
                return (cycle, nil)
            }
        }
        return (.custom, days)
    }

    private static func predictNextDate(
        lastCharge: Date,
        cycle: BillingCycle,
        customDays: Int?
    ) -> Date {
        let cal = Calendar.current
        switch cycle {
        case .weekly:    return cal.date(byAdding: .weekOfYear, value: 1, to: lastCharge) ?? lastCharge
        case .biweekly:  return cal.date(byAdding: .weekOfYear, value: 2, to: lastCharge) ?? lastCharge
        case .monthly:   return cal.date(byAdding: .month,      value: 1, to: lastCharge) ?? lastCharge
        case .quarterly: return cal.date(byAdding: .month,      value: 3, to: lastCharge) ?? lastCharge
        case .semiannual:return cal.date(byAdding: .month,      value: 6, to: lastCharge) ?? lastCharge
        case .annual:    return cal.date(byAdding: .year,       value: 1, to: lastCharge) ?? lastCharge
        case .custom:    return cal.date(byAdding: .day,        value: max(customDays ?? 30, 1), to: lastCharge) ?? lastCharge
        }
    }

    /// Confidence formula. Starts at 0.4, rewards high charge count, low
    /// amount variance, low interval variance, and an exact standard cycle.
    /// Caps at 0.95 — never claim total certainty on a heuristic match.
    private static func scoreConfidence(
        chargeCount: Int,
        amountCov: Double,
        intervalCov: Double,
        cycleIsExact: Bool
    ) -> Double {
        var score = 0.4
        if chargeCount >= 3 { score += 0.1 }
        if chargeCount >= 5 { score += 0.1 }
        if chargeCount >= 8 { score += 0.05 }
        if amountCov <= 0.10 { score += 0.15 } else if amountCov <= 0.20 { score += 0.05 }
        if intervalCov <= 0.10 { score += 0.15 } else if intervalCov <= 0.20 { score += 0.05 }
        if cycleIsExact { score += 0.05 }
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
