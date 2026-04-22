import Foundation
import SwiftData

// Launch-time runner: fetch active ScheduledReports whose nextFireDate
// has passed, run each through the engine+exporter, write to disk, and
// advance the cursor. Idempotent — overlapping fires are harmless.

@MainActor
enum ReportScheduleService {

    static func runDueSchedules(context: ModelContext) {
        let now = Date.now
        let activePredicate = #Predicate<ScheduledReport> { $0.isActive == true }
        guard let schedules = try? context.fetch(FetchDescriptor(predicate: activePredicate)) else {
            return
        }

        let due = schedules.filter { $0.nextFireDate <= now }
        guard !due.isEmpty else { return }

        // Pre-fetch SavedReports once; the service runs on launch alongside
        // other schedulers, so we avoid hammering SwiftData inside the loop.
        let savedReports = (try? context.fetch(FetchDescriptor<SavedReport>())) ?? []
        let savedByID = Dictionary(uniqueKeysWithValues: savedReports.map { ($0.id, $0) })

        for schedule in due {
            runOne(schedule, savedByID: savedByID, context: context, now: now)
        }

        try? context.save()
    }

    // MARK: - Run a single schedule

    private static func runOne(
        _ schedule: ScheduledReport,
        savedByID: [UUID: SavedReport],
        context: ModelContext,
        now: Date
    ) {
        guard let saved = savedByID[schedule.savedReportID],
              let def   = saved.definition else {
            schedule.failureMessage = "Saved report is missing."
            schedule.isActive = false
            return
        }

        let result = ReportRunner.run(def, context: context)
        let exporter = ReportExporterFactory.exporter(for: schedule.format)

        do {
            let data = try exporter.data(for: result)
            let filename = makeFilename(for: result, format: schedule.format, at: now)
            let url = URL(fileURLWithPath: schedule.destinationPath).appendingPathComponent(filename)

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)

            schedule.lastFireDate = now
            schedule.lastOutputFilename = filename
            schedule.failureMessage = nil
            saved.markRun(at: now)

            ReportsTelemetry.shared.recordExport(schedule.format)
        } catch {
            schedule.failureMessage = error.localizedDescription
        }

        // Always advance so a failing schedule doesn't re-fire on every
        // relaunch. The user sees the error in Settings and can resolve it.
        schedule.nextFireDate = schedule.cadence.nextFire(after: now)
    }

    // MARK: - Filename

    private static func makeFilename(for result: ReportResult, format: ReportExportFormat, at date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let slug = result.summary.title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(slug)-\(df.string(from: date)).\(format.fileExtension)"
    }
}
