import Foundation
import SwiftUI

/// Unified typed reason surfaced by the Review Queue. One reason per row —
/// a single transaction may produce multiple items (e.g. uncategorized AND
/// pending) and the hub dedupes/prioritizes via `dedupeKey`.
enum ReviewReasonCode: String, CaseIterable, Sendable {
    case uncategorizedTxn
    case pendingTxn
    case unusualAmount
    case duplicateCandidate
    case missingAccount
    case unlinkedRecurring
    case unlinkedSubscription
    case unreviewedTransfer
    case futureDated
    case negativeIncome
    case staleCleared

    var title: String {
        switch self {
        case .uncategorizedTxn:     "Needs category"
        case .pendingTxn:           "Pending"
        case .unusualAmount:        "Unusual amount"
        case .duplicateCandidate:   "Possible duplicate"
        case .missingAccount:       "Missing account"
        case .unlinkedRecurring:    "Unlinked recurring"
        case .unlinkedSubscription: "Unlinked subscription"
        case .unreviewedTransfer:   "Unreviewed transfer"
        case .futureDated:          "Future-dated"
        case .negativeIncome:       "Negative income"
        case .staleCleared:         "Stale cleared"
        }
    }

    var icon: String {
        switch self {
        case .uncategorizedTxn:     "questionmark.circle.fill"
        case .pendingTxn:           "clock.fill"
        case .unusualAmount:        "exclamationmark.triangle.fill"
        case .duplicateCandidate:   "doc.on.doc.fill"
        case .missingAccount:       "building.columns"
        case .unlinkedRecurring:    "arrow.triangle.2.circlepath"
        case .unlinkedSubscription: "repeat.circle.fill"
        case .unreviewedTransfer:   "arrow.left.arrow.right"
        case .futureDated:          "calendar.badge.exclamationmark"
        case .negativeIncome:       "arrow.down.right.circle.fill"
        case .staleCleared:         "hourglass"
        }
    }
}

enum ReviewSeverity: Int, Comparable, Sendable {
    case low = 0
    case suggested = 1
    case blocker = 2

    static func < (a: ReviewSeverity, b: ReviewSeverity) -> Bool { a.rawValue < b.rawValue }
}

/// One row in the Review Queue. Value type, Sendable, carries only the IDs
/// the UI needs to hydrate from the model context — so the service can be
/// rebuilt cheaply without capturing live @Model instances across threads.
struct ReviewItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let reason: ReviewReasonCode
    let severity: ReviewSeverity

    /// Primary subject — the transaction, recurring template, or
    /// subscription the row acts on. Most current reasons are
    /// transaction-bound.
    ///
    /// Note: a previous version also carried `accountID: UUID?` captured
    /// via `tx.account?.id`. Every capture triggered a SwiftData
    /// relationship fault per row, and nothing in the UI ever read the
    /// field, so it's been dropped. If a detector genuinely needs the
    /// account later, resolve it on-demand from the hydrated
    /// `Transaction` via `transactionID` instead of capturing eagerly.
    let transactionID: UUID?
    let recurringTemplateID: UUID?
    let subscriptionID: UUID?

    /// Stable key for dedupe + `DismissedDetection` lookup. Convention:
    /// "<reasonCode>:<subjectID>[:<suffix>]". Full persisted form uses the
    /// "review:" prefix (see `dismissalKey`).
    let dedupeKey: String

    /// Date used for secondary sort after severity. Usually the transaction
    /// date (so newer things surface first); services may override.
    let sortDate: Date

    /// Optional magnitude used for tertiary sort (higher first). Zero skips.
    let amountMagnitude: Decimal

    var dismissalKey: String { "review:\(dedupeKey)" }
}
