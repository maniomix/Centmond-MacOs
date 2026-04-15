import Foundation

/// Shared currency formatting for the entire app.
/// All money values flow through these functions for consistency.
enum CurrencyFormat {

    // MARK: - Standard (with cents): $1,234.56

    /// Format a Decimal amount with cents. Used for individual transaction amounts,
    /// account balances, and anywhere precision matters.
    static func standard(_ value: Decimal, currencyCode: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "$0.00"
    }

    // MARK: - Compact (no cents): $1,235

    /// Format a Decimal amount without cents. Used for summaries, totals,
    /// chart labels, and aggregated values where cents are noise.
    static func compact(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "$0"
    }

    // MARK: - Abbreviated: $1.2K, $3.4M

    /// Format a Double for chart axis labels and dense UI. Uses K/M suffixes.
    static func abbreviated(_ value: Double) -> String {
        let abs = Swift.abs(value)
        let sign = value < 0 ? "-" : ""
        if abs >= 1_000_000 {
            return "\(sign)$\(String(format: "%.1fM", abs / 1_000_000))"
        }
        if abs >= 1_000 {
            return "\(sign)$\(String(format: "%.1fK", abs / 1_000))"
        }
        return "\(sign)$\(Int(abs))"
    }

    // MARK: - Signed: +$500.00 / -$120.00

    /// Format with explicit sign prefix. Used for transaction displays
    /// where income vs expense needs visual distinction.
    static func signed(_ value: Decimal, isIncome: Bool) -> String {
        let formatted = standard(abs(value))
        return isIncome ? "+\(formatted)" : "-\(formatted)"
    }
}
