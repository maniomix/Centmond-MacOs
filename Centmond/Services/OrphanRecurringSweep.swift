import Foundation
import SwiftData
import CoreData

/// One-shot sweep that nukes every `RecurringTransaction` in the store using
/// the two-phase pattern that survives tombstoned `BudgetCategory` refs.
///
/// Context: user wiped sample-data categories but left five sample-seed
/// recurring templates behind (Salary, Landlord, PG&E, Paycheck, car
/// inssurance). Deleting them from the UI crashes because their `category`
/// FK still points at BudgetCategory/p39 which no longer exists in the store.
///
/// Guarded by `UserDefaults` key so it runs exactly once per install.
enum OrphanRecurringSweep {
    private static let didRunKey = "didPurgeOrphanRecurrings_2026_04_22"

    static func runOnce(context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didRunKey) else { return }

        guard let all = try? context.fetch(FetchDescriptor<RecurringTransaction>()),
              !all.isEmpty else {
            defaults.set(true, forKey: didRunKey)
            return
        }

        // Phase 1: nil the `category` FK on every row via primitive Core Data
        // access — never dereferences the faulting SwiftData accessor, so it's
        // safe even if the referenced BudgetCategory is tombstoned.
        for r in all {
            guard let mo = r as? NSManagedObject else { continue }
            mo.willAccessValue(forKey: "category")
            let hasRef = mo.primitiveValue(forKey: "category") != nil
            mo.didAccessValue(forKey: "category")
            guard hasRef else { continue }
            mo.willChangeValue(forKey: "category")
            mo.setPrimitiveValue(nil, forKey: "category")
            mo.didChangeValue(forKey: "category")
        }
        context.persist()

        // Phase 2: re-materialize each row by PID (fresh backing, no cached
        // relationship snapshot) and delete.
        let pids = all.map(\.persistentModelID)
        for pid in pids {
            if let fresh = context.model(for: pid) as? RecurringTransaction {
                context.delete(fresh)
            }
        }
        context.persist()

        defaults.set(true, forKey: didRunKey)
    }
}
