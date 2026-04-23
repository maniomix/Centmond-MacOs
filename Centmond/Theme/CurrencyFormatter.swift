import Foundation

/// Shared currency formatting for the entire app.
/// All money values flow through these functions for consistency.
///
/// Currency code is read at format time from the `defaultCurrency`
/// AppStorage setting so the Settings → Default Currency picker
/// actually changes what users see. Before this change the code was
/// hardcoded to "USD" in every entry point and the setting was dead.
enum CurrencyFormat {

    /// Read the user's chosen currency code from AppStorage. Falls
    /// back to USD if unset or unrecognised.
    static var currentCurrencyCode: String {
        UserDefaults.standard.string(forKey: "defaultCurrency") ?? "USD"
    }

    /// Matching currency symbol for the abbreviated K/M formatter.
    /// NumberFormatter resolves this per locale; we build one on
    /// demand rather than caching so a live currency change takes
    /// effect immediately.
    static var currentCurrencySymbol: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currentCurrencyCode
        return f.currencySymbol ?? "$"
    }

    // MARK: - Standard (with cents): $1,234.56

    /// Format a Decimal amount with cents. Used for individual transaction amounts,
    /// account balances, and anywhere precision matters.
    static func standard(_ value: Decimal, currencyCode: String? = nil) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode ?? currentCurrencyCode
        // Locale.current so number grouping/decimal separators follow the
        // user's system (e.g. "1.234,56 €" in de_DE, "1,234.56" in en_US).
        // The currency CODE still comes from the app's defaultCurrency
        // setting — number formatting and currency choice are orthogonal.
        // Phase 7 polish (2026-04-24): pre-release formatter was hardcoded
        // en_US which gave non-US users a hybrid (their currency code but
        // US separators). Fix opts into real locale-aware formatting.
        formatter.locale = Locale.current
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "\(currentCurrencySymbol)0.00"
    }

    // MARK: - Compact (no cents): $1,235

    /// Format a Decimal amount without cents. Used for summaries, totals,
    /// chart labels, and aggregated values where cents are noise.
    static func compact(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currentCurrencyCode
        formatter.locale = Locale.current  // see note on `standard` above
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "\(currentCurrencySymbol)0"
    }

    // MARK: - Abbreviated: $1.2K, $3.4M

    /// Format a Double for chart axis labels and dense UI. Uses K/M suffixes.
    static func abbreviated(_ value: Double) -> String {
        let abs = Swift.abs(value)
        let sign = value < 0 ? "-" : ""
        let symbol = currentCurrencySymbol
        if abs >= 1_000_000 {
            return "\(sign)\(symbol)\(String(format: "%.1fM", abs / 1_000_000))"
        }
        if abs >= 1_000 {
            return "\(sign)\(symbol)\(String(format: "%.1fK", abs / 1_000))"
        }
        return "\(sign)\(symbol)\(Int(abs))"
    }

    // MARK: - Signed: +$500.00 / -$120.00

    /// Format with explicit sign prefix. Used for transaction displays
    /// where income vs expense needs visual distinction.
    static func signed(_ value: Decimal, isIncome: Bool) -> String {
        let formatted = standard(abs(value))
        return isIncome ? "+\(formatted)" : "-\(formatted)"
    }
}
