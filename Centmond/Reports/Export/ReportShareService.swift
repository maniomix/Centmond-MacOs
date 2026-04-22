import Foundation
import AppKit

@MainActor
enum ReportShareService {

    /// Presents the system share picker anchored to the key window's
    /// content view. Shares an NSImage snapshot of the report's cover,
    /// which every target (Messages, Mail, Notes, AirDrop, etc.) accepts.
    static func shareImage(_ result: ReportResult) {
        guard let image = ReportImageRenderer.nsImage(for: result) else { return }
        presentPicker(items: [image])
    }

    /// Shares a file URL — typically the output of ReportExportService
    /// after a successful export. Works with targets that prefer a
    /// document attachment (Mail) over a rasterized image.
    static func shareFile(_ url: URL) {
        presentPicker(items: [url])
    }

    private static func presentPicker(items: [Any]) {
        let picker = NSSharingServicePicker(items: items)

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let anchor = window.contentView
        else { return }

        let rect = NSRect(x: anchor.bounds.midX - 1, y: anchor.bounds.midY - 1, width: 2, height: 2)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }
}
