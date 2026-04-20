import Foundation
import SwiftData

/// Persistent record that the user dismissed or snoozed an insight with this
/// `dedupeKey`. Checked by `AIInsightEngine.refresh` on every run so dismissed
/// insights don't re-surface the moment they match again.
///
/// `snoozeUntil == nil` → dismissed forever.
/// `snoozeUntil > now`  → snoozed, hidden until the date passes.
/// `snoozeUntil <= now` → expired, treated as not-dismissed on next refresh
///                        (the row is cleaned up lazily by the engine).
@Model
final class DismissedInsight {
    var id: UUID = UUID()
    var dedupeKey: String = ""
    var dismissedAt: Date = Date.now

    /// When the snooze expires. `nil` means dismissed permanently.
    var snoozeUntil: Date?

    init(dedupeKey: String, snoozeUntil: Date? = nil) {
        self.id = UUID()
        self.dedupeKey = dedupeKey
        self.dismissedAt = .now
        self.snoozeUntil = snoozeUntil
    }
}
