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

    @Relationship(inverse: \Transaction.account) var transactions: [Transaction]

    init(
        name: String,
        type: AccountType,
        institutionName: String? = nil,
        lastFourDigits: String? = nil,
        currentBalance: Decimal = 0,
        currency: String = "USD",
        colorHex: String? = nil,
        sortOrder: Int = 0
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
    }
}
