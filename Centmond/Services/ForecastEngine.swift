import Foundation

/// Produces a per-day financial forecast over a configurable horizon.
///
/// Pure compute — no SwiftData fetches. Callers pass already-filtered
/// inputs (`ForecastInputs`) and receive a single typed `ForecastHorizon`
/// the UI can render directly: a running balance line, a P10/P90
/// confidence band, a per-day event list, and summary stats (lowest
/// balance, first negative date, etc.) for risk chips and narrative.
///
/// The engine models three sources of balance change:
///
///   1. **Known events** — active subscription charges and active
///      recurring bills/income projected forward from their next
///      due-date using the shared cadence math.
///   2. **Goal contributions** — active goals with a `monthlyContribution`
///      project a single outflow on the same day-of-month as today,
///      for every month in the horizon. (The goals rebuild memory
///      notes that contributions are scheduled, not automated yet —
///      so this is a "planned" leg, not a guaranteed one.)
///   3. **Variable discretionary spend** — a flat daily mean from the
///      trailing `baselineWindowDays` of history (excluding transfers,
///      subscription-linked, and recurring-linked transactions).
///      Phase 1 uses a single mean + standard deviation to form the
///      P10/P90 band; Phase 2 will upgrade this to weekday-aware and
///      category-aware baselines.
///
/// The band is *only* the discretionary layer — known events are
/// deterministic and do not widen it.
enum ForecastEngine {

    // MARK: - Inputs

    struct Inputs {
        /// Sum of eligible account balances at horizon start (day 0).
        /// Callers mirror whichever account-filter rule drives the
        /// rest of the app (e.g. `!archived && !closed && includeInNetWorth`).
        var startingBalance: Decimal

        /// Active subscriptions. The engine projects upcoming charges
        /// via `SubscriptionForecast` so cadence logic stays in one place.
        var subscriptions: [Subscription]

        /// Active recurring bills + income templates. The engine walks
        /// their `nextOccurrence` forward using `RecurrenceFrequency.nextDate(after:)`.
        var recurring: [RecurringTransaction]

        /// Active goals with a `monthlyContribution` set. One outflow
        /// per calendar month inside the horizon.
        var goals: [Goal]

        /// Historical transactions used to fit the discretionary
        /// baseline. Safe to pass everything — the engine filters to
        /// the baseline window and excludes non-discretionary legs.
        var history: [Transaction]

        /// Trailing window (days) for the discretionary baseline fit.
        /// 60 is long enough to smooth weekday noise without leaking
        /// stale behavior from several cycles ago.
        var baselineWindowDays: Int = 60

        /// Anchor for "today". Injected so tests can pin it.
        var asOf: Date = .now
    }

    // MARK: - Outputs

    enum EventKind: String {
        case subscription
        case recurringBill
        case recurringIncome
        case goalContribution
    }

    struct Event: Identifiable, Hashable {
        let id: UUID
        let date: Date
        let name: String
        /// Signed — positive for income, negative for outflow.
        let delta: Decimal
        let kind: EventKind
        let iconSymbol: String
        let sourceID: UUID?

        static func == (lhs: Event, rhs: Event) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    struct Day: Hashable {
        /// Calendar-start-of-day.
        let date: Date
        /// Days from `asOf` (0 = today).
        let dayOffset: Int
        /// Deterministic ending balance assuming the mean discretionary
        /// draw for the day. This is the "line" on the chart.
        let expectedBalance: Decimal
        /// P10 — low end of the cone (bad luck).
        let lowBalance: Decimal
        /// P90 — high end of the cone (thrifty day).
        let highBalance: Decimal
        /// Events that hit on this day. Sorted income-first, then outflow
        /// by magnitude so the timeline reads naturally.
        let events: [Event]
        /// Mean discretionary outflow applied this day.
        let discretionary: Decimal
        /// What's left after today's obligations + typical spend —
        /// handy for the "safe to spend today" row the dashboard
        /// already shows in aggregate.
        let safeToSpend: Decimal
    }

