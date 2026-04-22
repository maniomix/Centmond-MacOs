import SwiftUI

struct ReportExportSheet: View {
    let result: ReportResult
    let onClose: () -> Void

    @AppStorage("reports.defaultFormat") private var defaultFormatRaw: String = ReportExportFormat.pdf.rawValue

    @State private var format: ReportExportFormat = .csv
    @State private var filename: String = ""
    @State private var lastOutcome: ReportExportService.ExportOutcome?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                Text("Export")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(result.summary.title)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            VStack(spacing: CentmondTheme.Spacing.sm) {
                ForEach(ReportExportFormat.allCases) { f in
                    formatRow(f)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Filename")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                TextField("Filename", text: $filename)
                    .textFieldStyle(.roundedBorder)
            }

            if let outcome = lastOutcome {
                successRow(outcome)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }

            HStack {
                Spacer()
                Button("Close") { onClose() }
                    .buttonStyle(SecondaryChipButtonStyle())
                Button {
                    runExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!format.isAvailable || filename.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(CentmondTheme.Spacing.xxl)
        .frame(width: 460)
        .onAppear {
            if filename.isEmpty { filename = defaultFilename() }
            if let preferred = ReportExportFormat(rawValue: defaultFormatRaw), preferred.isAvailable {
                format = preferred
            }
        }
    }

    // MARK: - Format rows

    private func formatRow(_ f: ReportExportFormat) -> some View {
        Button {
            if f.isAvailable { format = f }
        } label: {
            HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
                Image(systemName: f.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(format == f ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(format == f ? CentmondTheme.Colors.accentMuted : CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(f.displayName)
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(f.isAvailable ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textTertiary)
                        if !f.isAvailable {
                            Text("Coming soon")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(CentmondTheme.Colors.bgTertiary)
                                .clipShape(Capsule())
                        }
                    }
                    Text(f.detailLabel)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Image(systemName: format == f ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(format == f ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
            }
            .padding(CentmondTheme.Spacing.md)
            .background(format == f ? CentmondTheme.Colors.accentMuted.opacity(0.5) : CentmondTheme.Colors.bgTertiary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                    .stroke(format == f ? CentmondTheme.Colors.accent.opacity(0.6) : CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
            .opacity(f.isAvailable ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }

    private func successRow(_ outcome: ReportExportService.ExportOutcome) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(CentmondTheme.Colors.positive)
            Text("Saved to \(outcome.url.lastPathComponent)")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Reveal") {
                ReportExportService.revealInFinder(outcome.url)
            }
            .buttonStyle(SecondaryChipButtonStyle())
        }
        .padding(CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.positive.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
    }

    // MARK: - Run

    private func runExport() {
        errorMessage = nil
        do {
            let outcome = try ReportExportService.run(
                result: result,
                format: format,
                suggestedFilename: filename
            )
            if let outcome {
                lastOutcome = outcome
                ReportsTelemetry.shared.recordExport(outcome.format)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func defaultFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let slug = result.summary.title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(slug)-\(df.string(from: result.generatedAt))"
    }
}
