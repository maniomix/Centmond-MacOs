import Foundation
import SwiftData

@Model
final class SmartFolder {
    var id: UUID
    var name: String
    var filterJSON: String
    var sortOrder: Int
    var createdAt: Date

    init(name: String, filterJSON: String = "{}", sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.filterJSON = filterJSON
        self.sortOrder = sortOrder
        self.createdAt = .now
    }
}