    struct Summary {
        let horizonDays: Int
        let startingBalance: Decimal
        let endingExpectedBalance: Decimal
        let lowestExpectedBalance: Decimal
        let lowestExpectedBalanceDate: Date
        /// First day where the P10 band dips below zero — the
        /// earliest plausible overdraft. `nil` if the cone stays positive.
        let firstAtRiskDate: Date?
        /// First day where the *expected* line dips below zero.
        let firstExpectedNegativeDate: Date?
        let totalProjectedObligations: Decimal
        let totalProjectedIncome: Decimal
        let totalProjectedDiscretionary: Decimal
        let dailyDiscretionaryMean: Decimal
        let dailyDiscretionaryStdDev: Decimal
    }

    struct Horizon {
        let days: [Day]
        let summary: Summary
    }

    // MARK: - Scenario

    /// A lightweight set of tweaks applied to `Inputs` at build time —
    /// the P6 what-if simulator. The view holds one of these in `@State`,
    /// updates it via toggles/sliders, and calls `build(..., scenario:)`
    /// to get a parallel horizon it can overlay on the baseline chart.
    struct Scenario: Equatable {
        /// Subscriptions to treat as cancelled.
        var skippedSubscriptionIDs: Set<UUID> = []
        /// Recurring templates to treat as paused.
        var skippedRecurringIDs: Set<UUID> = []
        /// Goals whose contribution should be skipped.
        var skippedGoalIDs: Set<UUID> = []
        /// Multiplier applied to every weekday-bucket mean — 0.8 means
        /// "spend 20% less than usual". Clamped ≥ 0.
        var spendMultiplier: Double = 1.0
        /// Ad-hoc events to inject. Negative delta = expense, positive = income.
        var oneOffs: [OneOff] = []

        struct OneOff: Identifiable, Equatable {
            let id: UUID
            let date: Date
            let delta: Decimal
            let label: String

            init(id: UUID = UUID(), date: Date, delta: Decimal, label: String) {
                self.id = id
                self.date = date
                self.delta = delta
                self.label = label
            }
        }

        var isIdentity: Bool {
            skippedSubscriptionIDs.isEmpty
                && skippedRecurringIDs.isEmpty
                && skippedGoalIDs.isEmpty
                && abs(spendMultiplier - 1.0) < 0.001
                && oneOffs.isEmpty
        }
    }

    // MARK: - Monthly breakdown

    enum MonthRisk {
        /// Expected line stays comfortably positive.
        case healthy
        /// Lowest balance dips into the buffer zone (P10 < 0 but
        /// expected ≥ 0) — plausible overdraft on a bad week.
        case tight
        /// Expected balance itself goes negative inside this month.
        case overdraft
    }

    struct MonthSummary: Identifiable {
        var id: Date { monthStart }
        let monthStart: Date
        /// Calendar-end-of-month (last instant of the month).
        let monthEnd: Date
        let daysIncluded: Int
        let startingBalance: Decimal
        let endingBalance: Decimal
        let lowestBalance: Decimal
        let lowestBalanceDate: Date
        let income: Decimal
        let obligations: Decimal
        let discretionary: Decimal
        /// Signed: income − obligations − discretionary.
        let net: Decimal
        /// Largest single outflow event in the month (if any).
        let biggestEvent: Event?
        let risk: MonthRisk
    }


    // MARK: - Entry point

