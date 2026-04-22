import Foundation
import SwiftData

/// Materializes `RecurringTransaction` templates into real `Transaction`
/// rows once their `nextOccurrence` is due, links manually-entered
/// transactions back to matching templates so we never double-count, and
/// auto-approves stale materializations after a grace period.
///
/// As of the 2026-04 Recurring rebuild every active template runs
/// automatically. The legacy `autoCreate` flag is ignored — it is left on
/// the model for SwiftData migration safety only.
///
/// Pipeline (per scheduler tick, in order):
///   1. `linkPendingMatches` — scan recent unlinked manual transactions,
///      attach them to active templates whose `nextOccurrence` they
///      satisfy, and advance the template forward one step.
///   2. `materializeDue` — for each active template still overdue after
///      linking, insert a new `Transaction` for every missed occurrence
///      and advance `nextOccurrence` until it is in the future.
///   3. `autoApproveStaleMaterializations` — flip `isReviewed = true` on
///      template-sourced transactions older than the configured grace
///      window so the Review Queue does not pile up.
enum RecurringService {

    // MARK: - Tunables

    /// Hard cap so a misconfigured template (e.g. nextOccurrence in 1970)
    /// cannot lock the app generating thousands of rows in one tick.
    private static let maxOccurrencesPerRun = 60

    /// Amount tolerance used by the matcher. ±5% covers most real-world
    /// drift (tax changes, exchange-rate jitter) without crossing into
    /// "different transaction entirely" territory.
    private static let amountTolerance: Decimal = Decimal(0.05)

    /// Date window used by the matcher (±N days around the template's
    /// `nextOccurrence`). Three days is wide enough to absorb weekend
    /// settlement delays without crossing into adjacent cycles.
    private static let dateToleranceDays = 3

    // MARK: - Materialization

