import Foundation
import SwiftData

@Model
final class Account {
    var id: UUID
    var name: String
    var type: AccountType
    var institutionName: String?
    var lastFourDigits: String?
    var currentBalance: Decimal
    var currency: String
    var colorHex: String?
    var isArchived: Bool
    var sortOrder: Int
    var createdAt: Date

    // Phase 2 — expanded fields
    var openingBalance: Decimal = 0
    var openingBalanceDate: Date?
    var notes: String?
    var includeInNetWorth: Bool = true
    var includeInBudgeting: Bool = true
    var isClosed: Bool = false
    var closedAt: Date?

    // Credit card fields
    var creditLimit: Decimal?
    var statementClosingDay: Int?
    var paymentDueDay: Int?

    @Relationship(inverse: \Transaction.account) var transactions: [Transaction]

    init(
        name: String,
        type: AccountType,
        institutionName: String? = nil,
        lastFourDigits: String? = nil,
        currentBalance: Decimal = 0,
        currency: String = "USD",
        colorHex: String? = nil,
        sortOrder: Int = 0,
        openingBalance: Decimal = 0,
        openingBalanceDate: Date? = nil,
        notes: String? = nil,
        includeInNetWorth: Bool = true,
        includeInBudgeting: Bool = true,
        creditLimit: Decimal? = nil,
        statementClosingDay: Int? = nil,
        paymentDueDay: Int? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.institutionName = institutionName
        self.lastFourDigits = lastFourDigits
        self.currentBalance = currentBalance
        self.currency = currency
        self.colorHex = colorHex
        self.isArchived = false
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.transactions = []
        self.openingBalance = openingBalance
        self.openingBalanceDate = openingBalanceDate
        self.notes = notes
        self.includeInNetWorth = includeInNetWorth
        self.includeInBudgeting = includeInBudgeting
        self.isClosed = false
        self.closedAt = nil
        self.creditLimit = creditLimit
        self.statementClosingDay = statementClosingDay
        self.paymentDueDay = paymentDueDay
    }

    // MARK: - Computed

    /// Effective color for UI: falls back to accent based on type
    var effectiveColor: String {
        if let hex = colorHex, !hex.isEmpty { return hex }
        switch type {
        case .checking:  return "3B82F6" // blue
        case .savings:   return "22C55E" // green
        case .creditCard: return "EF4444" // red
        case .investment: return "8B5CF6" // purple
        case .cash:      return "F59E0B" // amber
        case .other:     return "64748B" // slate
        }
    }

    /// Display status for badges
    var statusLabel: String? {
        if isClosed { return "Closed" }
        if isArchived { return "Archived" }
        return nil
    }

    /// True if the account is in an inactive state
    var isInactive: Bool {
        isClosed || isArchived
    }

    /// Credit utilization percentage (credit cards only)
    var creditUtilization: Double? {
        guard type == .creditCard,
              let limit = creditLimit,
              limit > 0 else { return nil }
        return Double(truncating: (abs(currentBalance) / limit) as NSDecimalNumber)
    }

    /// Available credit (credit cards only)
    var availableCredit: Decimal? {
        guard type == .creditCard, let limit = creditLimit else { return nil }
        return limit - abs(currentBalance)
    }
}

// MARK: - Common Currencies

enum SupportedCurrency: String, CaseIterable, Identifiable {
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case jpy = "JPY"
    case cad = "CAD"
    case aud = "AUD"
    case chf = "CHF"
    case cny = "CNY"
    case sek = "SEK"
    case nok = "NOK"
    case dkk = "DKK"
    case krw = "KRW"
    case inr = "INR"
    case brl = "BRL"
    case mxn = "MXN"
    case try_ = "TRY"
    case aed = "AED"
    case sar = "SAR"
    case irr = "IRR"

    var id: String { rawValue }

    var displayName: String {
        let locale = Locale(identifier: "en_US")
        return locale.localizedString(forCurrencyCode: rawValue) ?? rawValue
    }

    var symbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = rawValue
        formatter.locale = Locale(identifier: "en_US")
        return formatter.currencySymbol ?? rawValue
    }

    var label: String {
        "\(symbol) \(rawValue) — \(displayName)"
    }
}

// MARK: - Account Color Presets

enum AccountColorPreset: String, CaseIterable {
    case blue = "3B82F6"
    case green = "22C55E"
    case red = "EF4444"
    case purple = "8B5CF6"
    case amber = "F59E0B"
    case cyan = "06B6D4"
    case pink = "EC4899"
    case slate = "64748B"
    case orange = "F97316"
    case teal = "14B8A6"
}