    static func build(_ inputs: Inputs, horizonDays: Int, scenario: Scenario = Scenario()) -> Horizon {
        let cal = Calendar.current
        let today = cal.startOfDay(for: inputs.asOf)
        let horizon = max(1, horizonDays)
        let end = cal.date(byAdding: .day, value: horizon, to: today) ?? today
        let spendMult = max(0, scenario.spendMultiplier)

        // --- Baseline fit ---------------------------------------------------
        let baseline = fitWeekdayBaseline(
            history: inputs.history,
            asOf: today,
            windowDays: inputs.baselineWindowDays,
            calendar: cal
        )

        // --- Collect future events -----------------------------------------
        var eventsByDay: [Date: [Event]] = [:]

        let activeSubs = inputs.subscriptions.filter { !scenario.skippedSubscriptionIDs.contains($0.id) }
        for charge in SubscriptionForecast.upcomingCharges(
            for: activeSubs,
            from: today,
            to: end,
            includeTrialEnds: false
        ) where charge.amount > 0 {
            let day = cal.startOfDay(for: charge.date)
            eventsByDay[day, default: []].append(Event(
                id: charge.id,
                date: day,
                name: charge.displayName,
                delta: -charge.amount,
                kind: .subscription,
                iconSymbol: charge.iconSymbol ?? "arrow.triangle.2.circlepath",
                sourceID: charge.subscriptionID
            ))
        }

        for tpl in inputs.recurring where tpl.isActive && !scenario.skippedRecurringIDs.contains(tpl.id) {
            var cursor = tpl.nextOccurrence
            var safety = 0
            while cursor <= end, safety < 500 {
                if cursor >= today {
                    let day = cal.startOfDay(for: cursor)
                    let signed: Decimal = tpl.isIncome ? tpl.amount : -tpl.amount
                    eventsByDay[day, default: []].append(Event(
                        id: UUID(),
                        date: day,
                        name: tpl.name,
                        delta: signed,
                        kind: tpl.isIncome ? .recurringIncome : .recurringBill,
                        iconSymbol: tpl.isIncome ? "arrow.down.circle" : "repeat",
                        sourceID: tpl.id
                    ))
                }
                let next = tpl.frequency.nextDate(after: cursor)
                if next <= cursor { break }
                cursor = next
                safety += 1
            }
        }

        for goal in inputs.goals where goal.status == .active && !scenario.skippedGoalIDs.contains(goal.id) {
            guard let contribution = goal.monthlyContribution, contribution > 0 else { continue }
            // One draw per calendar month inside the horizon, anchored
            // to today's day-of-month (so a horizon starting on the 15th
            // projects goal contributions on the 15th of each month).
            var cursor = today
            var safety = 0
            while cursor <= end, safety < 24 {
                if cursor >= today {
                    let day = cal.startOfDay(for: cursor)
                    eventsByDay[day, default: []].append(Event(
                        id: UUID(),
                        date: day,
                        name: goal.name,
                        delta: -contribution,
                        kind: .goalContribution,
                        iconSymbol: goal.icon.isEmpty ? "target" : goal.icon,
                        sourceID: goal.id
                    ))
                }
                guard let next = cal.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
                safety += 1
            }
        }

        for oneOff in scenario.oneOffs where oneOff.date >= today && oneOff.date <= end {
            let day = cal.startOfDay(for: oneOff.date)
            eventsByDay[day, default: []].append(Event(
                id: oneOff.id,
                date: day,
                name: oneOff.label,
                delta: oneOff.delta,
                kind: oneOff.delta > 0 ? .recurringIncome : .recurringBill,
                iconSymbol: oneOff.delta > 0 ? "plus.circle" : "minus.circle",
                sourceID: nil
            ))
        }

        // --- Walk the horizon day by day -----------------------------------
        var expected = inputs.startingBalance
        var low = inputs.startingBalance
        var high = inputs.startingBalance
        var days: [Day] = []

        var totalObligations: Decimal = 0
        var totalIncome: Decimal = 0
        var totalDiscretionary: Decimal = 0
        var lowestExpected = inputs.startingBalance
        var lowestExpectedDate = today
        var firstAtRisk: Date?
        var firstExpectedNegative: Date?

        days.reserveCapacity(horizon + 1)

        // Day 0 — no draw yet, just the starting snapshot.
        days.append(Day(
            date: today,
            dayOffset: 0,
            expectedBalance: expected,
            lowBalance: low,
            highBalance: high,
            events: sortEvents(eventsByDay[today] ?? []),
            discretionary: 0,
            safeToSpend: expected
        ))

        for offset in 1...horizon {
            guard let date = cal.date(byAdding: .day, value: offset, to: today) else { break }
            let dayKey = cal.startOfDay(for: date)
            let dayEvents = sortEvents(eventsByDay[dayKey] ?? [])

            let eventDelta = dayEvents.reduce(Decimal.zero) { $0 + $1.delta }
            let incomeToday = dayEvents.filter { $0.delta > 0 }.reduce(Decimal.zero) { $0 + $1.delta }
            let outflowToday = dayEvents.filter { $0.delta < 0 }.reduce(Decimal.zero) { $0 - $1.delta }

            totalIncome += incomeToday
            totalObligations += outflowToday

            let bucket = baseline.bucket(for: dayKey, calendar: cal)
            let multiplier = Decimal(spendMult)
            let mean = bucket.mean * multiplier
            let stdev = bucket.stdev * multiplier
            totalDiscretionary += mean

            expected += eventDelta - mean
            // The band widens through the discretionary layer only —
            // events are deterministic. σ accumulates linearly here for
            // display legibility; a real distribution would scale as
            // sqrt(days). Tracked for a later refinement.
            low += eventDelta - (mean + stdev)
            high += eventDelta - max(Decimal.zero, mean - stdev)

            if expected < lowestExpected {
                lowestExpected = expected
                lowestExpectedDate = dayKey
            }
            if firstAtRisk == nil, low < 0 { firstAtRisk = dayKey }
            if firstExpectedNegative == nil, expected < 0 { firstExpectedNegative = dayKey }

            days.append(Day(
                date: dayKey,
                dayOffset: offset,
                expectedBalance: expected,
                lowBalance: low,
                highBalance: high,
                events: dayEvents,
                discretionary: mean,
                safeToSpend: expected
            ))
        }

        let summary = Summary(
            horizonDays: horizon,
            startingBalance: inputs.startingBalance,
            endingExpectedBalance: expected,
            lowestExpectedBalance: lowestExpected,
            lowestExpectedBalanceDate: lowestExpectedDate,
            firstAtRiskDate: firstAtRisk,
            firstExpectedNegativeDate: firstExpectedNegative,
            totalProjectedObligations: totalObligations,
            totalProjectedIncome: totalIncome,
            totalProjectedDiscretionary: totalDiscretionary,
            dailyDiscretionaryMean: baseline.pooled.mean,
            dailyDiscretionaryStdDev: baseline.pooled.stdev
        )

        return Horizon(days: days, summary: summary)
    }