    /// Insert a new `Transaction` for every overdue occurrence of every
    /// active template. Idempotent — advances each template's
    /// `nextOccurrence` per insert so a second call within the same
    /// session is a no-op.
    @discardableResult
    static func materializeDue(in context: ModelContext, asOf: Date = .now) -> Int {
        let descriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive }
        )
        guard let templates = try? context.fetch(descriptor) else { return 0 }

        var touchedAccounts: Set<UUID> = []
        var accountLookup: [UUID: Account] = [:]
        var produced = 0

        for template in templates {
            let count = run(template, upTo: asOf, in: context)
            produced += count
            if count > 0, let acc = template.account {
                touchedAccounts.insert(acc.id)
                accountLookup[acc.id] = acc
            }
        }
        for id in touchedAccounts {
            if let acc = accountLookup[id] {
                BalanceService.recalculate(account: acc)
            }
        }
        return produced
    }

    /// Manual single-template fire. Retained for the AI action executor
    /// so the assistant can ask for an immediate run without waiting for
    /// the next scheduler tick.
    @discardableResult
    static func materializeOne(_ template: RecurringTransaction,
                               in context: ModelContext,
                               asOf: Date = .now) -> Int {
        guard template.isActive else { return 0 }
        let count = run(template, upTo: asOf, in: context)
        if count > 0, let acc = template.account {
            BalanceService.recalculate(account: acc)
        }
        return count
    }

    // MARK: - Linking

    /// Scan recently-created, unreviewed, unlinked transactions and pair
    /// them with active templates whose next occurrence they satisfy.
    /// When a manual transaction matches a template, we tag it with the
    /// template ID and advance the template's `nextOccurrence` instead
    /// of letting `materializeDue` create a duplicate row.
    @discardableResult
    static func linkPendingMatches(in context: ModelContext, asOf: Date = .now) -> Int {
        let descriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive }
        )
        guard let templates = try? context.fetch(descriptor), !templates.isEmpty else { return 0 }

        // Pull a 60-day window of candidate transactions. Anything older
        // than that has already been past several scheduler ticks and is
        // unlikely to be a missed link; capping the fetch keeps this
        // cheap on large stores.
        let window = Calendar.current.date(byAdding: .day, value: -60, to: asOf) ?? asOf
        let txDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { tx in
                tx.recurringTemplateID == nil
                && tx.isTransfer == false
                && tx.date >= window
            }
        )
        guard let candidates = try? context.fetch(txDescriptor), !candidates.isEmpty else { return 0 }

        var linked = 0
        let cal = Calendar.current

        // Pre-bucket candidates: split by isIncome, pre-normalize payees,
        // sort by date ascending. The inner-loop used to walk the full
        // candidate array for every (template, occurrence) pair and call
        // `normalize` on both strings every match — O(T × O × C) with a
        // heavy allocation per hop. With this prep, each occurrence walks
        // only same-sign candidates, compares normalized strings, and
        // an O(log C) date lower-bound trims even that.
        struct PreppedCandidate {
            let tx: Transaction
            let date: Date
            let amount: Decimal
            let isIncome: Bool
            let normalizedPayee: String
        }
        let prepped: [PreppedCandidate] = candidates
            .map { PreppedCandidate(tx: $0, date: $0.date, amount: $0.amount, isIncome: $0.isIncome, normalizedPayee: normalize($0.payee)) }
            .sorted { $0.date < $1.date }

        // Split by sign so each template only scans the matching half.
        let incomeBucket = prepped.filter { $0.isIncome }
        let expenseBucket = prepped.filter { !$0.isIncome }

        // Mark-linked set so the inner scans don't re-match an already-
        // linked candidate across templates.
        var consumedTxIDs: Set<UUID> = []

        for template in templates {
            let bucket = template.isIncome ? incomeBucket : expenseBucket
            if bucket.isEmpty { continue }
            let templateKey = normalize(template.name)
            if templateKey.isEmpty { continue }

            var advanced = 0
            while template.nextOccurrence <= asOf && advanced < maxOccurrencesPerRun {
                let target = template.nextOccurrence
                guard let lower = cal.date(byAdding: .day, value: -dateToleranceDays, to: target),
                      let upper = cal.date(byAdding: .day, value:  dateToleranceDays, to: target) else { break }

                // Date-sorted bucket + linear scan with break-on-date.
                // (Binary search would trim further but bucket is usually
                // a few hundred items; this already removes the O(N×M).)
                var match: PreppedCandidate?
                for c in bucket {
                    if c.date < lower { continue }
                    if c.date > upper { break }
                    if consumedTxIDs.contains(c.tx.id) { continue }
                    if c.tx.recurringTemplateID != nil { continue }
                    if !amountMatches(c.amount, template.amount) { continue }
                    let na = c.normalizedPayee
                    if na.isEmpty { continue }
                    if na == templateKey || na.contains(templateKey) || templateKey.contains(na) {
                        match = c
                        break
                    }
                }

                guard let hit = match else { break }
                hit.tx.recurringTemplateID = template.id
                hit.tx.updatedAt = .now
                consumedTxIDs.insert(hit.tx.id)
                template.lastMaterializedDate = target
                template.nextOccurrence = template.frequency.nextDate(after: target)
                linked += 1
                advanced += 1
            }
        }
        return linked
    }

    // MARK: - Auto-approve

    /// Mark template-sourced transactions older than `graceDays` as
    /// reviewed so the Review Queue does not accumulate routine items.
    /// Grace period defaults to 7 days; user-configurable via the
    /// `recurringAutoApproveDays` UserDefaults key (0 disables).
    @discardableResult
    static func autoApproveStaleMaterializations(in context: ModelContext, asOf: Date = .now) -> Int {
        let graceDays = UserDefaults.standard.object(forKey: "recurringAutoApproveDays") as? Int ?? 7
        guard graceDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -graceDays, to: asOf) else {
            return 0
        }
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { tx in
                tx.recurringTemplateID != nil
                && tx.isReviewed == false
                && tx.createdAt <= cutoff
            }
        )
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return 0 }
        for tx in stale {
            tx.isReviewed = true
            tx.updatedAt = .now
        }
        return stale.count
    }

    // MARK: - Internals

    private static func run(_ template: RecurringTransaction,
                            upTo asOf: Date,
                            in context: ModelContext) -> Int {
        var produced = 0
        while template.nextOccurrence <= asOf && produced < maxOccurrencesPerRun {
            let occurrenceDate = template.nextOccurrence
            let tx = Transaction(
                date: occurrenceDate,
                payee: template.name,
                amount: template.amount,
                notes: nil,
                isIncome: template.isIncome,
                status: .cleared,
                isReviewed: false,
                account: template.account,
                category: template.category
            )
            tx.recurringTemplateID = template.id
            // Inherit household attribution from the template (P2). Falls back
            // to the payee-learner so long-running templates benefit from any
                // manual corrections the user made to past materializations.
            tx.householdMember = template.householdMember
                ?? HouseholdService.resolveMember(forPayee: template.name, in: context)
            context.insert(tx)
            template.lastMaterializedDate = occurrenceDate
            template.nextOccurrence = template.frequency.nextDate(after: occurrenceDate)
            produced += 1
        }
        return produced
    }

    private static func amountMatches(_ a: Decimal, _ b: Decimal) -> Bool {
        guard b > 0 else { return a == b }
        let diff = (a - b).magnitude
        return diff / b <= amountTolerance
    }

    private static func payeeMatches(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na == nb || na.contains(nb) || nb.contains(na)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

private extension Decimal {
    var magnitude: Decimal { self < 0 ? -self : self }
}

// MARK: - RecurrenceFrequency forward step

extension RecurrenceFrequency {
    /// Single-step forward advance. Used by the materializer to walk
    /// occurrence dates one frequency at a time.
    func nextDate(after date: Date) -> Date {
        let cal = Calendar.current
        switch self {
        case .weekly:    return cal.date(byAdding: .weekOfYear, value: 1,  to: date) ?? date
        case .biweekly:  return cal.date(byAdding: .weekOfYear, value: 2,  to: date) ?? date
        case .monthly:   return cal.date(byAdding: .month,      value: 1,  to: date) ?? date
        case .quarterly: return cal.date(byAdding: .month,      value: 3,  to: date) ?? date
        case .annual:    return cal.date(byAdding: .year,       value: 1,  to: date) ?? date
        }
    }
}
