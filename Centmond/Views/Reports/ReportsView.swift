import SwiftUI
import SwiftData
import AppKit

// Dashboard layout — no sidebar. Top toolbar carries the title, exports,
// and schedule; a second toolbar row carries range chips, a Sections
// picker, and a Filters picker. The main pane is the live preview.

struct ReportsView: View {
    @Environment(\.modelContext) private var context

    /// Global currency preference (€, $, etc.). Piped into the runner so
    /// headers and every KPI render in the user's chosen currency instead
    /// of the engine default USD.
    @AppStorage("defaultCurrency") private var defaultCurrency: String = "USD"

    @State private var range: ReportDateRange = .preset(.last6Months)
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now
    @State private var customEnd: Date = .now
    @State private var enabled: Set<ReportSection> = Set(ReportSection.orderedAll)
    @State private var filter = ReportFilter()
    @State private var composite: CompositeReport?
    @State private var lastExport: CompositeExporter.ExportOutcome?
    @State private var exportError: String?
    @State private var showScheduleSheet = false
    @State private var showCustomRangePopover = false

    // Curated chip list. Dups omitted: 365d ≈ 12M, This yr ≈ YTD, 3M ≈ 90d.
    // Enum cases are kept intact so legacy persisted ranges still decode.
    private let shownPresets: [ReportDateRange.Preset] = [
        .mtd, .qtd, .ytd, .last30Days, .last90Days,
        .last6Months, .last12Months, .lastYear, .allTime
    ]

    var body: some View {
        VStack(spacing: 0) {
            primaryToolbar
            controlsBar
            preview
        }
        .background(CentmondTheme.Colors.bgPrimary)
        .onAppear { regenerate() }
        .onChange(of: range) { _, _ in regenerate() }
        .onChange(of: customStart) { _, _ in if case .custom = range { regenerate() } }
        .onChange(of: customEnd) { _, _ in if case .custom = range { regenerate() } }
        .onChange(of: enabled) { _, _ in regenerate() }
        .onChange(of: filter) { _, _ in regenerate() }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .sheet(isPresented: $showScheduleSheet) {
            ReportScheduleSheet(
                range: resolvedRange,
                filter: filter,
                sections: enabled,
                onClose: { showScheduleSheet = false }
            )
        }
    }

    private var resolvedRange: ReportDateRange {
        if case .custom = range {
            return .custom(start: customStart, end: customEnd)
        }
        return range
    }

    // MARK: - Primary toolbar

    private var primaryToolbar: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Text("Reports")
                .font(CentmondTheme.Typography.heading2)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            SectionHelpButton(screen: .reports)

