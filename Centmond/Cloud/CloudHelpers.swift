import Foundation

// ============================================================
// MARK: - CloudHelpers
// ============================================================
// Shared encode/decode utilities every Repository uses.
//   • Decimal ↔ Int (cents)
//   • Date ↔ ISO-8601 string (matches PostgREST `timestamptz`)
//
// Rounding for Decimal → cents uses **bankers' rounding** so
// half-cents go to the nearest even cent — the same default
// PostgreSQL uses, keeps math symmetric across platforms.
// ============================================================

enum CloudHelpers {

    // MARK: - Money

    /// Convert a Decimal currency value to integer cents.
    /// `12.345` → `1235` (banker's rounded to nearest even cent).
    static func toCents(_ d: Decimal) -> Int {
        let multiplied = d * 100
        let rounded = NSDecimalNumber(decimal: multiplied).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .bankers,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        )
        return rounded.intValue
    }

    /// Convert integer cents back to a Decimal currency value.
    static func toDecimal(cents: Int) -> Decimal {
        Decimal(cents) / 100
    }

    /// Decimal → Double for tables whose Postgres column is `numeric`
    /// (e.g. accounts.current_balance, goals.target_amount). Double has
    /// ~15 significant digits which covers any reasonable monetary
    /// value with no perceptible rounding for currency display. Use
    /// this instead of `toCents`/`toDecimal(cents:)` when the wire
    /// column is `numeric`, NOT `bigint`.
    static func numericDouble(_ d: Decimal) -> Double {
        NSDecimalNumber(decimal: d).doubleValue
    }

    /// Double → Decimal companion for `numericDouble`. PostgREST
    /// decodes `numeric` columns as JSON number → Swift Double.
    static func numericDecimal(_ d: Double) -> Decimal {
        Decimal(d)
    }

    // MARK: - Dates

    static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Tolerant parser for PostgREST timestamptz responses (with or
    /// without fractional seconds).
    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func isoString(_ date: Date) -> String {
        isoOut.string(from: date)
    }

    // MARK: - Safe id-indexing

    /// Build a `[UUID: T]` lookup from a list of models, tolerating
    /// duplicate ids (last entry wins). `Dictionary(uniqueKeysWithValues:)`
    /// is fatal on duplicates — under heavy data (e.g. after a large
    /// CSV import) two rows can share an id long enough for a pull to
    /// crash on the merge step. This helper never crashes; callers
    /// that want to clean up the extras can subtract `dict.count`
    /// from `items.count` to know how many duplicates there were.
    static func indexById<T>(_ items: [T], idOf: (T) -> UUID) -> [UUID: T] {
        var dict: [UUID: T] = [:]
        dict.reserveCapacity(items.count)
        for item in items {
            dict[idOf(item)] = item
        }
        return dict
    }

    // MARK: - UUID convenience

    static func uuidString(_ uuid: UUID?) -> String? {
        uuid?.uuidString
    }

    static func uuid(_ s: String?) -> UUID? {
        s.flatMap(UUID.init(uuidString:))
    }
}
