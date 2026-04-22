import Foundation
import SwiftData
import CoreData

/// One-time repair for orphan `BudgetCategory` references.
///
/// Before the inverse relationships on `BudgetCategory` for
/// `RecurringTransaction.category` and `TransactionSplit.category` were
/// declared, deleting a category left those relationships pointing at the
/// deleted row. Accessing `category?.name` on such a ref crashes with
/// "backing data could no longer be found" because SwiftData tries to
/// fault the tombstoned object.
///
/// Any SwiftData mutation path (generated setter OR `setValue(forKey:)`)
/// still requires loading the current value's snapshot to detach the
/// inverse — and that snapshot is gone. We drop to the underlying Core
/// Data `setPrimitiveValue(_:forKey:)` which writes the relationship FK
/// directly without touching the dead row.
enum CategoryReferenceRepair {
    static func run(context: ModelContext) {
        let liveIDs: Set<PersistentIdentifier> = {
            let descriptor = FetchDescriptor<BudgetCategory>()
            guard let cats = try? context.fetch(descriptor) else { return [] }
            return Set(cats.map(\.persistentModelID))
        }()

        var changed = false

        if let recurrings = try? context.fetch(FetchDescriptor<RecurringTransaction>()) {
            for r in recurrings {
                if let pid = r.category?.persistentModelID, !liveIDs.contains(pid) {
                    if nullifyRelationship(on: r, key: "category") {
                        changed = true
                    }
                }
            }
        }

        if let splits = try? context.fetch(FetchDescriptor<TransactionSplit>()) {
            for s in splits {
                if let pid = s.category?.persistentModelID, !liveIDs.contains(pid) {
                    if nullifyRelationship(on: s, key: "category") {
                        changed = true
                    }
                }
            }
        }

        if let txns = try? context.fetch(FetchDescriptor<Transaction>()) {
            for t in txns {
                if let pid = t.category?.persistentModelID, !liveIDs.contains(pid) {
                    if nullifyRelationship(on: t, key: "category") {
                        changed = true
                    }
                }
            }
        }

        if changed {
            try? context.save()
        }
    }

    /// Bridge to the underlying `NSManagedObject` and write the relationship
    /// FK to nil via `setPrimitiveValue(_:forKey:)`. Returns true on success.
    /// Silently returns false if the model isn't bridgeable (shouldn't
    /// happen on current SwiftData — every PersistentModel IS an
    /// NSManagedObject underneath).
    private static func nullifyRelationship(on model: any PersistentModel, key: String) -> Bool {
        guard let mo = model as? NSManagedObject else { return false }
        mo.willChangeValue(forKey: key)
        mo.setPrimitiveValue(nil, forKey: key)
        mo.didChangeValue(forKey: key)
        return true
    }
}
