import Foundation
import SwiftData

// ============================================================
// MARK: - Net Worth History Service (P2)
// ============================================================
//
// Writes `NetWorthSnapshot` aggregates and per-account
// `AccountBalancePoint` rows. Called on launch / scene-active /
// midnight alongside RecurringScheduler, with the same idempotent
// contract: overlapping fires are harmless.
//
// Historical backfill walks backwards from each account's live
// `currentBalance` by unwinding transaction deltas, producing one
// row per calendar day.
//
// Aggregate sign convention matches NetWorthView:
//   assets:      balance is kept as-is and summed
//   liabilities: abs(balance) is subtracted from assets
// ============================================================

enum NetWorthHistoryService {

    // MARK: - Settings (clamp at call site per memory rule)
    //
    // Settings UI may write any value through @AppStorage; the
    // service clamps reads here so a corrupt value can't break
    // the snapshot pipeline.

    private static let backfillKey = "netWorthBackfillDays"
    private static let autoSnapshotKey = "netWorthAutoSnapshotEnabled"

    static var effectiveBackfillDays: Int {
        let raw = UserDefaults.standard.integer(forKey: backfillKey)
        let value = raw == 0 ? 365 : raw
        return min(max(value, 30), 1825)   // 1 month to 5 years
    }

    static var effectiveAutoSnapshotEnabled: Bool {
        if UserDefaults.standard.object(forKey: autoSnapshotKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoSnapshotKey)
    }

    // MARK: - Public API

    /// Idempotent: writes a snapshot for today only if one does not
    /// already exist for the current calendar day (regardless of
    /// source). Safe to call repeatedly. Skipped entirely when the
    /// user disables auto-snapshot — they can still trigger a manual
    /// snapshot from Settings.
    @discardableResult
    static func tick(context: ModelContext) -> Bool {
        guard effectiveAutoSnapshotEnabled else { return false }
        let day = Calendar.current.startOfDay(for: .now)
        if snapshotExists(on: day, context: context) { return false }
        writeSnapshot(on: day, source: .auto, context: context)
        return true
    }

    /// Forces a new snapshot right now (user action "Snapshot now").
    /// Replaces the day's existing row if present, so repeated taps
    /// don't pile up duplicate entries.
    static func snapshotNow(context: ModelContext) {
        let day = Calendar.current.startOfDay(for: .now)
        deleteSnapshots(on: day, context: context)
        writeSnapshot(on: day, source: .manual, context: context)
    }

