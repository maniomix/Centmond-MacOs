import Foundation
import AppKit
import PDFKit

// Orchestrates a single export of a CompositeReport across all three
// formats. Reuses the existing per-result PDFExporter / CSVExporter /
// XLSXExporter — this file is the glue, not the encoder.
//
// - PDF:   run PDFExporter per section, merge pages with PDFKit,
//          prepend a cover page.
// - CSV:   run CSVExporter per section, concatenate with `=== Section ===`
//          markers, single flat file.
// - XLSX:  a single consolidated sheet with every section stacked and
//          labeled. True one-sheet-per-section is a later polish.

@MainActor
enum CompositeExporter {

    struct ExportOutcome {
        let url: URL
        let format: ReportExportFormat
    }

    static func run(
        composite: CompositeReport,
        format: ReportExportFormat,
        suggestedFilename: String
    ) throws -> ExportOutcome? {
        let data = try encode(composite, format: format)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "\(suggestedFilename).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export report"
        panel.message = "Choose where to save \(format.displayName)"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return ExportOutcome(url: url, format: format)
    }

    /// Raw-bytes encoder — used by the schedule service to write without
    /// popping a save panel. Kept as the single branch-on-format location.
    static func encode(_ c: CompositeReport, format: ReportExportFormat) throws -> Data {
        switch format {
        case .pdf:  return try encodePDF(c)
        case .csv:  return try encodeCSV(c)
        case .xlsx: return try encodeXLSX(c)
        }
    }

    static func encodePDF(_ c: CompositeReport)  throws -> Data { try buildPDF(c) }
    static func encodeCSV(_ c: CompositeReport)  throws -> Data { try buildCSV(c) }
    static func encodeXLSX(_ c: CompositeReport) throws -> Data { try buildXLSX(c) }

    // MARK: - PDF

    private static func buildPDF(_ c: CompositeReport) throws -> Data {
        guard !c.sections.isEmpty else { throw ReportExportError.emptyReport }
        return try CompositeReportPDFBuilder.build(c)
    }

    // MARK: - CSV (single flat file)

    private static func buildCSV(_ c: CompositeReport) throws -> Data {
        guard !c.sections.isEmpty else { throw ReportExportError.emptyReport }

        var out = ""
        // Friendly preamble — opens cleanly as rows in Numbers/Excel/Sheets
        // without the `#` comment-prefix noise the old format used.
        out += csvRow(["Centmond Report"])
        out += "\r\n"
        out += csvRow(["Date range",   "\(prettyDate(c.resolvedStart)) – \(prettyDate(c.resolvedEnd))"])
        out += "\r\n"
        out += csvRow(["Sections",     c.sections.map(\.title).joined(separator: ", ")])
        out += "\r\n"
        out += csvRow(["Transactions", "\(c.transactionCount)"])
        out += "\r\n"
        out += csvRow(["Currency",     c.currencyCode])
        out += "\r\n"
        out += csvRow(["Generated",    prettyDateTime(c.generatedAt)])
        out += "\r\n\r\n"

        let exporter = CSVExporter()
        for (idx, section) in c.sections.enumerated() {
            guard let result = c.results[section] else { continue }
            let data = try exporter.data(for: result)
            // Strip the BOM the per-section exporter prepends.
            let clean = stripBOM(data)
            let text = String(data: clean, encoding: .utf8) ?? ""
            if idx > 0 { out += "\r\n\r\n" }
            out += csvRow([section.title])
            out += "\r\n"
            out += text
            out += "\r\n"
        }

        guard let utf8 = out.data(using: .utf8) else { return Data() }
        return bom + utf8
    }

    // MARK: - CSV helpers (local; mirror CSVExporter's RFC 4180 quoting)

    private static func csvRow(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    private static func csvField(_ raw: String) -> String {
        let needsQuoting = raw.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        if needsQuoting {
            let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return raw
    }

    private static func prettyDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private static func prettyDateTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private static let bom = Data([0xEF, 0xBB, 0xBF])

    private static func stripBOM(_ d: Data) -> Data {
        guard d.count >= 3,
              d[0] == 0xEF, d[1] == 0xBB, d[2] == 0xBF
        else { return d }
        return d.subdata(in: 3..<d.count)
    }

    // MARK: - XLSX (single consolidated sheet for now)

    private static func buildXLSX(_ c: CompositeReport) throws -> Data {
        guard !c.sections.isEmpty else { throw ReportExportError.emptyReport }
        return try CompositeXLSXBuilder.build(composite: c)
    }

    // MARK: - Helpers

}
