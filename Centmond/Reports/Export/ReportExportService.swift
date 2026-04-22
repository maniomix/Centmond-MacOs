import Foundation
import AppKit

@MainActor
enum ReportExportService {

    struct ExportOutcome {
        let url: URL
        let format: ReportExportFormat
    }

    /// Encodes, presents an NSSavePanel, writes to disk. Returns the
    /// destination URL on success or throws / returns nil if the user
    /// cancelled. Keep the orchestrator thin — encoding happens inside
    /// the per-format exporter.
    static func run(
        result: ReportResult,
        format: ReportExportFormat,
        suggestedFilename: String
    ) throws -> ExportOutcome? {
        let exporter = ReportExporterFactory.exporter(for: format)
        let data = try exporter.data(for: result)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "\(suggestedFilename).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export report"
        panel.message = "Choose where to save \(format.displayName)"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }

        try data.write(to: url, options: .atomic)
        return ExportOutcome(url: url, format: format)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