    // MARK: - Baseline fit

    /// Pooled (single) mean + σ for a window of daily discretionary
    /// values. Used as a fallback when a weekday has too few samples
    /// to fit its own bucket, and as the headline number in `Summary`.
    struct Baseline: Equatable {
        let mean: Decimal
        let stdev: Decimal
        let sampleDays: Int
    }

    /// Per-weekday baseline — seven buckets keyed by
    /// `Calendar.component(.weekday, from:)` (1 = Sunday … 7 = Saturday).
    /// Buckets with fewer than `minSamplesPerBucket` observations fall
    /// through to the pooled baseline so a quiet weekday doesn't
    /// produce a wild stdev from a single $400 weekend purchase.
    struct WeekdayBaseline: Equatable {
        static let minSamplesPerBucket = 3
        let byWeekday: [Int: Baseline]
        let pooled: Baseline

        func bucket(for date: Date, calendar: Calendar) -> Baseline {
            let wd = calendar.component(.weekday, from: date)
            if let b = byWeekday[wd], b.sampleDays >= Self.minSamplesPerBucket {
                return b
            }
            return pooled
        }
    }

    /// Weekday-aware fit: groups daily discretionary totals by
    /// `Calendar.component(.weekday, …)` and computes per-bucket
    /// mean + population σ, plus a pooled baseline for fallback and
    /// summary stats. Discretionary = spending expense (per
    /// `BalanceService`) that is NOT tied to a recurring template.
    /// Zero-spend days are included in every bucket so dry weekdays
    /// don't over-inflate their own mean.
    ///
    /// Subscription-tied historical transactions currently have no
    /// back-link to `Subscription`, so if a sub charge appears in
    /// discretionary history it will be double-counted against the
    /// future sub event. A later phase should add `subscriptionID` to
    /// `Transaction` to tighten this.
    static func fitWeekdayBaseline(
        history: [Transaction],
        asOf: Date,
        windowDays: Int,
        calendar: Calendar = .current
    ) -> WeekdayBaseline {
        let today = calendar.startOfDay(for: asOf)
        guard let windowStart = calendar.date(byAdding: .day, value: -max(1, windowDays), to: today) else {
            return WeekdayBaseline(byWeekday: [:], pooled: Baseline(mean: 0, stdev: 0, sampleDays: 0))
        }

        var totalsByDay: [Date: Decimal] = [:]
        for tx in history {
            guard BalanceService.isSpendingExpense(tx) else { continue }
            guard tx.recurringTemplateID == nil else { continue }
            guard tx.date >= windowStart, tx.date < today else { continue }
            let day = calendar.startOfDay(for: tx.date)
            totalsByDay[day, default: 0] += tx.amount
        }

        // Build a per-day value array first — includes zero-spend days
        // so means and σ are honest about quiet stretches.
        let days = max(1, calendar.dateComponents([.day], from: windowStart, to: today).day ?? windowDays)
        var perWeekday: [Int: [Decimal]] = [:]
        var pooledValues: [Decimal] = []
        pooledValues.reserveCapacity(days)

        for offset in 0..<days {
            guard let d = calendar.date(byAdding: .day, value: offset, to: windowStart) else { continue }
            let dayKey = calendar.startOfDay(for: d)
            let value = totalsByDay[dayKey] ?? 0
            pooledValues.append(value)
            let wd = calendar.component(.weekday, from: dayKey)
            perWeekday[wd, default: []].append(value)
        }

        let pooled = baseline(from: pooledValues)
        var buckets: [Int: Baseline] = [:]
        for (wd, values) in perWeekday {
            buckets[wd] = baseline(from: values)
        }
        return WeekdayBaseline(byWeekday: buckets, pooled: pooled)
    }

