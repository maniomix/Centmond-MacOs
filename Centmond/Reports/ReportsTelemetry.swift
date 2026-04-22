import Foundation
import Observation

// Local-only counter for report runs and exports. Lives in UserDefaults
// so the hub can show "most used" templates + the user can see their
// own activity from Settings. Never leaves the device.

@MainActor
@Observable
final class ReportsTelemetry {
    static let shared = ReportsTelemetry()

    private let runsKey    = "reports.telemetry.runs"
    private let exportsKey = "reports.telemetry.exports"
    private let lastRunKey = "reports.telemetry.lastRun"

    // kind.rawValue -> count
    private(set) var runs: [String: Int]    = [:]
    // format.rawValue -> count
    private(set) var exports: [String: Int] = [:]
    // kind.rawValue -> ISO-8601 date of last run
    private(set) var lastRunByKind: [String: Date] = [:]

    private init() {
        load()
    }

    // MARK: - Recorders

    func recordRun(_ kind: ReportKind) {
        runs[kind.rawValue, default: 0] += 1
        lastRunByKind[kind.rawValue] = .now
        save()
    }

    func recordExport(_ format: ReportExportFormat) {
        exports[format.rawValue, default: 0] += 1
        save()
    }

    // MARK: - Queries

    func runCount(_ kind: ReportKind) -> Int {
        runs[kind.rawValue, default: 0]
    }

    func totalRuns() -> Int {
        runs.values.reduce(0, +)
    }

    func totalExports() -> Int {
        exports.values.reduce(0, +)
    }

    func topKinds(limit: Int = 3) -> [(ReportKind, Int)] {
        runs
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { pair in
                guard let kind = ReportKind(rawValue: pair.key) else { return nil }
                return (kind, pair.value)
            }
    }

    func reset() {
        runs = [:]
        exports = [:]
        lastRunByKind = [:]
        save()
    }

    // MARK: - Persistence

    private func load() {
        let d = UserDefaults.standard
        if let r = d.dictionary(forKey: runsKey) as? [String: Int] {
            runs = r
        }
        if let e = d.dictionary(forKey: exportsKey) as? [String: Int] {
            exports = e
        }
        if let l = d.dictionary(forKey: lastRunKey) as? [String: Date] {
            lastRunByKind = l
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(runs,          forKey: runsKey)
        d.set(exports,       forKey: exportsKey)
        d.set(lastRunByKind, forKey: lastRunKey)
    }
}
