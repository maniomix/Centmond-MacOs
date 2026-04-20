import Foundation
import SwiftData

/// Self-correction layer for `RecurringTransaction` templates. Two
/// independent passes:
///
/// 1. **Drift correction** — when the most recent N linked transactions
///    all land at a new price (rent went up, Netflix raised the
///    subscription, etc.), update the template's `amount` so future
///    synthetic materializations match reality. Only considers the
///    chronologically-latest cluster — older syntheticised values would
///    bias the median toward the stale price and mask the change.
///
/// 2. **Stale auto-pause** — when a template's last N expected
///    occurrence dates all have ZERO linked transactions (neither
///    manual nor surviving synthetic), the user is clearly not paying
///    this any more. Auto-pause and let them resume manually if the
///    pause was wrong.
///
/// Both passes run inside `RecurringScheduler.tick` AFTER linking (so
/// freshly-linked manual transactions feed the drift signal) and AFTER
/// materializing (so stale check sees the most current `nextOccurrence`).
enum RecurringDriftService {

    // MARK: - Tunables

    /// How many of the most recent linked transactions to inspect for
    /// drift. Three is the sweet spot — single-cycle changes get noise
    /// rejected; five-plus is too slow to react to a real price hike.
    static let driftSampleSize: Int = 3

    /// All N samples must be within ±this of each other before we treat
    /// them as a coherent new price. Stops a single outlier (refund,
    /// promotional charge) from flipping the template.
    static let driftClusterTolerance: Decimal = Decimal(0.05)

    /// Minimum delta from `template.amount` before we update. Below this
    /// the change is in noise territory.
    static let driftCorrectionThreshold: Decimal = Decimal(0.10)

    /// Number of consecutive expected occurrences with zero linked
    /// transactions before a template is auto-paused. Three cycles =
    /// one full quarter for monthly templates, conservative.
    static let staleMissCount: Int = 3

    // MARK: - Public API