    private static func baseline(from values: [Decimal]) -> Baseline {
        guard !values.isEmpty else { return Baseline(mean: 0, stdev: 0, sampleDays: 0) }
        let mean = values.reduce(Decimal.zero, +) / Decimal(values.count)
        let variance = values.reduce(Decimal.zero) { acc, v in
            let diff = v - mean
            return acc + diff * diff
        } / Decimal(values.count)
        let stdev = decimalSqrt(variance)
        return Baseline(mean: mean, stdev: stdev, sampleDays: values.count)
    }

    // MARK: - Helpers

    private static func sortEvents(_ events: [Event]) -> [Event] {
        events.sorted { a, b in
            if (a.delta > 0) != (b.delta > 0) { return a.delta > 0 }
            return abs((a.delta as NSDecimalNumber).doubleValue) > abs((b.delta as NSDecimalNumber).doubleValue)
        }
    }

    private static func decimalSqrt(_ value: Decimal) -> Decimal {
        let d = (value as NSDecimalNumber).doubleValue
        guard d > 0, d.isFinite else { return 0 }
        return Decimal(d.squareRoot())
    }
}

// MARK: - Monthly breakdown (extension)

extension ForecastEngine.Horizon {
    /// One entry per calendar month that any day in the horizon
    /// touches. Partial months at the start/end are included — the
    /// card just shows "through day N" for the tail month. Sorted
    /// ascending by `monthStart`.
    func monthlyBreakdown(calendar: Calendar = .current) -> [ForecastEngine.MonthSummary] {
        guard !days.isEmpty else { return [] }

        var buckets: [Date: [ForecastEngine.Day]] = [:]
        for day in days {
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: day.date)) ?? day.date
            buckets[monthStart, default: []].append(day)
        }

        return buckets.keys.sorted().compactMap { monthStart in
            guard let bucket = buckets[monthStart], let first = bucket.first, let last = bucket.last else {
                return nil
            }
            let monthEnd = calendar.date(
                byAdding: DateComponents(month: 1, second: -1),
                to: monthStart
            ) ?? last.date

            var income: Decimal = 0
            var obligations: Decimal = 0
            var discretionary: Decimal = 0
            var lowest = first.expectedBalance
            var lowestDate = first.date
            var biggest: ForecastEngine.Event?

            for d in bucket {
                discretionary += d.discretionary
                for ev in d.events {
                    if ev.delta > 0 { income += ev.delta }
                    else { obligations += -ev.delta }
                    if ev.delta < 0 {
                        if biggest == nil || ev.delta < biggest!.delta { biggest = ev }
                    }
                }
                if d.expectedBalance < lowest {
                    lowest = d.expectedBalance
                    lowestDate = d.date
                }
            }

            let anyExpectedNeg = bucket.contains { $0.expectedBalance < 0 }
            let anyLowNeg = bucket.contains { $0.lowBalance < 0 }
            let risk: ForecastEngine.MonthRisk = {
                if anyExpectedNeg { return .overdraft }
                if anyLowNeg { return .tight }
                return .healthy
            }()

            return ForecastEngine.MonthSummary(
                monthStart: monthStart,
                monthEnd: monthEnd,
                daysIncluded: bucket.count,
                startingBalance: first.expectedBalance,
                endingBalance: last.expectedBalance,
                lowestBalance: lowest,
                lowestBalanceDate: lowestDate,
                income: income,
                obligations: obligations,
                discretionary: discretionary,
                net: income - obligations - discretionary,
                biggestEvent: biggest,
                risk: risk
            )
        }
    }
}
