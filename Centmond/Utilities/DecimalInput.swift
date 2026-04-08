import Foundation

/// Centralized rules for parsing user-entered numeric input into `Decimal`.
///
/// Mirrors the existing `Decimal(string:)` semantics already used throughout
/// the sheets — locale-independent, no thousands separators expected — so
/// that introducing this helper does not change behavior in any current
/// flow. Use these instead of inline `Decimal(string: text) ?? 0` patterns.
enum DecimalInput {

    // MARK: - Parsing

    /// Parse a user-entered string into a `Decimal`. Returns `nil` for
    /// blank input or unparseable input. Leading/trailing whitespace is
    /// tolerated.
    ///
    /// Important: this is locale-independent on purpose. The existing
    /// sheets all use `Decimal(string:)`, and switching to a localized
    /// formatter here would silently change which inputs parse.
    static func parse(_ value: String) -> Decimal? {
        let trimmed = TextNormalization.trimmed(value)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed)
    }

    /// Parse and require a strictly positive amount. Returns `nil` for
    /// blank, unparseable, zero, or negative input. Use this for fields
    /// like Transaction.amount, Goal.targetAmount, Subscription.amount.
    static func parsePositive(_ value: String) -> Decimal? {
        guard let d = parse(value), d > 0 else { return nil }
        return d
    }

    /// Parse and require a non-negative amount. Returns `nil` for
    /// blank, unparseable, or negative input; allows zero. Use this for
    /// optional balance fields like opening balance.
    static func parseNonNegative(_ value: String) -> Decimal? {
        guard let d = parse(value), d >= 0 else { return nil }
        return d
    }

    // MARK: - Predicates

    /// True when the input parses to a strictly positive `Decimal`.
    /// Convenience for sheet validation guards.
    static func isPositive(_ value: String) -> Bool {
        parsePositive(value) != nil
    }

    // MARK: - Round-trip for prefilled edit sheets

    /// Render a stored `Decimal` back into a plain editable string.
    /// Use this in `EditXxxSheet.init` instead of `"\(decimal)"`, which
    /// works today only because `Decimal.description` happens to be
    /// locale-independent — this helper makes the intent explicit and
    /// keeps the round-trip in one place.
    static func editableString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// Optional variant — empty string for `nil`. Use for prefilling
    /// optional decimal inputs like Goal.monthlyContribution.
    static func editableString(_ value: Decimal?) -> String {
        guard let value else { return "" }
        return editableString(value)
    }
}
