import Foundation
import SwiftUI
import AppKit

// Renders a `ReportResult` to a self-contained PNG (the PDF cover page
// reused at 2× scale). Used for "Copy as image" → pasteboard and the
// Share picker, so a quick Slack/Messages paste is one click.

@MainActor
enum ReportImageRenderer {

    static func pngData(for result: ReportResult, scale: CGFloat = 2.0) -> Data? {
        let view = ReportCoverImageView(result: result)
            .environment(\.colorScheme, .light)
            .frame(width: 680, height: 880)
            .background(Color.white)

        let renderer = ImageRenderer(content: AnyView(view))
        renderer.proposedSize = .init(width: 680, height: 880)
        renderer.scale = scale

        guard let nsImage = renderer.nsImage else { return nil }
        guard let tiff = nsImage.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func nsImage(for result: ReportResult, scale: CGFloat = 2.0) -> NSImage? {
        let view = ReportCoverImageView(result: result)
            .environment(\.colorScheme, .light)
            .frame(width: 680, height: 880)
            .background(Color.white)

        let renderer = ImageRenderer(content: AnyView(view))
        renderer.proposedSize = .init(width: 680, height: 880)
        renderer.scale = scale
        return renderer.nsImage
    }

    static func copyToPasteboard(_ result: ReportResult) -> Bool {
        guard let image = nsImage(for: result) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([image])
    }

    @discardableResult
    static func writePNG(for result: ReportResult, to url: URL) throws -> URL {
        guard let png = pngData(for: result) else {
            throw NSError(domain: "ReportImageRenderer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Image rendering failed."
            ])
        }
        try png.write(to: url, options: .atomic)
        return url
    }
}

// Self-contained cover view with print theme, reused from the PDF
// exporter. Kept in this file so there's one renderable image shape
// shared by pasteboard + share + save-as-PNG.
private struct ReportCoverImageView: View {
    let result: ReportResult

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CENTMOND")
                    .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.55))
                Spacer()
                Text(result.generatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(CentmondTheme.Typography.micro)
                    .foregroundStyle(Color(white: 0.55))
            }

            Spacer().frame(height: 40)

            Text(result.summary.title.uppercased())
                .font(CentmondTheme.Typography.captionSmallSemibold)
                .tracking(2)
                .foregroundStyle(Color(red: 0.20, green: 0.45, blue: 0.95))

            Text(result.definition.kind.tagline)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color(white: 0.10))
                .padding(.top, 4)
                .lineLimit(3)

            Text(result.summary.rangeStart.formatted(.dateTime.month(.abbreviated).day().year())
                 + " — "
                 + result.summary.rangeEnd.formatted(.dateTime.month(.abbreviated).day().year()))
                .font(CentmondTheme.Typography.bodyLarge)
                .foregroundStyle(Color(white: 0.30))
                .padding(.top, 10)

            Rectangle().fill(Color(white: 0.88)).frame(height: 0.5).padding(.top, 28)

            kpiGrid.padding(.top, 24)

            Spacer()

            HStack {
                Spacer()
                Text("\(result.summary.transactionCount) transactions · \(result.summary.currencyCode)")
                    .font(CentmondTheme.Typography.micro)
                    .foregroundStyle(Color(white: 0.55))
            }
        }
        .padding(40)
    }

    private var kpiGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
            ForEach(result.summary.kpis) { kpi in
                VStack(alignment: .leading, spacing: 4) {
                    Text(kpi.label.uppercased())
                        .font(CentmondTheme.Typography.micro.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(Color(white: 0.55))
                    Text(format(kpi))
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(tone(kpi.tone))
                    if let d = kpi.deltaVsBaseline {
                        Text((d >= 0 ? "▲ " : "▼ ") + formatDelta(abs(d)))
                            .font(CentmondTheme.Typography.overline)
                            .foregroundStyle(d >= 0 ? Color(red: 0.10, green: 0.55, blue: 0.30) : Color(red: 0.75, green: 0.20, blue: 0.20))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.97))
                .overlay(Rectangle().stroke(Color(white: 0.88), lineWidth: 0.5))
            }
        }
    }

    private func format(_ k: ReportKPI) -> String {
        switch k.valueFormat {
        case .currency: return currencyString(k.value)
        case .percent:  return "\(Int(truncating: k.value as NSDecimalNumber))%"
        case .integer:  return "\(Int(truncating: k.value as NSDecimalNumber))"
        }
    }

    private func formatDelta(_ d: Decimal) -> String {
        currencyString(d)
    }

    private func currencyString(_ d: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSDecimalNumber(decimal: d)) ?? "\(d)"
    }

    private func tone(_ t: ReportKPI.Tone) -> Color {
        switch t {
        case .neutral:  return Color(white: 0.10)
        case .positive: return Color(red: 0.10, green: 0.55, blue: 0.30)
        case .negative: return Color(red: 0.75, green: 0.20, blue: 0.20)
        case .warning:  return Color(red: 0.85, green: 0.55, blue: 0.10)
        }
    }
}
