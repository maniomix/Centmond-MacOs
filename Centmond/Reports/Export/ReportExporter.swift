import Foundation

protocol ReportExporter {
    var format: ReportExportFormat { get }
    func data(for result: ReportResult) throws -> Data
}

enum ReportExportError: LocalizedError {
    case notImplemented(ReportExportFormat)
    case emptyReport

    var errorDescription: String? {
        switch self {
        case .notImplemented(let f): return "\(f.displayName) export is not available yet."
        case .emptyReport:           return "Nothing to export — the report has no data."
        }
    }
}

@MainActor
enum ReportExporterFactory {
    static func exporter(for format: ReportExportFormat) -> ReportExporter {
        switch format {
        case .csv:  return CSVExporter()
        case .pdf:  return PDFExporter()
        case .xlsx: return XLSXExporter()
        }
    }
}

private struct StubExporter: ReportExporter {
    let format: ReportExportFormat
    func data(for result: ReportResult) throws -> Data {
        throw ReportExportError.notImplemented(format)
    }
}
