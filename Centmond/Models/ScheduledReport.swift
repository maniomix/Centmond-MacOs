import Foundation
import SwiftData

// Persisted schedule: "run this SavedReport on this cadence, drop the
// exported file in this folder." Idempotent — the launch-time runner
// only fires when `nextFireDate <= .now` and advances the cursor after
// each successful write.

@Model
final class ScheduledReport {
    var id: UUID
    var savedReportID: UUID                // references SavedReport.id
    var formatRaw: String                  // ReportExportFormat.rawValue
    var cadenceRaw: String                 // ScheduledReportCadence.rawValue
    var destinationPath: String            // plain POSIX path (app is non-sandboxed)
    var isActive: Bool
    var createdAt: Date
    var nextFireDate: Date
    var lastFireDate: Date?
    var lastOutputFilename: String?
    var failureMessage: String?

    init(
        savedReportID: UUID,
        format: ReportExportFormat,
        cadence: ScheduledReportCadence,
        destinationPath: String,
        nextFireDate: Date = .now
    ) {
        self.id = UUID()
        self.savedReportID = savedReportID
        self.formatRaw = format.rawValue
        self.cadenceRaw = cadence.rawValue
        self.destinationPath = destinationPath
        self.isActive = true
        self.createdAt = .now
        self.nextFireDate = nextFireDate
    }

    var format: ReportExportFormat {
        ReportExportFormat(rawValue: formatRaw) ?? .pdf
    }

    var cadence: ScheduledReportCadence {
        ScheduledReportCadence(rawValue: cadenceRaw) ?? .monthly
    }
}

enum ScheduledReportCadence: String, Codable, CaseIterable, Identifiable, Hashable {
    case daily
    case weekly
    case monthly
    case quarterly

    var id: String { rawValue }

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
