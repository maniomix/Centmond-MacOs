import Foundation
import SwiftData
import CoreData

/// Repair orphaned Transaction references. Mirrors `CategoryReferenceRepair`:
/// walks every entity that holds a strong/weak reference to a Transaction,
/// and if the referenced row's `persistentModelID` is no longer in the live
/// Transaction set, deletes the orphan (for owned children like ExpenseShare
/// and HouseholdSettlement) or nullifies the pointer.
///
/// Why we need this: SwiftData occasionally leaves tombstoned Transaction
/// refs in related tables after a deletion — accessing `ref.id` or most
/// properties crashes with "backing data could no longer be found in the
/// store." `persistentModelID` is the one safe property on a dead ref, so
/// we use it as the comparison key.
///
/// Runs at launch alongside `CategoryReferenceRepair` + `NetWorthReferenceRepair`.
enum TransactionReferenceRepair {
    static func run(context: ModelContext) {
        let liveIDs: Set<PersistentIdentifier> = {
            let descriptor = FetchDescriptor<Transaction>()
            guard let txns = try? context.fetch(descriptor) else { return [] }
            return Set(txns.map(\.persistentModelID))
        }()

        var changed = false

        // ExpenseShare.parentTransaction — if its parent is gone, the share
        // is meaningless (can't attribute it) and must be deleted.
        if let shares = try? context.fetch(FetchDescriptor<ExpenseShare>()) {
            for share in shares {
                guard let pid = share.parentTransaction?.persistentModelID else { continue }
                if !liveIDs.contains(pid) {
                    context.delete(share)
                    changed = true
                }
            }
        }

        // HouseholdSettlement.linkedTransaction — nullify the pointer if the
        // linked ledger row is gone. (We don't delete the settlement itself —
        // it's still valid history, just unlinked.)
        if let settlements = try? context.fetch(FetchDescriptor<HouseholdSettlement>()) {
            for s in settlements {
                guard let pid = s.linkedTransaction?.persistentModelID else { continue }
                if !liveIDs.contains(pid) {
                    if nullifyRelationship(on: s, key: "linkedTransaction") {
                        changed = true
                    }
                }
            }
        }

        // ExpenseShare.settlementTransaction — same treatment; settlement
        // survives but loses its link.
        if let shares = try? context.fetch(FetchDescriptor<ExpenseShare>()) {
            for share in shares {
                guard let pid = share.settlementTransaction?.persistentModelID else { continue }
                if !liveIDs.contains(pid) {
                    if nullifyRelationship(on: share, key: "settlementTransaction") {
                        changed = true
                    }
                }
            }
        }

        if changed {
            context.persist()
        }
    }

    private static func nullifyRelationship(on model: any PersistentModel, key: String) -> Bool {
        guard let mo = model as? NSManagedObject else { return false }
        mo.willChangeValue(forKey: key)
        mo.setPrimitiveValue(nil, forKey: key)
        mo.didChangeValue(forKey: key)
        return true
    }
}
