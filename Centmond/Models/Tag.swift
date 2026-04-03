import Foundation
import SwiftData

@Model
final class Tag {
    var id: UUID
    var name: String
    var colorHex: String

    @Relationship var transactions: [Transaction]

    init(name: String, colorHex: String = "64748B") {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.transactions = []
    }
}