            if let c = composite {
                Text("· \(fullRangeText(c)) · \(c.transactionCount) transactions")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Spacer()

            Button {
                showScheduleSheet = true
            } label: {
                Label("Schedule", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .disabled(enabled.isEmpty)
            .help("Schedule this report to export on a cadence")

            Divider().frame(height: 18)

            Button {
                runExport(.csv)
            } label: {
                Label("CSV", systemImage: "tablecells")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(composite == nil || enabled.isEmpty)

            Button {
                runExport(.xlsx)
            } label: {
                Label("Excel", systemImage: "chart.bar.doc.horizontal")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(composite == nil || enabled.isEmpty)

            Button {
                runExport(.pdf)
            } label: {
                Label("PDF", systemImage: "doc.richtext")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(composite == nil || enabled.isEmpty)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgSecondary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    // MARK: - Controls bar (second row)

    private var controlsBar: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(shownPresets, id: \.self) { preset in
                        rangeChip(preset)
                    }
                    customRangeChip
                }
            }

            Divider().frame(height: 18)

            sectionsMenu
            filtersMenu
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgPrimary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    private func rangeChip(_ preset: ReportDateRange.Preset) -> some View {
        let isSelected: Bool = {
            if case .preset(let p) = range { return p == preset }
            return false
        }()
        return Button {
            range = .preset(preset)
        } label: {
            Text(preset.shortLabel)
                .font(CentmondTheme.Typography.captionMedium)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.md)
                        .fill(isSelected ? CentmondTheme.Colors.accent.opacity(0.18) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.md)
                        .stroke(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                )
                .foregroundStyle(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var customRangeChip: some View {
        let isSelected: Bool = {
            if case .custom = range { return true }
            return false
        }()
        return Button {
            if case .custom = range {
                // already on custom — pop the date editor
                showCustomRangePopover = true
            } else {
                range = .custom(start: customStart, end: customEnd)
                showCustomRangePopover = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(CentmondTheme.Typography.captionSmall)
                Text(isSelected ? customRangeLabel : "Custom")
                    .font(CentmondTheme.Typography.captionMedium)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md)
                    .fill(isSelected ? CentmondTheme.Colors.accent.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md)
                    .stroke(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCustomRangePopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Custom range")
                    .font(CentmondTheme.Typography.heading3)
                DatePicker("Start", selection: $customStart, displayedComponents: .date)
                    .datePickerStyle(.compact)
                DatePicker("End", selection: $customEnd, displayedComponents: .date)
                    .datePickerStyle(.compact)
                HStack {
                    Spacer()
                    Button("Done") { showCustomRangePopover = false }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(CentmondTheme.Spacing.lg)
            .frame(width: 280)
        }
    }

    private var customRangeLabel: String {
        let df = DateFormatter(); df.dateFormat = "MMM d"
        return "\(df.string(from: customStart)) — \(df.string(from: customEnd))"
    }

    private var sectionsMenu: some View {
        Menu {
            Button(enabled.count == ReportSection.orderedAll.count ? "Clear all" : "Select all") {
                if enabled.count == ReportSection.orderedAll.count {
                    enabled = []
                } else {
                    enabled = Set(ReportSection.orderedAll)
                }
            }
            Divider()
            ForEach(ReportSection.orderedAll) { section in
                Button {
                    if enabled.contains(section) { enabled.remove(section) } else { enabled.insert(section) }
                } label: {
                    Label(
                        section.title + (enabled.contains(section) ? "  ✓" : ""),
                        systemImage: section.symbol
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(CentmondTheme.Typography.captionSmall)
                Text("Sections")
                    .font(CentmondTheme.Typography.captionMedium)
                Text("\(enabled.count)/\(ReportSection.orderedAll.count)")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Image(systemName: "chevron.down")
                    .font(CentmondTheme.Typography.micro.weight(.semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md).fill(Color.clear))
            .overlay(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md).stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1))
            .foregroundStyle(CentmondTheme.Colors.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var filtersMenu: some View {
        Menu {
            Toggle("Include transfers", isOn: Binding(
                get: { filter.includeTransfers },
                set: { filter.includeTransfers = $0 }
            ))
            Toggle("Only reviewed", isOn: Binding(
                get: { filter.onlyReviewed },
                set: { filter.onlyReviewed = $0 }
            ))
            Divider()
            Picker("Direction", selection: Binding(
                get: { filter.direction },
                set: { filter.direction = $0 }
            )) {
                ForEach(ReportFilter.Direction.allCases, id: \.self) { d in
                    Text(d.label).tag(d)
                }
            }
            if !filter.isEmpty {
                Divider()
                Button("Reset filters") { filter = ReportFilter() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    .font(CentmondTheme.Typography.captionSmall)
                Text("Filters")
                    .font(CentmondTheme.Typography.captionMedium)
                if !filter.isEmpty {
                    Text("·")
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Text(filterSummary)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                }
                Image(systemName: "chevron.down")
                    .font(CentmondTheme.Typography.micro.weight(.semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md).fill(Color.clear))
            .overlay(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md).stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1))
            .foregroundStyle(CentmondTheme.Colors.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var filterSummary: String {
        var parts: [String] = []
        if filter.direction != .any { parts.append(filter.direction.label) }
        if filter.includeTransfers   { parts.append("transfers") }
        if filter.onlyReviewed       { parts.append("reviewed") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
                SectionTutorialStrip(screen: .reports)
                coverBanner

                if enabled.isEmpty {
                    emptyStateNoSections
                } else if let c = composite {
                    ForEach(c.sections) { section in
                        if let result = c.results[section] {
                            ReportSectionCard(section: section, result: result)
                        }
                    }
                } else {
                    ProgressView("Preparing preview…")
                        .frame(maxWidth: .infinity, minHeight: 280)
                }
            }
            .padding(CentmondTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var coverBanner: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "doc.richtext.fill")
                        .font(CentmondTheme.Typography.heading2)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                    Text("Centmond Report")
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }

                if let c = composite {
                    Text(fullRangeText(c) + " · \(c.transactionCount) transactions · \(c.sections.count) sections")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }

                Text("What you see below is exactly what ships in the export — range, sections, and filters apply 1:1.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyStateNoSections: some View {
        EmptyStateView(
            icon: "square.stack.3d.up.slash",
            heading: "No sections selected",
            description: "Open the Sections menu in the toolbar to include one or more sections."
        )
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: - Engine

    private func regenerate() {
        composite = CompositeReportRunner.run(
            range: resolvedRange,
            filter: filter,
            sections: enabled,
            context: context,
            currencyCode: defaultCurrency
        )
    }

    // MARK: - Export

    private func runExport(_ format: ReportExportFormat) {
        guard let composite else { return }
        do {
            if let outcome = try CompositeExporter.run(
                composite: composite,
                format: format,
                suggestedFilename: suggestedFilename(composite)
            ) {
                lastExport = outcome
                ReportsTelemetry.shared.recordExport(format)
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func suggestedFilename(_ c: CompositeReport) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "centmond-report-\(df.string(from: c.generatedAt))"
    }

    private func fullRangeText(_ c: CompositeReport) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy"
        return "\(df.string(from: c.resolvedStart)) — \(df.string(from: c.resolvedEnd))"
    }
}
