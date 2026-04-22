import Foundation
import SwiftData

// Persisted report preset. The full ReportDefinition is encoded as JSON
// so the schema doesn't need to migrate every time the definition type
// evolves — callers decode lazily via `definition` and swallow legacy
// shapes as a nil fallback.

@Model
final class SavedReport {
    var id: UUID
    var name: String
    var notes: String?
    var kindRaw: String?                  // ReportKind.rawValue snapshot for quick filtering
    var symbol: String?                   // SF Symbol override, optional
    var definitionJSON: Data
    var createdAt: Date
    var updatedAt: Date
    var lastRunAt: Date?
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        name: String,
        notes: String? = nil,
        definition: ReportDefinition,
        symbol: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.kindRaw = definition.kind.rawValue
        self.symbol = symbol
        self.definitionJSON = (try? Self.encoder.encode(definition)) ?? Data()
        self.createdAt = .now
        self.updatedAt = .now
        self.lastRunAt = nil
        self.isPinned = isPinned
    }

    var definition: ReportDefinition? {
        guard !definitionJSON.isEmpty else { return nil }
        return try? Self.decoder.decode(ReportDefinition.self, from: definitionJSON)
    }

    func update(_ new: ReportDefinition, name: String? = nil) {
        if let name { self.name = name }
        self.kindRaw = new.kind.rawValue
        if let data = try? Self.encoder.encode(new) {
            self.definitionJSON = data
        }
        self.updatedAt = .now
    }

    func markRun(at date: Date = .now) {
        self.lastRunAt = date
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
