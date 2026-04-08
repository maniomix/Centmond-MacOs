import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var format: ExportFormat = .csv
    @State private var dateRange: ExportDateRange = .allTime
    @State private var includeCategories = true
    @State private var includeAccounts = true
    @State private var includeNotes = true
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SheetHeader(title: "Export Data") { dismiss() }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xl) {
                    // Format
                    formField("FORMAT") {
                        Picker("", selection: $format) {
                            ForEach(ExportFormat.allCases) { fmt in
                                Text(fmt.displayName).tag(fmt)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Date range
                    formField("DATE RANGE") {
                        Picker("", selection: $dateRange) {
                            ForEach(ExportDateRange.allCases) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Include options
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                        Text("INCLUDE")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.3)

                        Toggle("Categories", isOn: $includeCategories)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)

                        Toggle("Accounts", isOn: $includeAccounts)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)

                        Toggle("Notes", isOn: $includeNotes)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    }

                    // Preview hint
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        Text("Exported file will be saved to your chosen location.")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }

                    if let exportError {
                        Text(exportError)
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.negative)
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Export") { performExport() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 420)
    }

    @ViewBuilder
    private func formField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text(label)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.3)

            content()
                .padding(.horizontal, CentmondTheme.Spacing.sm)
                .frame(height: CentmondTheme.Sizing.inputHeight)
                .background(CentmondTheme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                        .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                )
        }
    }

    private func performExport() {
        exportError = nil
        let options = BackupService.ExportOptions(
            format: format,
            dateRange: dateRange,
            includeCategories: includeCategories,
            includeAccounts: includeAccounts,
            includeNotes: includeNotes
        )

        do {
            let (ext, data) = try BackupService.exportTransactions(options: options, in: modelContext)
            #if os(macOS)
            let panel = NSSavePanel()
            panel.allowedContentTypes = []
            panel.nameFieldStringValue = defaultFilename(extension: ext)
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            try data.write(to: url)
            dismiss()
            #else
            dismiss()
            #endif
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func defaultFilename(extension ext: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "centmond-transactions-\(fmt.string(from: .now)).\(ext)"
    }
}

// MARK: - Export Types

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv
    case json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .csv: "CSV (.csv)"
        case .json: "JSON (.json)"
        }
    }
}

enum ExportDateRange: String, CaseIterable, Identifiable {
    case thisMonth
    case lastThreeMonths
    case thisYear
    case allTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thisMonth: "This Month"
        case .lastThreeMonths: "Last 3 Months"
        case .thisYear: "This Year"
        case .allTime: "All Time"
        }
    }
}
