import Foundation
import SwiftData

/// A point-in-time aggregate of the user's net worth.
///
/// Written by `NetWorthHistoryService` (P2) on launch / scene-active /
/// midnight, plus on-demand from the "Snapshot now" action and during
/// historical backfill. Standalone aggregates (no relationship to
/// Account) so deleting or archiving an account does not retroactively
/// rewrite history.
@Model
final class NetWorthSnapshot {
    var id: UUID
    var date: Date
    var totalAssets: Decimal
    var totalLiabilities: Decimal
    var netWorth: Decimal
    var source: String
    var createdAt: Date

    init(
        date: Date,
        totalAssets: Decimal,
        totalLiabilities: Decimal,
        source: SnapshotSource = .auto
    ) {
        self.id = UUID()
        self.date = date
        self.totalAssets = totalAssets
        self.totalLiabilities = totalLiabilities
        self.netWorth = totalAssets - totalLiabilities
        self.source = source.rawValue
        self.createdAt = .now
    }
}

/// Stored as `String` per the SwiftData enum migration trap memory —
/// adding a non-optional raw-value enum to an @Model crashes existing
/// stores. Accessor below stays type-safe at the call site.
extension NetWorthSnapshot {
    enum SnapshotSource: String {
        case auto         // scheduled (launch/midnight)
        case manual       // user tapped "Snapshot now"
        case backfill     // derived from transaction history
        case rebuild      // destructive rebuild action
    }

    var snapshotSource: SnapshotSource {
        SnapshotSource(rawValue: source) ?? .auto
    }
}