    @MainActor
    @discardableResult
    static func correctDrift(in context: ModelContext) -> Int {
        guard isDriftEnabled else { return 0 }
        let descriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive }
        )
        guard let templates = try? context.fetch(descriptor), !templates.isEmpty else { return 0 }

        var corrected = 0
        for template in templates {
            if applyDrift(to: template, in: context) {
                corrected += 1
            }
        }
        return corrected
    }

    @MainActor
    @discardableResult
    static func autoPauseStale(in context: ModelContext, asOf: Date = .now) -> Int {
        guard isStaleAutoPauseEnabled else { return 0 }
        let descriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive }
        )
        guard let templates = try? context.fetch(descriptor), !templates.isEmpty else { return 0 }

        var paused = 0
        for template in templates {
            if shouldAutoPause(template, in: context, asOf: asOf) {
                template.isActive = false
                paused += 1
            }
        }
        return paused
    }

    // MARK: - Settings-backed tunables

    /// Master switch — disabling stops all auto-amount changes. Defaults
    /// to true (rent rises silently, the user shouldn't have to chase it).
    static var isDriftEnabled: Bool {
        UserDefaults.standard.object(forKey: "recurringDriftEnabled") as? Bool ?? true
    }

    /// Minimum delta from current `template.amount` (as a fraction)
    /// before drift correction kicks in. Lower = more sensitive. Clamped
    /// to 0.02...0.50 so a misconfigured value never thrashes templates
    /// (too low) or makes drift effectively impossible (too high).
    static var effectiveDriftThreshold: Decimal {
        let raw = UserDefaults.standard.object(forKey: "recurringDriftThreshold") as? Double
            ?? NSDecimalNumber(decimal: driftCorrectionThreshold).doubleValue
        return Decimal(min(max(raw, 0.02), 0.50))
    }

    /// Master switch for auto-pause. Off by default would defeat the
    /// "automatic" promise; on by default with conservative N=3 cycles.
    static var isStaleAutoPauseEnabled: Bool {
        UserDefaults.standard.object(forKey: "recurringStaleAutoPauseEnabled") as? Bool ?? true
    }

    /// Number of consecutive empty cycles before auto-pause. Clamped to
    /// 2...12 so the user can't zero this out (would pause everything
    /// instantly) or push it so high it never fires.
    static var effectiveStaleMissCount: Int {
        let raw = UserDefaults.standard.object(forKey: "recurringStaleMissCount") as? Int
            ?? staleMissCount
        return min(max(raw, 2), 12)
    }

    // MARK: - Drift internals

    @MainActor
    private static func applyDrift(to template: RecurringTransaction, in context: ModelContext) -> Bool {
        let templateID = template.id
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { tx in
                tx.recurringTemplateID == templateID
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        guard let recent = try? context.fetch(descriptor),
              recent.count >= driftSampleSize else { return false }

        let sample = Array(recent.prefix(driftSampleSize))
        let amounts = sample.map(\.amount)

        // All samples must agree with each other to within tolerance —
        // otherwise the cluster isn't coherent and we don't know what
        // the new price actually is.
        guard let minAmt = amounts.min(), let maxAmt = amounts.max(), minAmt > 0 else { return false }
        let spread = (maxAmt - minAmt) / minAmt
        guard spread <= driftClusterTolerance else { return false }

        // Use median of the cluster as the proposed new amount.
        let sortedAmounts = amounts.sorted()
        let newAmount = sortedAmounts[sortedAmounts.count / 2]

        guard template.amount > 0 else { return false }
        let delta = (newAmount - template.amount).magnitude / template.amount
        guard delta >= Self.effectiveDriftThreshold else { return false }

        template.amount = newAmount
        return true
    }

    // MARK: - Stale internals

    @MainActor
    private static func shouldAutoPause(_ template: RecurringTransaction, in context: ModelContext, asOf: Date) -> Bool {
        // Walk backward from `nextOccurrence` to enumerate the last N
        // expected cycles. (We can't go further back than the template
        // has existed; bail if `createdAt` is too recent.)
        let cal = Calendar.current
        let missCount = effectiveStaleMissCount
        guard let earliestPossible = cal.date(byAdding: .day, value: -missCount * 31 * 4, to: asOf),
              template.createdAt < earliestPossible else { return false }

        let cycles = expectedOccurrences(
            template: template,
            count: missCount,
            endingBefore: asOf
        )
        guard cycles.count == missCount else { return false }

        let templateID = template.id
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { tx in
                tx.recurringTemplateID == templateID
            }
        )
        guard let linked = try? context.fetch(descriptor) else { return false }

        // For each expected cycle, check if ANY linked transaction sits
        // within ±3 days. A single hit per cycle is enough to keep the
        // template alive.
        for cycle in cycles {
            guard let lower = cal.date(byAdding: .day, value: -3, to: cycle),
                  let upper = cal.date(byAdding: .day, value:  3, to: cycle) else { return false }
            let hit = linked.contains { $0.date >= lower && $0.date <= upper }
            if hit { return false }
        }
        return true
    }

    /// Walk the template's frequency BACKWARD from `nextOccurrence` to
    /// enumerate the most recent `count` expected cycles whose date is
    /// strictly before `endingBefore`. Returned newest-first.
    private static func expectedOccurrences(
        template: RecurringTransaction,
        count: Int,
        endingBefore: Date
    ) -> [Date] {
        var out: [Date] = []
        let cal = Calendar.current
        var cursor = template.nextOccurrence
        while cursor >= endingBefore {
            cursor = previousDate(after: cursor, frequency: template.frequency, calendar: cal)
            if cursor == endingBefore { break }
        }
        var safety = 0
        while out.count < count && safety < count * 4 {
            out.append(cursor)
            cursor = previousDate(after: cursor, frequency: template.frequency, calendar: cal)
            safety += 1
        }
        return out
    }

    private static func previousDate(after date: Date, frequency: RecurrenceFrequency, calendar: Calendar) -> Date {
        switch frequency {
        case .weekly:    return calendar.date(byAdding: .weekOfYear, value: -1, to: date) ?? date
        case .biweekly:  return calendar.date(byAdding: .weekOfYear, value: -2, to: date) ?? date
        case .monthly:   return calendar.date(byAdding: .month,      value: -1, to: date) ?? date
        case .quarterly: return calendar.date(byAdding: .month,      value: -3, to: date) ?? date
        case .annual:    return calendar.date(byAdding: .year,       value: -1, to: date) ?? date
        }
    }
}

private extension Decimal {
    var magnitude: Decimal { self < 0 ? -self : self }
}
