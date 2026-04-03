import Foundation
import SwiftData

@Model
final class Insight {
    var id: UUID
    var type: InsightType
    var title: String
    var body: String
    var isDismissed: Bool
    var createdAt: Date

    init(
        type: InsightType,
        title: String,
        body: String
    ) {
        self.id = UUID()
        self.type = type
        self.title = title
        self.body = body
        self.isDismissed = false
        self.createdAt = .now
    }
}
