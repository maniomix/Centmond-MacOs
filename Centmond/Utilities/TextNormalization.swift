import Foundation

/// Centralized rules for normalizing user-entered text before validation,
/// comparison, or persistence.
///
/// All sheets, services, and importers should route string input through
/// this enum so that trimming and empty-to-nil semantics are identical
/// everywhere. The character set used for trimming is intentionally
/// `.whitespacesAndNewlines` so that pasted input carrying trailing
/// newlines is handled the same as typed input.
enum TextNormalization {

    /// The single trim character set used across the app. Do not introduce
    /// `.whitespaces` (without newlines) anywhere new — pasted text routinely
    /// contains trailing newlines and the two character sets diverge there.
    static let trimSet: CharacterSet = .whitespacesAndNewlines

    // MARK: - Required strings

    /// Trim whitespace and newlines. Use for required string fields where
    /// the empty string is still a "value" and you want to validate it
    /// separately via `isBlank`.
    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: trimSet)
    }

    /// True when the value is empty after trimming. Use for required-field
    /// validation in sheets, e.g. `if TextNormalization.isBlank(name) { ... }`.
    static func isBlank(_ value: String) -> Bool {
        trimmed(value).isEmpty
    }

    // MARK: - Optional strings

    /// Trim and convert blank input to `nil`. Use when persisting an optional
    /// `String?` field (notes, memo, institutionName, etc.) so that an
    /// empty text field never round-trips as `""`.
    static func trimmedOrNil(_ value: String) -> String? {
        let result = trimmed(value)
        return result.isEmpty ? nil : result
    }

    /// Trim and convert blank input to `nil`. Pass-through for already-optional
    /// values; treats `nil` and blank-after-trim identically.
    static func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        return trimmedOrNil(value)
    }

    // MARK: - Comparison helpers

    /// Case- and whitespace-insensitive equality. Use for uniqueness checks
    /// across user-entered names (account names, tag names, category names).
    static func equalsNormalized(_ lhs: String, _ rhs: String) -> Bool {
        trimmed(lhs).lowercased() == trimmed(rhs).lowercased()
    }
}
