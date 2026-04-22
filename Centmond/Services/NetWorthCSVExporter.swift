import Foundation
import SwiftData
import AppKit
import UniformTypeIdentifiers

// ============================================================
// MARK: - Net Worth CSV Exporter (P10)
// ============================================================
//
// Writes the full snapshot history to a CSV file the user picks
// via NSSavePanel. Columns: date (YYYY-MM-DD), assets,
// liabilities, net_worth, source. ISO date + plain Decimal so
// the file opens cleanly in Numbers / Excel without locale fuss.
// ============================================================

enum NetWorthCSVExporter {

    /// Returns true if a file was actually written. False on
    /// user cancel or write failure (logged silently).
    @MainActor
    static func exportSnapshots(context: ModelContext) -> Bool {
        let snaps = (try? context.fetch(FetchDescriptor<NetWorthSnapshot>(
            sortBy: [SortDescriptor(\.date)]
        ))) ?? []
        guard !snaps.isEmpty else { return false }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "centmond-networth-\(filenameDate()).csv"
        panel.title = "Export Net Worth History"

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        let csv = renderCSV(snaps: snaps)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Internals

    private static func renderCSV(snaps: [NetWorthSnapshot]) -> String {
        let header = "date,assets,liabilities,net_worth,source"
        let rows = snaps.map { s -> String in
            "\(isoDay(s.date)),\(plain(s.totalAssets)),\(plain(s.totalLiabilities)),\(plain(s.netWorth)),\(s.source)"
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private static func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    private static func filenameDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: .now)
    }

    /// Plain decimal string with no thousands separators or currency
    /// glyphs — keeps the CSV machine-parseable across locales.
    private static func plain(_ value: Decimal) -> String {
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 2, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}
