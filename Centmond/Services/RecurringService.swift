import Foundation
import SwiftData

/// Materializes `RecurringTransaction` templates into real `Transaction`
/// rows once their `nextOccurrence` is due. The single source of truth
/// for the "auto-create" pipeline so the rules are not duplicated across
/// the recurring view, app launch, or manual run buttons.
///
/// Rules:
///   - Only `isActive == true` items participate.
///   - `materializeDue` only touches items with `autoCreate == true`.
///     Manual runs (`materializeOne`) bypass that flag so the user can
///     fire a paused-auto template on demand.
///   - For each due occurrence we insert a Transaction, advance
///     `nextOccurrence` by one frequency step, and repeat until
///     `nextOccurrence > asOf`. This catches up overdue items in a
///     single pass after the app has been closed for a while.
///   - Materialized transactions are inserted as `cleared` and
///     `unreviewed`, so the Review Queue picks them up for the user to
///     confirm before they pollute analytics.
///   - Account balances are recalculated for every account that
///     received at least one new transaction.
enum RecurringService {

    /// Run the materializer for every eligible template. `asOf` is
    /// injectable for tests; production callers pass `.now`.
    @discardableResult
    static func materializeDue(in context: ModelContext, asOf: Date = .now) -> Int {
        let descriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive && $0.autoCreate }
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

    /// Manually fire a single template — used by the "Run Now" action in
    /// the recurring view. Bypasses `autoCreate` so the user can produce
    /// a one-off occurrence without flipping the flag.
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

    // MARK: - Internals

    /// Insert one Transaction per overdue occurrence and advance the
    /// template's `nextOccurrence` by one frequency step each time.
    private static func run(_ template: RecurringTransaction,
                            upTo asOf: Date,
                            in context: ModelContext) -> Int {
        var produced = 0
        // Hard cap so a misconfigured template (e.g. nextOccurrence in
        // 1970) cannot lock the app up generating thousands of rows.
        let maxOccurrencesPerRun = 60

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
            context.insert(tx)
            template.lastMaterializedDate = occurrenceDate
            template.nextOccurrence = template.frequency.nextDate(after: occurrenceDate)
            produced += 1
        }
        return produced
    }
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