    /// Soft fill: writes missing daily rows from the earliest
    /// existing snapshot (or `daysBack` days ago, whichever is
    /// later) up through today. Safe to re-run — skips days that
    /// already have a row.
    static func backfillIfNeeded(context: ModelContext, daysBack: Int? = nil) {
        let daysBack = daysBack ?? effectiveBackfillDays
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let earliestWanted = cal.date(byAdding: .day, value: -daysBack, to: today) ?? today

        let existing = (try? context.fetch(FetchDescriptor<NetWorthSnapshot>())) ?? []
        let existingDays = Set(existing.map { cal.startOfDay(for: $0.date) })

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        guard !accounts.isEmpty else { return }

        // Sort each account's transactions desc ONCE so the inner-loop
        // historicalBalance call is linear-with-early-exit instead of a
        // full filter per day. Cold 365-day backfill shrinks from
        // O(days × totalTxns) to O(totalTxns log totalTxns + days × avgAfterCutoff).
        let sortedCache = sortedDescTxnCache(for: accounts)

        var day = earliestWanted
        while day <= today {
            if !existingDays.contains(day) {
                writeSnapshot(on: day, source: .backfill, context: context, accounts: accounts, sortedTxnsCache: sortedCache)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
    }

    /// Per-account txns sorted descending by date. Keyed on ObjectIdentifier
    /// of the Account @Model instance. Built once per backfill/rebuild.
    private static func sortedDescTxnCache(for accounts: [Account]) -> [ObjectIdentifier: [Transaction]] {
        var cache: [ObjectIdentifier: [Transaction]] = [:]
        cache.reserveCapacity(accounts.count)
        for a in accounts {
            cache[ObjectIdentifier(a)] = a.transactions.sorted { $0.date > $1.date }
        }
        return cache
    }

    /// Destructive: wipes every snapshot + balance point, then
    /// rebuilds a `daysBack`-day daily timeline from scratch.
    static func rebuildHistory(context: ModelContext, daysBack: Int? = nil) {
        let daysBack = daysBack ?? effectiveBackfillDays
        if let snaps = try? context.fetch(FetchDescriptor<NetWorthSnapshot>()) {
            for s in snaps { context.delete(s) }
        }
        if let pts = try? context.fetch(FetchDescriptor<AccountBalancePoint>()) {
            for p in pts { context.delete(p) }
        }
        try? context.save()

        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let start = cal.date(byAdding: .day, value: -daysBack, to: today) ?? today

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        guard !accounts.isEmpty else { return }

        let sortedCache = sortedDescTxnCache(for: accounts)

        var day = start
        while day <= today {
            let source: NetWorthSnapshot.SnapshotSource = (day == today) ? .rebuild : .backfill
            writeSnapshot(on: day, source: source, context: context, accounts: accounts, sortedTxnsCache: sortedCache)
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
    }

    // MARK: - Core write

    /// Writes one `NetWorthSnapshot` + one `AccountBalancePoint` per
    /// active account for the given calendar day. Callers are
    /// responsible for idempotency checks (see `tick` / `backfillIfNeeded`).
    private static func writeSnapshot(
        on day: Date,
        source: NetWorthSnapshot.SnapshotSource,
        context: ModelContext,
        accounts: [Account]? = nil,
        sortedTxnsCache: [ObjectIdentifier: [Transaction]]? = nil
    ) {
        let accts = accounts ?? ((try? context.fetch(FetchDescriptor<Account>())) ?? [])
        let active = accts.filter { !$0.isArchived && !$0.isClosed && $0.includeInNetWorth }
        guard !active.isEmpty else { return }

        var totalAssets: Decimal = 0
        var totalLiabilities: Decimal = 0

        for account in active {
            let cached = sortedTxnsCache?[ObjectIdentifier(account)]
            let balance = historicalBalance(for: account, on: day, sortedTxnsDesc: cached)
            let point = AccountBalancePoint(date: day, balance: balance, account: account)
            context.insert(point)

            if account.type.isLiability {
                totalLiabilities += abs(balance)
            } else {
                totalAssets += balance
            }
        }

        let snapshot = NetWorthSnapshot(
            date: day,
            totalAssets: totalAssets,
            totalLiabilities: totalLiabilities,
            source: source
        )
        context.insert(snapshot)
        try? context.save()
    }

    // MARK: - Historical math

    /// Reconstructs an account's balance on `day` by unwinding every
    /// transaction dated AFTER `day` from the live `currentBalance`.
    /// Income legs are added back (they would have been absent before
    /// the income posted); expense legs are un-subtracted. For the
    /// current day this is a no-op and returns `currentBalance`.
    ///
    /// Pass `sortedTxnsDesc` (date descending) when calling in a loop —
    /// backfill/rebuild walk D days × A accounts, and re-filtering the
    /// full relationship array on every iteration was the single biggest
    /// cost of a cold backfill. With the array pre-sorted desc, this
    /// call becomes a linear walk with early-exit at `cutoff`.
    private static func historicalBalance(
        for account: Account,
        on day: Date,
        sortedTxnsDesc: [Transaction]? = nil
    ) -> Decimal {
        let cutoff = Calendar.current.startOfDay(for: day)
        var delta: Decimal = 0
        if let sorted = sortedTxnsDesc {
            // Fast path: walk desc-sorted array and bail when we pass the cutoff.
            for t in sorted {
                if t.date <= cutoff { break }
                delta += t.isIncome ? t.amount : -t.amount
            }
        } else {
            // Slow path (external callers, single-day writes).
            for t in account.transactions where t.date > cutoff {
                delta += t.isIncome ? t.amount : -t.amount
            }
        }
        return account.currentBalance - delta
    }

    // MARK: - Helpers

    private static func snapshotExists(on day: Date, context: ModelContext) -> Bool {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return false }

        var descriptor = FetchDescriptor<NetWorthSnapshot>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        descriptor.fetchLimit = 1
        let hit = (try? context.fetch(descriptor))?.first
        return hit != nil
    }

    private static func deleteSnapshots(on day: Date, context: ModelContext) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }

        let snapDesc = FetchDescriptor<NetWorthSnapshot>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        if let snaps = try? context.fetch(snapDesc) {
            for s in snaps { context.delete(s) }
        }

        let pointDesc = FetchDescriptor<AccountBalancePoint>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        if let pts = try? context.fetch(pointDesc) {
            for p in pts { context.delete(p) }
        }
        try? context.save()
    }
}
