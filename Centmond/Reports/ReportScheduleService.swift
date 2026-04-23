import Foundation
import SwiftData

// Launch-time runner: sweep ScheduledReport rows, drop ones that no longer
// decode (orphans from the old SavedReport-referencing schema), then run
// every active+due row through the composite engine+exporter and advance
// its cursor. Always advances on failure so a broken schedule doesn't
// pin the loop on every relaunch.

@MainActor
enum ReportScheduleService {

    static func runDueSchedules(context: ModelContext) {
        let now = Date.now
        guard let schedules = try? context.fetch(FetchDescriptor<ScheduledReport>()) else {
            return
        }

        // One-time orphan sweep: any schedule whose range/sections didn't
        // round-trip (legacy rows, corrupt JSON) gets deleted. The user
        // re-creates it from the new schedule sheet.
        let orphans = schedules.filter { !$0.isDecodable }
        for orphan in orphans { context.delete(orphan) }

        let live = schedules.filter { $0.isDecodable && $0.isActive }
        let due = live.filter { $0.nextFireDate <= now }

        for schedule in due {
            runOne(schedule, context: context, now: now)
        }

        if !orphans.isEmpty || !due.isEmpty {
            context.persist()
        }
    }

    // MARK: - Run a single schedule

    private static func runOne(
        _ schedule: ScheduledReport,
        context: ModelContext,
        now: Date
    ) {
        guard let range = schedule.range else {
            schedule.failureMessage = "Schedule is missing a date range."
            schedule.isActive = false
            return
        }

        let defaultCurrency = UserDefaults.standard.string(forKey: "defaultCurrency") ?? "USD"
        let composite = CompositeReportRunner.run(
            range: range,
            filter: schedule.filter,
            sections: schedule.sections,
            context: context,
            currencyCode: defaultCurrency,
            now: now
        )

        let format = schedule.format
        let filename = makeFilename(for: schedule, format: format, at: now)
        let url = URL(fileURLWithPath: schedule.destinationPath).appendingPathComponent(filename)

        do {
            let data = try encode(composite, format: format)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)

            schedule.lastFireDate = now
            schedule.lastOutputFilename = filename
            schedule.failureMessage = nil

            ReportsTelemetry.shared.recordExport(format)
        } catch {
            schedule.failureMessage = error.localizedDescription
        }

        // Always advance so a failing schedule doesn't re-fire on every
        // relaunch. The user sees the error in Settings and can resolve it.
        schedule.nextFireDate = schedule.cadence.nextFire(after: now)
    }

    /// Mirrors CompositeExporter's per-format encoding without popping an
    /// NSSavePanel. Kept in sync manually — if CompositeExporter grows a
    /// new format branch, add it here too.
    private static func encode(_ c: CompositeReport, format: ReportExportFormat) throws -> Data {
        switch format {
        case .pdf:  return try CompositeExporter.encodePDF(c)
        case .csv:  return try CompositeExporter.encodeCSV(c)
        case .xlsx: return try CompositeExporter.encodeXLSX(c)
        }
    }

    // MARK: - Filename

    private static func makeFilename(for schedule: ScheduledReport, format: ReportExportFormat, at date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let slug = schedule.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let stem = slug.isEmpty ? "centmond-report" : slug
        return "\(stem)-\(df.string(from: date)).\(format.fileExtension)"
    }
}
