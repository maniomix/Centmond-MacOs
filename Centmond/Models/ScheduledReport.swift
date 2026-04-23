import Foundation
import SwiftData

// Persisted schedule for composite report exports. All inputs are inlined
// (range, filter, sections, format) so the runner doesn't need a separate
// preset model to reference. The launch-time runner decodes lazily via
// computed accessors and tolerates legacy rows by swallowing decode
// failures — those get swept on launch by ReportScheduleService.

@Model
final class ScheduledReport {
    var id: UUID
    var name: String
    var sectionsRaw: String              // CSV of ReportSection.rawValue
    var rangeJSON: Data                  // ReportDateRange encoded
    var filterJSON: Data                 // ReportFilter encoded
    var formatRaw: String                // ReportExportFormat.rawValue
    var cadenceRaw: String               // ScheduledReportCadence.rawValue
    var destinationPath: String          // POSIX path (app is non-sandboxed)
    var isActive: Bool
    var createdAt: Date
    var nextFireDate: Date
    var lastFireDate: Date?
    var lastOutputFilename: String?
    var failureMessage: String?

    init(
        name: String,
        sections: Set<ReportSection>,
        range: ReportDateRange,
        filter: ReportFilter,
        format: ReportExportFormat,
        cadence: ScheduledReportCadence,
        destinationPath: String,
        nextFireDate: Date = .now
    ) {
        self.id = UUID()
        self.name = name
        self.sectionsRaw = sections.map(\.rawValue).sorted().joined(separator: ",")
        self.rangeJSON  = (try? Self.encoder.encode(range))  ?? Data()
        self.filterJSON = (try? Self.encoder.encode(filter)) ?? Data()
        self.formatRaw = format.rawValue
        self.cadenceRaw = cadence.rawValue
        self.destinationPath = destinationPath
        self.isActive = true
        self.createdAt = .now
        self.nextFireDate = nextFireDate
    }

    // MARK: - Computed accessors

    var sections: Set<ReportSection> {
        let parts = sectionsRaw.split(separator: ",").map(String.init)
        return Set(parts.compactMap { ReportSection(rawValue: $0) })
    }

    var range: ReportDateRange? {
        guard !rangeJSON.isEmpty else { return nil }
        return try? Self.decoder.decode(ReportDateRange.self, from: rangeJSON)
    }

    var filter: ReportFilter {
        guard !filterJSON.isEmpty,
              let decoded = try? Self.decoder.decode(ReportFilter.self, from: filterJSON)
        else { return ReportFilter() }
        return decoded
    }

    var format: ReportExportFormat {
        ReportExportFormat(rawValue: formatRaw) ?? .pdf
    }

    var cadence: ScheduledReportCadence {
        ScheduledReportCadence(rawValue: cadenceRaw) ?? .monthly
    }

    /// Decodable consistency check. Rows written by the old SavedReport-
    /// referencing schema have empty rangeJSON and no usable sections —
    /// the launch-time sweeper drops them.
    var isDecodable: Bool {
        range != nil && !sections.isEmpty
    }

    // MARK: - Codec

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

nonisolated enum ScheduledReportCadence: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case daily
    case weekly
    case monthly
    case quarterly

    nonisolated var id: String { rawValue }

    var label: String {
        switch self {
        case .daily:     "Daily"
        case .weekly:    "Weekly"
        case .monthly:   "Monthly"
        case .quarterly: "Quarterly"
        }
    }

    func nextFire(after date: Date, calendar: Calendar = .current) -> Date {
        let comp: DateComponents = {
            switch self {
            case .daily:     return DateComponents(day: 1)
            case .weekly:    return DateComponents(day: 7)
            case .monthly:   return DateComponents(month: 1)
            case .quarterly: return DateComponents(month: 3)
            }
        }()
        return calendar.date(byAdding: comp, to: date) ?? date
    }
}
