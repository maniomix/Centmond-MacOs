import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers
import AppKit

// Phase 3 detail shell: header + KPI strip + minimal body preview.
// The bespoke per-template visuals come in Phase 5; this view exists
// so the hub leads somewhere real and exporters in P6+ can hook in.

struct ReportDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let initialDefinition: ReportDefinition
    let onBack: () -> Void

    @State private var def: ReportDefinition
    @State private var result: ReportResult?
    @State private var showSaveSheet = false
    @State private var showExportSheet = false
    @State private var showScheduleSheet = false
    @State private var saveName: String = ""
    @State private var inspectorVisible = true

    @State private var aiSummary: String?
    @State private var aiSummarizing = false
    @State private var aiError: String?
    @State private var didAutoSummarize = false

    @AppStorage("reports.autoSummarize") private var autoSummarize = false

    init(definition: ReportDefinition, onBack: @escaping () -> Void) {
        self.initialDefinition = definition
        self.onBack = onBack
        self._def = State(initialValue: definition)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            HStack(spacing: 0) {
                if inspectorVisible {
                    ReportInspectorView(definition: $def)
                        .frame(width: 320)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
                        header
                        kpiStrip
                        aiNarrativeCard
                        bodyPreview
                    }
                    .padding(CentmondTheme.Spacing.xxl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .animation(CentmondTheme.Motion.layout, value: inspectorVisible)
        }
        .background(CentmondTheme.Colors.bgPrimary)
        .onAppear {
            regenerate()
            if autoSummarize && !didAutoSummarize && result != nil {
                didAutoSummarize = true
                runSummarize()
            }
        }
        .onChange(of: def) { _, _ in
            regenerate()
            aiSummary = nil
            aiError = nil
        }
        .sheet(isPresented: $showSaveSheet) {
            saveSheet
        }
        .sheet(isPresented: $showExportSheet) {
            if let result {
                ReportExportSheet(result: result) { showExportSheet = false }
            }
        }
        .sheet(isPresented: $showScheduleSheet) {
            ReportScheduleSheet(
                definition: def,
                defaultName: def.kind.title,
                onClose: { showScheduleSheet = false }
            )
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Button {
                onBack()
            } label: {
                Label("Reports", systemImage: "chevron.left")
                    .font(CentmondTheme.Typography.bodyMedium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CentmondTheme.Colors.textSecondary)

            Spacer()

            Button {
                inspectorVisible.toggle()
            } label: {
                Label(inspectorVisible ? "Hide filters" : "Show filters",
                      systemImage: "sidebar.left")
            }
            .buttonStyle(SecondaryChipButtonStyle())

            Button {
                def = initialDefinition
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .disabled(def == initialDefinition)

            Button {
                saveName = def.kind.title
                showSaveSheet = true
            } label: {
                Label("Save preset", systemImage: "bookmark")
            }
            .buttonStyle(SecondaryChipButtonStyle())

            Button {
                runSummarize()
            } label: {
                if aiSummarizing {
                    Label("Thinking…", systemImage: "sparkles")
                } else {
                    Label("Summarize with AI", systemImage: "sparkles")
                }
            }
            .buttonStyle(SecondaryChipButtonStyle())
            .disabled(result == nil || aiSummarizing)

            Menu {
                Button {
                    if let result {
                        if ReportImageRenderer.copyToPasteboard(result) {
                            // Optional: toast in a later pass.
                        }
                    }
                } label: {
                    Label("Copy as image", systemImage: "doc.on.clipboard")
                }
                Button {
                    if let result { ReportShareService.shareImage(result) }
                } label: {
                    Label("Share image…", systemImage: "square.and.arrow.up")
                }
                Button {
                    runSaveImage()
                } label: {
                    Label("Save image as PNG…", systemImage: "photo")
                }

                Divider()

                Button {
                    showScheduleSheet = true
                } label: {
                    Label("Schedule export…", systemImage: "calendar.badge.plus")
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up.on.square")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(result == nil)

            Button {
                showExportSheet = true
            } label: {
                Label("Export", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(result == nil)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgSecondary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: def.kind.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.accent)
                Text(def.kind.title)
                    .font(CentmondTheme.Typography.heading1)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
            if let result {
                Text(result.summary.rangeStart.formatted(.dateTime.month().day().year())
                     + " — "
                     + result.summary.rangeEnd.formatted(.dateTime.month().day().year())
                     + " · \(result.summary.transactionCount) transactions")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
        }
    }

    // MARK: - KPI strip

    @ViewBuilder
    private var kpiStrip: some View {
        if let kpis = result?.summary.kpis, !kpis.isEmpty {
            HStack(spacing: CentmondTheme.Spacing.md) {
                ForEach(kpis) { kpi in
                    kpiTile(kpi)
                }
            }
        }
    }

    private func kpiTile(_ kpi: ReportKPI) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                Text(kpi.label.uppercased())
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(0.5)

                Text(formatted(kpi))
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(toneColor(kpi.tone))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                if let delta = kpi.deltaVsBaseline {
                    HStack(spacing: 4) {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(formattedDecimal(abs(delta), as: kpi.valueFormat))
                    }
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(delta >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toneColor(_ tone: ReportKPI.Tone) -> Color {
        switch tone {
        case .neutral:  return CentmondTheme.Colors.textPrimary
        case .positive: return CentmondTheme.Colors.positive
        case .negative: return CentmondTheme.Colors.negative
        case .warning:  return CentmondTheme.Colors.warning
        }
    }

    private func formatted(_ kpi: ReportKPI) -> String {
        formattedDecimal(kpi.value, as: kpi.valueFormat)
    }

    private func formattedDecimal(_ d: Decimal, as f: ReportKPI.ValueFormat) -> String {
        switch f {
        case .currency: return CurrencyFormat.compact(d)
        case .percent:  return "\(Int(truncating: d as NSDecimalNumber))%"
        case .integer:  return "\(Int(truncating: d as NSDecimalNumber))"
        }
    }

    // MARK: - Body preview — dispatched to bespoke per-kind views (P5)

    @ViewBuilder
    private var bodyPreview: some View {
        if let result {
            switch result.body {
            case .periodSeries(let s):
                PeriodSeriesBodyView(series: s, groupByLabel: def.groupBy.label)
            case .categoryBreakdown(let c):
                CategoryBreakdownBodyView(breakdown: c)
            case .merchantLeaderboard(let m):
                MerchantLeaderboardBodyView(leaderboard: m)
            case .heatmap(let h):
                BudgetHeatmapBodyView(heatmap: h)
            case .netWorth(let n):
                NetWorthBodyPreview(payload: n)
            case .subscriptionRoster(let r):
                SubscriptionRosterBodyView(roster: r)
            case .recurringRoster(let r):
                RecurringRosterBodyView(roster: r)
            case .goalsProgress(let g):
                GoalsProgressBodyView(progress: g)
            case .empty(let reason):
                emptyPreview(reason)
            }
        }
    }

    private func emptyPreview(_ reason: ReportBody.EmptyReason) -> some View {
        EmptyStateView(
            icon: "doc.text.magnifyingglass",
            heading: emptyHeading(reason),
            description: emptyDescription(reason)
        )
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func emptyHeading(_ r: ReportBody.EmptyReason) -> String {
        switch r {
        case .noTransactionsInRange: "No transactions in this range"
        case .allFilteredOut:        "Filters removed every result"
        case .missingData:           "No data yet"
        }
    }

    private func emptyDescription(_ r: ReportBody.EmptyReason) -> String {
        switch r {
        case .noTransactionsInRange: "Try widening the date range or check that the right accounts are included."
        case .allFilteredOut:        "Loosen the filters in the inspector to see results."
        case .missingData:           "This report needs data that isn't in the store yet."
        }
    }

    // MARK: - Save preset sheet

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
            Text("Save preset")
                .font(CentmondTheme.Typography.heading2)

            TextField("Name", text: $saveName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { showSaveSheet = false }
                    .buttonStyle(SecondaryChipButtonStyle())
                Button("Save") {
                    let trimmed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let saved = SavedReport(name: trimmed, definition: def)
                    context.insert(saved)
                    saved.markRun()
                    try? context.save()
                    showSaveSheet = false
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(CentmondTheme.Spacing.xxl)
        .frame(width: 380)
    }

    // MARK: - AI narrative

    @ViewBuilder
    private var aiNarrativeCard: some View {
        if aiSummary != nil || aiSummarizing || aiError != nil {
            CardContainer {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CentmondTheme.Colors.accent)
                        Text("AI narrative")
                            .font(CentmondTheme.Typography.captionMedium)
                            .tracking(0.5)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        Spacer()
                        if aiSummary != nil && !aiSummarizing {
                            Button {
                                runSummarize()
                            } label: {
                                Label("Regenerate", systemImage: "arrow.clockwise")
                                    .font(CentmondTheme.Typography.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        }
                    }

                    if aiSummarizing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Generating a 3-bullet brief…")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        }
                    } else if let summary = aiSummary {
                        Text(summary)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let err = aiError {
                        Text(err)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.negative)
                    }
                }
            }
        }
    }

    private func runSaveImage() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(filenameSlug(result)).png"
        panel.canCreateDirectories = true
        panel.title = "Save report image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = try? ReportImageRenderer.writePNG(for: result, to: url)
    }

    private func filenameSlug(_ r: ReportResult) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let slug = r.summary.title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(slug)-\(df.string(from: r.generatedAt))"
    }

    private func runSummarize() {
        guard let result else { return }
        aiSummarizing = true
        aiSummary = nil
        aiError = nil
        Task {
            do {
                let narrative = try await ReportSummarizer.summarize(result)
                aiSummary = narrative
            } catch {
                aiError = error.localizedDescription
            }
            aiSummarizing = false
        }
    }

    // MARK: - Engine

    private func regenerate() {
        let fresh = ReportRunner.run(def, context: context)
        // Only count a run when the kind changes or we transition from nil — noisy
        // re-runs from filter tweaks would otherwise dominate the telemetry.
        if result?.definition.kind != fresh.definition.kind || result == nil {
            ReportsTelemetry.shared.recordRun(fresh.definition.kind)
        }
        result = fresh
    }
}
