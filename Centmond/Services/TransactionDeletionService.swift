import Foundation
import SwiftData

/// Centralized delete path for Transactions. Every caller MUST route through
/// here so related accounting artifacts (goal contributions, household
/// shares, household settlements) are removed in the right order. Otherwise
/// downstream balances drift — e.g. after deleting a shared transaction the
/// household hub kept showing phantom "owes/owed" pills because orphan
/// ExpenseShare or HouseholdSettlement rows remained in the store.
///
/// Implementation rule: ALL identifier + relationship reads happen in one
/// snapshot pass BEFORE any `context.delete` fires. Mid-loop deletion of
/// an inverse-related child (an ExpenseShare on `transaction.shares`)
/// invalidates the parent's backing data, after which reading
/// `transaction.id` or `transaction.shares` crashes with
/// "This model instance was invalidated because its backing data could no
/// longer be found the store." Capturing everything up-front removes that
/// hazard entirely.
enum TransactionDeletionService {
    static func delete(_ transaction: Transaction, context: ModelContext) {
        delete([transaction], context: context)
    }

    static func delete(_ transactions: [Transaction], context: ModelContext) {
        // PASS 1 — snapshot identifiers + relationship IDs before anything
        // is deleted. `Transaction.id` and `Transaction.shares` become
        // unsafe to access the moment a related inverse delete fires.
        //
        // Also skip transactions that are already detached from the
        // context (`modelContext == nil`) or flagged deleted. SwiftUI
        // alerts sometimes fire with stale references after the user
        // deletes the same row twice in quick succession or after a
        // context flush mid-gesture — without this guard, accessing
        // `tx.id` on a tombstoned model crashes with
        // "This model instance was invalidated because its backing data
        // could no longer be found in the store."
        struct Snapshot {
            let tx: Transaction
            let txID: UUID
        }
        // Never touch caller-provided refs beyond `persistentModelID`. The
        // refs may be tombstoned (e.g. after a household cascade or a
        // re-entrant SwiftUI alert), and `tx.id`, `tx.shares`, even
        // `tx.isDeleted` will fault with "backing data could no longer be
        // found in the store". Resolve every input PID against a freshly-
        // fetched live set and only read scalar fields off the fetched
        // model — never traverse the `shares` to-many relationship, which
        // can itself fault if any inverse-related ExpenseShare backing was
        // invalidated upstream.
        let inputPIDs: [PersistentIdentifier] = transactions.map(\.persistentModelID)
        let liveByPID: [PersistentIdentifier: Transaction] = {
            guard let all = try? context.fetch(FetchDescriptor<Transaction>()) else { return [:] }
            return Dictionary(uniqueKeysWithValues: all.map { ($0.persistentModelID, $0) })
        }()
        let snapshots: [Snapshot] = inputPIDs.compactMap { pid in
            guard let live = liveByPID[pid] else { return nil }
            return Snapshot(tx: live, txID: live.id)
        }
        guard !snapshots.isEmpty else { return }
        let txIDs = Set(snapshots.map(\.txID))

        // Find shares + settlements by reverse-lookup against the txIDs
        // set rather than walking `tx.shares` / inverse arrays. Each such
        // walk is a chance to fault on a tombstoned child.
        var sharesToDelete: [ExpenseShare] = []
        if let allShares = try? context.fetch(FetchDescriptor<ExpenseShare>()) {
            for share in allShares {
                guard let parent = share.parentTransaction,
                      liveByPID[parent.persistentModelID] != nil,
                      txIDs.contains(parent.id) else { continue }
                sharesToDelete.append(share)
            }
        }

        var settlementsToDelete: [HouseholdSettlement] = []
        if let allSettlements = try? context.fetch(FetchDescriptor<HouseholdSettlement>()) {
            for s in allSettlements {
                guard let linked = s.linkedTransaction,
                      liveByPID[linked.persistentModelID] != nil,
                      txIDs.contains(linked.id) else { continue }
                settlementsToDelete.append(s)
            }
        }

        // PASS 2 — perform deletions. Order:
        //  1. Shares first so the transaction's inverse array is clean.
        //  2. Settlements whose cash movement WAS this transaction — without
        //     the linked transaction they're meaningless history and would
        //     flip the balance ledger the wrong direction.
        //  3. Goal contributions attributed to the transaction (keeps goal
        //     progress accurate).
        //  4. The transactions themselves.
        for share in sharesToDelete {
            context.delete(share)
        }
        for settlement in settlementsToDelete {
            context.delete(settlement)
        }
        for snapshot in snapshots {
            GoalContributionService.removeContributions(forTransactionID: snapshot.txID, context: context)
        }
        for snapshot in snapshots {
            context.delete(snapshot.tx)
        }
    }
}
