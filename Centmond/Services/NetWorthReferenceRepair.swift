import Foundation
import SwiftData

/// Nullifies dangling `AccountBalancePoint.account` references left from
/// builds before the inverse on `Account.balanceHistory` was declared.
/// Same pattern as `CategoryReferenceRepair` — accessing a tombstoned
/// SwiftData ref crashes with "backing data could no longer be found".
enum NetWorthReferenceRepair {
    static func run(context: ModelContext) {
        let liveAccountIDs: Set<PersistentIdentifier> = {
            guard let accounts = try? context.fetch(FetchDescriptor<Account>()) else { return [] }
            return Set(accounts.map(\.persistentModelID))
        }()

        guard let points = try? context.fetch(FetchDescriptor<AccountBalancePoint>()) else { return }

        var changed = false
        for p in points {
            if let pid = p.account?.persistentModelID, !liveAccountIDs.contains(pid) {
                context.delete(p)
                changed = true
            }
        }

        if changed { try? context.save() }
    }
}
