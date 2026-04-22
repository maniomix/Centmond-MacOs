import Foundation
import UniformTypeIdentifiers

nonisolated enum ReportExportFormat: String, CaseIterable, Hashable, Identifiable {
    case csv
    case pdf
    case xlsx

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .csv:  "CSV"
        case .pdf:  "PDF"
        case .xlsx: "Excel (.xlsx)"
        }
    }

    var detailLabel: String {
        switch self {
        case .csv:  "Raw data for Numbers, Excel, or any tool"
        case .pdf:  "Print-ready document with charts and tables"
        case .xlsx: "Multi-sheet workbook with live formulas"
        }
    }

    var fileExtension: String {
        switch self {
        case .csv:  "csv"
        case .pdf:  "pdf"
        case .xlsx: "xlsx"
        }
    }

    var symbol: String {
        switch self {
        case .csv:  "tablecells"
        case .pdf:  "doc.richtext"
        case .xlsx: "chart.bar.doc.horizontal"
        }
    }

    var utType: UTType {
        switch self {
        case .csv:  return .commaSeparatedText
        case .pdf:  return .pdf
        case .xlsx: return UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data
        }
    }

    var isAvailable: Bool {
        switch self {
        case .csv:  return true
        case .pdf:  return true
        case .xlsx: return true
        }
    }
}
