import Foundation
import SwiftData
import CoreData

/// One-time repair for orphan `BudgetCategory` references.
///
/// Before the inverse relationships on `BudgetCategory` for
/// `RecurringTransaction.category` and `TransactionSplit.category` were
/// declared, deleting a category left those relationships pointing at the
/// deleted row. Accessing `r.category?.name` (or even `.persistentModelID`
/// in some SwiftData versions) on such a ref crashes with "backing data
/// could no longer be found" because SwiftData tries to fault the
/// tombstoned object as soon as the optional is evaluated.
///
/// This repair bypasses SwiftData's faulting accessors entirely and works
/// at the underlying Core Data layer:
///   1. Read the relationship via `primitiveValue(forKey:)` — returns the
///      raw NSManagedObject fault WITHOUT materializing (no crash).
///   2. Compare its `objectID` directly against the live-category objectID
///      set. `objectID` is always safe, even on a dead ref.
///   3. If the ref is stale, nullify via `setPrimitiveValue(nil, forKey:)`
///      which writes the FK directly without touching the dead row's
///      snapshot.
///
/// Runs at launch alongside `TransactionReferenceRepair` +
/// `NetWorthReferenceRepair`. Also safe to call after a runtime delete
/// if the caller wants an immediate scrub.
enum CategoryReferenceRepair {
    static func run(context: ModelContext) {
        let liveObjectIDs: Set<NSManagedObjectID> = {
            let descriptor = FetchDescriptor<BudgetCategory>()
            guard let cats = try? context.fetch(descriptor) else { return [] }
            return Set(cats.compactMap { ($0 as? NSManagedObject)?.objectID })
        }()

        var changed = false

        if let recurrings = try? context.fetch(FetchDescriptor<RecurringTransaction>()) {
            for r in recurrings {
                if scrubIfStale(on: r, key: "category", liveObjectIDs: liveObjectIDs) {
                    changed = true
                }
            }
        }

        if let splits = try? context.fetch(FetchDescriptor<TransactionSplit>()) {
            for s in splits {
                if scrubIfStale(on: s, key: "category", liveObjectIDs: liveObjectIDs) {
                    changed = true
                }
            }
        }

        if let txns = try? context.fetch(FetchDescriptor<Transaction>()) {
            for t in txns {
                if scrubIfStale(on: t, key: "category", liveObjectIDs: liveObjectIDs) {
                    changed = true
                }
            }
        }

        if changed {
            context.persist()
        }
    }

    /// Scrub a single model's `category` ref via primitive Core Data access,
    /// regardless of whether the pointee is alive. Call this BEFORE deleting
    /// a row whose `.category` may point at a tombstoned BudgetCategory —
    /// SwiftData's delete walks relationships and faults on a dead ref.
    /// `key` is the relationship name on the model (e.g. "category").
    static func unsafeNilCategory(on model: any PersistentModel, key: String = "category") {
        guard let mo = model as? NSManagedObject else { return }
        mo.willAccessValue(forKey: key)
        let hasRef = mo.primitiveValue(forKey: key) != nil
        mo.didAccessValue(forKey: key)
        guard hasRef else { return }
        mo.willChangeValue(forKey: key)
        mo.setPrimitiveValue(nil, forKey: key)
        mo.didChangeValue(forKey: key)
    }

    /// Check a relationship via the underlying Core Data primitive layer —
    /// never dereferences the faulting SwiftData accessor. Returns true if
    /// it nullified a stale ref.
    private static func scrubIfStale(
        on model: any PersistentModel,
        key: String,
        liveObjectIDs: Set<NSManagedObjectID>
    ) -> Bool {
        guard let mo = model as? NSManagedObject else { return false }

        // Primitive read: returns the faulting NSManagedObject WITHOUT
        // materializing. `objectID` is safe to read on any fault, alive
        // or tombstoned — it's stored on the fault stub itself.
        mo.willAccessValue(forKey: key)
        let ref = mo.primitiveValue(forKey: key) as? NSManagedObject
        mo.didAccessValue(forKey: key)

        guard let ref else { return false }
        if liveObjectIDs.contains(ref.objectID) { return false }

        // Dead ref — nullify the relationship FK directly. This never
        // triggers the snapshot-fetch that would crash on a tombstoned row.
        mo.willChangeValue(forKey: key)
        mo.setPrimitiveValue(nil, forKey: key)
        mo.didChangeValue(forKey: key)
        return true
    }
}
