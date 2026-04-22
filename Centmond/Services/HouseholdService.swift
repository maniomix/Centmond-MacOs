import Foundation
import SwiftData

/// Orchestrator for the Household feature. Single entry point for member CRUD,
/// share math, and settle-up calculation so every call site (sheets, AI
/// actions, review queue, CSV import) stays consistent.
///
/// Pure functions where possible (no ModelContext) so the math is easy to test
/// and reuse in previews. Mutating helpers take the context explicitly.
enum HouseholdService {

    // MARK: - Member lifecycle

    static func activeMembers(in context: ModelContext) -> [HouseholdMember] {
        let descriptor = FetchDescriptor<HouseholdMember>(
            sortBy: [SortDescriptor(\.joinedAt, order: .forward)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.isActive }
    }

    static func allMembers(in context: ModelContext) -> [HouseholdMember] {
        let descriptor = FetchDescriptor<HouseholdMember>(
            sortBy: [SortDescriptor(\.joinedAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Archive instead of hard-delete when a member has any attached ledger
    /// history (transactions, shares, settlements). Keeps reports correct.
    static func archive(_ member: HouseholdMember) {
        member.isActive = false
        member.archivedAt = .now
    }

    static func restore(_ member: HouseholdMember) {
        member.isActive = true
        member.archivedAt = nil
    }

    /// Hard delete is safe only when the member has no references anywhere.
    static func canHardDelete(_ member: HouseholdMember) -> Bool {
        member.transactions.isEmpty && member.shares.isEmpty
    }

    // MARK: - Payee learner

    /// Look at the last `limit` transactions for `payee` (case-insensitive,
    /// alphanumeric-normalized) and return the dominant household member — if
    /// one exists. Dominance threshold: at least 3 attributed samples AND the
    /// top member accounts for ≥60% of them. Conservative on purpose; wrong
    /// auto-attribution is worse than none.
    static func resolveMember(forPayee payee: String,
                              in context: ModelContext,
                              limit: Int = 20) -> HouseholdMember? {
        let key = normalizedPayeeKey(payee)
        guard !key.isEmpty else { return nil }

        var descriptor = FetchDescriptor<Transaction>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 400
        guard let recent = try? context.fetch(descriptor) else { return nil }

        var counts: [UUID: (member: HouseholdMember, count: Int)] = [:]
        var total = 0
        for tx in recent {
            guard normalizedPayeeKey(tx.payee) == key, let m = tx.householdMember else { continue }
            counts[m.id, default: (m, 0)].count += 1
            total += 1
            if total >= limit { break }
        }
        guard total >= 3,
              let best = counts.values.max(by: { $0.count < $1.count }),
              Double(best.count) / Double(total) >= 0.6 else { return nil }
        return best.member
    }

    private static func normalizedPayeeKey(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    // MARK: - Share math (pure)

    /// Compute equal-split share amounts for `total` across `memberCount` ways.
    /// Remainder cent goes on the first share so the sum matches `total` exactly.
    static func equalShares(total: Decimal, memberCount: Int) -> [Decimal] {
        guard memberCount > 0 else { return [] }
        let count = Decimal(memberCount)
        let scale: Decimal = 100
        var totalCents = total * scale
        var rounded = Decimal()
        NSDecimalRound(&rounded, &totalCents, 0, .plain)
        let totalCentsInt = (rounded as NSDecimalNumber).intValue
        let base = totalCentsInt / memberCount
        let remainder = totalCentsInt - base * memberCount
        return (0..<memberCount).map { i in
            let cents = base + (i < remainder ? 1 : 0)
            return Decimal(cents) / scale
        }
    }

    /// Compute share amounts from percent weights (e.g. [50, 30, 20]). Percent
    /// values are normalized against their sum so callers don't have to make
    /// them add to 100. Remainder cent goes on the largest-percent share.
    static func percentShares(total: Decimal, percents: [Double]) -> [Decimal] {
        let sum = percents.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 0, count: percents.count) }
        let scale: Decimal = 100
        var totalCentsDecimal = total * scale
        var rounded = Decimal()
        NSDecimalRound(&rounded, &totalCentsDecimal, 0, .plain)
        let totalCents = (rounded as NSDecimalNumber).intValue
        var allocated: [Int] = percents.map { p in
            Int((Double(totalCents) * (p / sum)).rounded(.down))
        }
        var remainder = totalCents - allocated.reduce(0, +)
        // Hand remainder cents to the largest-percent shares first.
        let order = percents.enumerated().sorted { $0.element > $1.element }.map(\.offset)
        var i = 0
        while remainder > 0 && i < order.count {
            allocated[order[i]] += 1
            remainder -= 1
            i += 1
        }
        return allocated.map { Decimal($0) / scale }
    }

    /// Integer-shares split (e.g. 2:1:1 for a family of four). Converts weights
    /// to percents and delegates.
    static func weightedShares(total: Decimal, weights: [Int]) -> [Decimal] {
        percentShares(total: total, percents: weights.map(Double.init))
    }

    // MARK: - Share application

    /// Replace any existing ExpenseShare rows on `transaction` with a fresh
    /// equal split across `members`. Idempotent — safe to call repeatedly;
    /// stale rows are deleted before new ones are inserted so the sum always
    /// matches `transaction.amount` after this call.
    static func applyEqualSplit(to transaction: Transaction,
                                members: [HouseholdMember],
                                in context: ModelContext) {
        clearShares(on: transaction, context: context)
        guard !members.isEmpty else { return }
        let amounts = equalShares(total: transaction.amount, memberCount: members.count)
        for (i, m) in members.enumerated() {
            let share = ExpenseShare(
                amount: amounts[i],
                status: .owed,
                method: .equal,
                parentTransaction: transaction,
                member: m
            )
            context.insert(share)
        }
    }

    /// Replace existing shares with a percent-weighted split. `percents` must
    /// line up by index with `members`. Normalization + rounding handled by
    /// `percentShares`.
    static func applyPercentSplit(to transaction: Transaction,
                                  members: [HouseholdMember],
                                  percents: [Double],
                                  in context: ModelContext) {
        clearShares(on: transaction, context: context)
        guard members.count == percents.count, !members.isEmpty else { return }
        let amounts = percentShares(total: transaction.amount, percents: percents)
        for (i, m) in members.enumerated() {
            let share = ExpenseShare(
                amount: amounts[i],
                percent: percents[i],
                status: .owed,
                method: .percent,
                parentTransaction: transaction,
                member: m
            )
            context.insert(share)
        }
    }

    /// Replace existing shares with caller-specified exact amounts. No
    /// validation that sum == transaction.amount — the sheet enforces that
    /// before calling.
    static func applyExactSplit(to transaction: Transaction,
                                members: [HouseholdMember],
                                amounts: [Decimal],
                                in context: ModelContext) {
        clearShares(on: transaction, context: context)
        guard members.count == amounts.count, !members.isEmpty else { return }
        for (i, m) in members.enumerated() {
            let share = ExpenseShare(
                amount: amounts[i],
                status: .owed,
                method: .exact,
                parentTransaction: transaction,
                member: m
            )
            context.insert(share)
        }
    }

    private static func clearShares(on transaction: Transaction, context: ModelContext) {
        for existing in transaction.shares {
            context.delete(existing)
        }
    }

    // MARK: - Settle-up ledger

    /// Net balance per member: positive = others owe them, negative = they owe
    /// others. Computed from open `ExpenseShare` rows minus `HouseholdSettlement`
    /// entries. A share is owed by `share.member` to `share.parentTransaction`'s
    /// payer (the member who attributed the transaction, if any).
    struct Balance {
        let member: HouseholdMember
        let amount: Decimal
    }

    static func balances(in context: ModelContext) -> [Balance] {
        let members = activeMembers(in: context)
        guard !members.isEmpty else { return [] }

        // Per-directed-pair accumulation. A settlement can only REDUCE
        // the debt in its own direction — never flip it into a reverse
        // debt. Earlier version added settlements directly into the
        // per-member totals, which let a stale settlement (e.g. from a
        // deleted share cycle) push a balance through zero and produce
        // phantom "Mani owes Ali €20" when the only live share is
        // "Ali owes Mani €5". Clamp at 0 per pair to fix.
        var pairDebt: [String: Decimal] = [:]      // "debtor->creditor" → net amount owed
        var pairMembers: [String: (HouseholdMember, HouseholdMember)] = [:]

        // Pre-fetch live Transaction persistentModelIDs so we can skip any
        // ExpenseShare whose parentTransaction is a tombstoned ref without
        // dereferencing it (which would crash on invalidated backing data).
        let liveTxIDs: Set<PersistentIdentifier> = Set(
            ((try? context.fetch(FetchDescriptor<Transaction>())) ?? []).map(\.persistentModelID)
        )

        let shareDescriptor = FetchDescriptor<ExpenseShare>()
        let shares = (try? context.fetch(shareDescriptor)) ?? []
        for share in shares where share.status == .owed {
            guard
                let debtor = share.member,
                let parent = share.parentTransaction,
                liveTxIDs.contains(parent.persistentModelID),
                let creditor = parent.householdMember,
                debtor.id != creditor.id
            else { continue }
            let key = "\(debtor.id)->\(creditor.id)"
            pairDebt[key, default: 0] += share.amount
            pairMembers[key] = (debtor, creditor)
        }

        let settlementDescriptor = FetchDescriptor<HouseholdSettlement>()
        let settlements = (try? context.fetch(settlementDescriptor)) ?? []
        for s in settlements {
            guard let from = s.fromMember, let to = s.toMember else { continue }
            // Settlement from→to pays down the debt from→to. If no such
            // debt exists we silently drop it rather than inverting the
            // balance — settlements may NEVER create debt in the reverse
            // direction. This is the clamp that keeps orphan / stale
            // settlements from producing phantom reverse balances.
            let key = "\(from.id)->\(to.id)"
            guard let existing = pairDebt[key], existing > 0 else { continue }
            let applied = min(existing, s.amount)
            pairDebt[key] = existing - applied
        }

        // Collapse per-pair debts into per-member totals.
        var totals: [UUID: Decimal] = [:]
        for m in members { totals[m.id] = 0 }
        for (key, amount) in pairDebt where amount > 0 {
            guard let pair = pairMembers[key] else { continue }
            totals[pair.0.id, default: 0] -= amount     // debtor
            totals[pair.1.id, default: 0] += amount     // creditor
        }

        return members.compactMap { m in
            guard let amount = totals[m.id] else { return nil }
            return Balance(member: m, amount: amount)
        }
    }

    /// Record a settle-up payment from one member to another. Optionally
    /// creates a matching Transaction (notes: "Settlement: X → Y") linked to
    /// `account` so the cash movement is visible in the ledger. Returns the
    /// created settlement so the caller can jump to it.
    @discardableResult
    static func recordSettlement(from: HouseholdMember,
                                 to: HouseholdMember,
                                 amount: Decimal,
                                 date: Date = .now,
                                 note: String? = nil,
                                 account: Account? = nil,
                                 createLinkedTransaction: Bool = false,
                                 in context: ModelContext) -> HouseholdSettlement {
        var linked: Transaction?
        if createLinkedTransaction {
            let tx = Transaction(
                date: date,
                payee: "Settlement: \(from.name) → \(to.name)",
                amount: amount,
                notes: note ?? "Household settle-up",
                isIncome: false,
                status: .cleared,
                isReviewed: true,
                account: account,
                category: nil
            )
            tx.householdMember = from
            context.insert(tx)
            if let acc = account {
                BalanceService.recalculate(account: acc)
            }
            linked = tx
        }
        let settlement = HouseholdSettlement(
            amount: amount,
            date: date,
            note: note,
            fromMember: from,
            toMember: to,
            linkedTransaction: linked
        )
        context.insert(settlement)

        // Walk open shares owed by `from` to `to`'s transactions and mark them
        // settled up to `amount`. FIFO by share creation date.
        let remaining = markSharesSettled(from: from, to: to, budget: amount,
                                          settlement: settlement, context: context)
        if remaining > 0 {
            // Over-settlement: not an error, just means the payment covered
            // more than the tracked open shares. Historical slack is fine.
        }
        return settlement
    }

    @discardableResult
    private static func markSharesSettled(from: HouseholdMember,
                                          to: HouseholdMember,
                                          budget: Decimal,
                                          settlement: HouseholdSettlement,
                                          context: ModelContext) -> Decimal {
        let fromID = from.id
        let toID = to.id
        let shareDescriptor = FetchDescriptor<ExpenseShare>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        guard let shares = try? context.fetch(shareDescriptor) else { return budget }
        var remaining = budget
        for share in shares where share.status == .owed {
            guard
                share.member?.id == fromID,
                let parent = share.parentTransaction,
                parent.householdMember?.id == toID
            else { continue }
            if share.amount <= remaining {
                share.status = .settled
                share.settledAt = .now
                share.settlementTransaction = settlement.linkedTransaction
                remaining -= share.amount
            }
            if remaining <= 0 { break }
        }
        return remaining
    }

    // MARK: - Pair balances (debt-first UI)

    /// One open direction of a pairwise balance. Produced from ExpenseShare +
    /// HouseholdSettlement walk; returns only positive net amounts (the
    /// debtor still owes the creditor).
    struct PairBalance: Identifiable, Hashable {
        let id: String          // "<debtorID>->\(creditorID)"
        let debtor: HouseholdMember
        let creditor: HouseholdMember
        let amount: Decimal
    }

    /// All open debts across the household. Used by the Household hub's
    /// "who owes who" panel and the Record Payment sheet. Pure — no UI.
    ///
    /// Clamp-safe: settlements only reduce debt in their OWN direction and
    /// never below zero. An orphaned or over-large settlement can't flip a
    /// pair into a reverse debt. Balances math uses the same rule.
    static func openPairBalances(in context: ModelContext) -> [PairBalance] {
        var tallies: [String: Decimal] = [:]
        var keyToPair: [String: (HouseholdMember, HouseholdMember)] = [:]

        // Skip shares whose parent is a tombstoned Transaction ref — see
        // balances() for the crash pattern we're avoiding.
        let liveTxIDs: Set<PersistentIdentifier> = Set(
            ((try? context.fetch(FetchDescriptor<Transaction>())) ?? []).map(\.persistentModelID)
        )

        let shares = (try? context.fetch(FetchDescriptor<ExpenseShare>())) ?? []
        for s in shares where s.status == .owed {
            guard
                let debtor = s.member,
                let parent = s.parentTransaction,
                liveTxIDs.contains(parent.persistentModelID),
                let creditor = parent.householdMember,
                debtor.id != creditor.id
            else { continue }
            let key = "\(debtor.id)->\(creditor.id)"
            tallies[key, default: 0] += s.amount
            keyToPair[key] = (debtor, creditor)
        }

        let settlements = (try? context.fetch(FetchDescriptor<HouseholdSettlement>())) ?? []
        for st in settlements {
            guard let from = st.fromMember, let to = st.toMember else { continue }
            let key = "\(from.id)->\(to.id)"
            guard let existing = tallies[key], existing > 0 else { continue }
            tallies[key] = existing - min(existing, st.amount)
        }

        return tallies.compactMap { key, amount in
            guard amount > 0, let pair = keyToPair[key] else { return nil }
            return PairBalance(id: key, debtor: pair.0, creditor: pair.1, amount: amount)
        }
        .sorted { $0.amount > $1.amount }
    }

    // MARK: - Per-member net worth (P4)

    /// Sum of assets minus liabilities for accounts owned by `member`. Accounts
    /// with `ownerMember == nil` are treated as shared/joint and NOT included
    /// in any individual member's total — they belong to the household line.
    static func netWorth(for member: HouseholdMember,
                         in context: ModelContext) -> Decimal {
        let descriptor = FetchDescriptor<Account>()
        let accounts = (try? context.fetch(descriptor)) ?? []
        let id = member.id
        return accounts
            .filter { $0.ownerMember?.id == id && !$0.isArchived && $0.includeInNetWorth }
            .reduce(Decimal(0)) { $0 + $1.currentBalance }
    }

    /// Joint / shared accounts — not attributed to any single member. Shown
    /// alongside per-member totals in the household hub so every dollar has a
    /// home line.
    static func sharedNetWorth(in context: ModelContext) -> Decimal {
        let descriptor = FetchDescriptor<Account>()
        let accounts = (try? context.fetch(descriptor)) ?? []
        return accounts
            .filter { $0.ownerMember == nil && !$0.isArchived && $0.includeInNetWorth }
            .reduce(Decimal(0)) { $0 + $1.currentBalance }
    }

    // MARK: - Repair

    /// Nullify orphaned share / settlement references left behind after a
    /// member hard-delete. Called on launch alongside the other repair passes.
    static func repairOrphans(in context: ModelContext) {
        let shareDescriptor = FetchDescriptor<ExpenseShare>()
        for share in (try? context.fetch(shareDescriptor)) ?? [] {
            if share.parentTransaction == nil {
                context.delete(share)
            }
        }
        let settlementDescriptor = FetchDescriptor<HouseholdSettlement>()
        for s in (try? context.fetch(settlementDescriptor)) ?? [] {
            if s.fromMember == nil && s.toMember == nil {
                context.delete(s)
            }
        }
    }
}
