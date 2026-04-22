import Foundation
import SwiftUI
import CoreGraphics
import AppKit
import Charts

// US Letter @ 72 dpi. SwiftUI's ImageRenderer lets us render any View
// into a CGContext; we feed that into a CGPDFContext and stamp one
// page per ImageRenderer invocation. Print-theme colors are forced
// inside every view so dark-mode screenshots don't bleed through.

@MainActor
struct PDFExporter: ReportExporter {
    let format: ReportExportFormat = .pdf

    private let pageSize = CGSize(width: 612, height: 792)
    private let margin: CGFloat = 40
    private let rowsPerTablePage = 28

    func data(for result: ReportResult) throws -> Data {
        let pages = buildPages(for: result)
        guard !pages.isEmpty else { throw ReportExportError.emptyReport }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            throw ReportExportError.emptyReport
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ReportExportError.emptyReport
        }

        let total = pages.count
        for (index, page) in pages.enumerated() {
            let framed = page
                .environment(\.colorScheme, .light)
                .frame(width: pageSize.width, height: pageSize.height)
                .background(Color.white)

            let renderer = ImageRenderer(content: AnyView(framed))
            renderer.proposedSize = .init(width: pageSize.width, height: pageSize.height)

            ctx.beginPDFPage(nil)
            renderer.render { _, draw in
                draw(ctx)
            }
            drawPageFooter(ctx: ctx, page: index + 1, total: total, title: result.summary.title)
            ctx.endPDFPage()
        }

        ctx.closePDF()
        return data as Data
    }

    // MARK: - Pages

    @ViewBuilder
    private func buildPages(for result: ReportResult) -> [AnyView] {
        var pages: [AnyView] = []
        pages.append(AnyView(CoverPage(result: result, pageSize: pageSize, margin: margin)))
        pages.append(contentsOf: bodyPages(for: result))
        return pages
    }

    private func bodyPages(for result: ReportResult) -> [AnyView] {
        switch result.body {
        case .periodSeries(let s):
            return [AnyView(PeriodSeriesPage(result: result, series: s, margin: margin))]
                + paginatedTable(
                    title: "By \(result.definition.groupBy.label.lowercased())",
                    headers: ["Period", "Income", "Expense", "Net", "Tx"],
                    rows: s.buckets.map { [$0.label, PrintFmt.currency($0.income), PrintFmt.currency($0.expense), PrintFmt.currency($0.net), String($0.transactionCount)] }
                )

        case .categoryBreakdown(let c):
            return [AnyView(CategoryPage(result: result, breakdown: c, margin: margin))]
                + paginatedTable(
                    title: "Breakdown",
                    headers: ["Category", "Amount", "Transactions", "% of total"],
                    rows: c.slices.map { [$0.name, PrintFmt.currency($0.amount), String($0.transactionCount), PrintFmt.percent($0.percentOfTotal)] }
                )

        case .merchantLeaderboard(let m):
            return paginatedTable(
                title: "Top merchants",
                headers: ["Rank", "Merchant", "Amount", "Transactions", "Average", "% of total"],
                rows: m.rows.enumerated().map { idx, r in
                    [String(idx + 1), r.displayName, PrintFmt.currency(r.amount), String(r.transactionCount), PrintFmt.currency(r.averageAmount), PrintFmt.percent(r.percentOfTotal)]
                }
            )

        case .heatmap(let h):
            return [AnyView(HeatmapPage(result: result, heatmap: h, margin: margin))]

        case .netWorth(let n):
            return [AnyView(NetWorthPage(result: result, payload: n, margin: margin))]
                + paginatedTable(
                    title: "Snapshots",
                    headers: ["Date", "Assets", "Liabilities", "Net worth"],
                    rows: n.snapshots.map { [PrintFmt.date($0.date), PrintFmt.currency($0.assets), PrintFmt.currency($0.liabilities), PrintFmt.currency($0.netWorth)] }
                )

        case .subscriptionRoster(let s):
            return paginatedTable(
                title: "Subscriptions",
                headers: ["Service", "Category", "Status", "Monthly", "Annual"],
                rows: s.rows.map { [$0.serviceName, $0.categoryName, $0.statusLabel, PrintFmt.currency($0.monthlyCost), PrintFmt.currency($0.annualCost)] }
            )

        case .recurringRoster(let r):
            let combined = (r.expenseRows + r.incomeRows).map { row -> [String] in
                [row.name, row.isIncome ? "Income" : "Expense", row.frequencyLabel, PrintFmt.currency(row.amount), PrintFmt.currency(row.normalizedMonthly)]
            }
            return paginatedTable(
                title: "Recurring activity",
                headers: ["Name", "Kind", "Frequency", "Amount", "Monthly"],
                rows: combined
            )

        case .goalsProgress(let g):
            return paginatedTable(
                title: "Goals",
                headers: ["Goal", "Progress", "Current", "Target", "Monthly"],
                rows: g.rows.map { [
                    $0.name,
                    PrintFmt.percent($0.percentComplete),
                    PrintFmt.currency($0.currentAmount),
                    PrintFmt.currency($0.targetAmount),
                    $0.monthlyContribution.map(PrintFmt.currency) ?? "—"
                ] }
            )

        case .empty(let reason):
            return [AnyView(EmptyPage(reason: reason, margin: margin))]
        }
    }

    private func paginatedTable(title: String, headers: [String], rows: [[String]]) -> [AnyView] {
        guard !rows.isEmpty else { return [] }
        let chunks = rows.chunked(into: rowsPerTablePage)
        return chunks.enumerated().map { idx, chunk in
            AnyView(TablePage(
                title: title + (chunks.count > 1 ? " (page \(idx + 1) of \(chunks.count))" : ""),
                headers: headers,
                rows: chunk,
                margin: margin
            ))
        }
    }

    // MARK: - Page footer

    private func drawPageFooter(ctx: CGContext, page: Int, total: Int, title: String) {
        let text = "\(title)  ·  Page \(page) of \(total)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor(white: 0.55, alpha: 1)
        ]
        let line = NSAttributedString(string: text, attributes: attrs)
        let lineSize = line.size()

        ctx.saveGState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        line.draw(at: CGPoint(
            x: (pageSize.width - lineSize.width) / 2,
            y: 20
        ))

        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}

// MARK: - Print theme

private enum PrintTheme {
    static let text      = Color(white: 0.10)
    static let secondary = Color(white: 0.30)
    static let muted     = Color(white: 0.55)
    static let hairline  = Color(white: 0.85)
    static let stripe    = Color(white: 0.97)
    static let accent    = Color(red: 0.20, green: 0.45, blue: 0.95)
    static let positive  = Color(red: 0.10, green: 0.55, blue: 0.30)
    static let negative  = Color(red: 0.75, green: 0.20, blue: 0.20)
    static let warning   = Color(red: 0.85, green: 0.55, blue: 0.10)
}

// MARK: - Cover

private struct CoverPage: View {
    let result: ReportResult
    let pageSize: CGSize
    let margin: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CENTMOND")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(PrintTheme.muted)
                Spacer()
                Text("Generated " + result.generatedAt.formatted(date: .long, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(PrintTheme.muted)
            }

            Spacer().frame(height: 80)

            Text(result.summary.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(2)
                .foregroundStyle(PrintTheme.accent)

            Text(result.definition.kind.tagline)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(PrintTheme.text)
                .padding(.top, 4)
                .lineLimit(3)

            Text(rangeLabel)
                .font(.system(size: 16))
                .foregroundStyle(PrintTheme.secondary)
                .padding(.top, 12)

            Rectangle()
                .fill(PrintTheme.hairline)
                .frame(height: 1)
                .padding(.top, 36)

            kpiGrid
                .padding(.top, 28)

            Spacer()

            HStack {
                Spacer()
                Text("\(result.summary.transactionCount) transactions · \(result.summary.currencyCode)")
                    .font(.system(size: 9))
                    .foregroundStyle(PrintTheme.muted)
            }
        }
        .padding(margin)
    }

    private var rangeLabel: String {
        PrintFmt.date(result.summary.rangeStart) + " — " + PrintFmt.date(result.summary.rangeEnd)
    }

    @ViewBuilder
    private var kpiGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 14) {
            ForEach(result.summary.kpis) { kpi in
                VStack(alignment: .leading, spacing: 4) {
                    Text(kpi.label.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(PrintTheme.muted)
                    Text(PrintFmt.kpi(kpi))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tone(kpi.tone))
                    if let d = kpi.deltaVsBaseline {
                        Text((d >= 0 ? "▲ " : "▼ ") + PrintFmt.currency(abs(d)))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(d >= 0 ? PrintTheme.positive : PrintTheme.negative)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PrintTheme.stripe)
                .overlay(Rectangle().stroke(PrintTheme.hairline, lineWidth: 0.5))
            }
        }
    }

    private func tone(_ t: ReportKPI.Tone) -> Color {
        switch t {
        case .neutral:  PrintTheme.text
        case .positive: PrintTheme.positive
        case .negative: PrintTheme.negative
        case .warning:  PrintTheme.warning
        }
    }
}

// MARK: - Section pages

private struct PeriodSeriesPage: View {
    let result: ReportResult
    let series: PeriodSeries
    let margin: CGFloat

    var body: some View {
        PageFrame(title: "Income vs expense", margin: margin) {
            Chart(series.buckets) { bucket in
                BarMark(x: .value("Period", bucket.label), y: .value("Income", NSDecimalNumber(decimal: bucket.income).doubleValue))
                    .foregroundStyle(PrintTheme.positive)
                    .position(by: .value("Type", "Income"))
                BarMark(x: .value("Period", bucket.label), y: .value("Expense", NSDecimalNumber(decimal: bucket.expense).doubleValue))
                    .foregroundStyle(PrintTheme.negative)
                    .position(by: .value("Type", "Expense"))
            }
            .frame(height: 260)

            totalsStrip
                .padding(.top, 16)
        }
    }

    private var totalsStrip: some View {
        HStack {
            totalTile(label: "Income",   value: series.totals.income,  color: PrintTheme.positive)
            totalTile(label: "Expense",  value: series.totals.expense, color: PrintTheme.negative)
            totalTile(label: "Net",      value: series.totals.net,     color: series.totals.net >= 0 ? PrintTheme.positive : PrintTheme.negative)
            if let sr = series.totals.savingsRate {
                totalTile(label: "Savings rate", value: Decimal(sr * 100), color: PrintTheme.text, format: .percent)
            }
        }
    }

    private func totalTile(label: String, value: Decimal, color: Color, format: ReportKPI.ValueFormat = .currency) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(1)
                .foregroundStyle(PrintTheme.muted)
            Text(PrintFmt.format(value, as: format))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CategoryPage: View {
    let result: ReportResult
    let breakdown: CategoryBreakdown
    let margin: CGFloat

    var body: some View {
        PageFrame(title: "Spending by category", margin: margin) {
            HStack(alignment: .top, spacing: 24) {
                Chart(breakdown.slices) { slice in
                    SectorMark(
                        angle: .value("Amount", NSDecimalNumber(decimal: slice.amount).doubleValue),
                        innerRadius: .ratio(0.6),
                        angularInset: 1
                    )
                    .foregroundStyle(by: .value("Category", slice.name))
                }
                .frame(width: 240, height: 240)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(breakdown.slices.prefix(10)) { slice in
                        HStack {
                            Text(slice.name)
                                .font(.system(size: 10))
                                .foregroundStyle(PrintTheme.text)
                                .lineLimit(1)
                            Spacer()
                            Text(PrintFmt.currency(slice.amount))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(PrintTheme.text)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct HeatmapPage: View {
    let result: ReportResult
    let heatmap: Heatmap
    let margin: CGFloat

    var body: some View {
        PageFrame(title: "Budget performance", margin: margin) {
            let maxValue = max(
                1,
                heatmap.cells.map { Double(truncating: $0.value as NSDecimalNumber) }.max() ?? 1
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    Text("").frame(width: 120, alignment: .leading)
                    ForEach(Array(heatmap.columnLabels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.system(size: 8))
                            .foregroundStyle(PrintTheme.muted)
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                    }
                }
                ForEach(Array(heatmap.rowLabels.enumerated()), id: \.offset) { rIdx, rowLabel in
                    HStack(spacing: 2) {
                        Text(rowLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(PrintTheme.text)
                            .frame(width: 120, alignment: .leading)
                            .lineLimit(1)

                        ForEach(cells(for: rIdx)) { cell in
                            heatCell(cell, maxValue: maxValue)
                        }
                    }
                }
            }
        }
    }

    private func cells(for row: Int) -> [IndexedCell] {
        heatmap.cells
            .filter { $0.row == row }
            .sorted { $0.column < $1.column }
            .map { IndexedCell(id: "\($0.row)-\($0.column)", cell: $0) }
    }

    private func heatCell(_ indexed: IndexedCell, maxValue: Double) -> some View {
        let cell = indexed.cell
        let v = Double(truncating: cell.value as NSDecimalNumber)
        let intensity = min(1, v / maxValue)
        let fill = cell.overBudget
            ? PrintTheme.negative.opacity(0.15 + 0.5 * intensity)
            : PrintTheme.accent.opacity(0.10 + 0.45 * intensity)
        return Rectangle()
            .fill(fill)
            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
            .overlay(
                Text(PrintFmt.currencyCompact(cell.value))
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(PrintTheme.text)
            )
    }

    private struct IndexedCell: Identifiable {
        let id: String
        let cell: Heatmap.Cell
    }
}

private struct NetWorthPage: View {
    let result: ReportResult
    let payload: NetWorthBody
    let margin: CGFloat

    var body: some View {
        PageFrame(title: "Net worth", margin: margin) {
            Chart(payload.snapshots) { p in
                LineMark(x: .value("Date", p.date), y: .value("Net worth", NSDecimalNumber(decimal: p.netWorth).doubleValue))
                    .foregroundStyle(PrintTheme.accent)
                    .interpolationMethod(.monotone)
            }
            .frame(height: 260)
        }
    }
}

private struct TablePage: View {
    let title: String
    let headers: [String]
    let rows: [[String]]
    let margin: CGFloat

    var body: some View {
        PageFrame(title: title, margin: margin) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { idx, h in
                        Text(h.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(PrintTheme.muted)
                            .frame(maxWidth: .infinity, alignment: idx == 0 ? .leading : .trailing)
                    }
                }
                .padding(.vertical, 6)

                Rectangle().fill(PrintTheme.hairline).frame(height: 0.5)

                ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { cIdx, cell in
                            Text(cell)
                                .font(.system(size: 10, design: cIdx == 0 ? .default : .monospaced))
                                .foregroundStyle(PrintTheme.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: cIdx == 0 ? .leading : .trailing)
                        }
                    }
                    .padding(.vertical, 5)
                    .background(rIdx.isMultiple(of: 2) ? Color.clear : PrintTheme.stripe)
                }
            }
        }
    }
}

private struct EmptyPage: View {
    let reason: ReportBody.EmptyReason
    let margin: CGFloat

    var body: some View {
        PageFrame(title: "No data", margin: margin) {
            VStack(spacing: 8) {
                Spacer()
                Text("No data to display")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PrintTheme.text)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(PrintTheme.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var description: String {
        switch reason {
        case .noTransactionsInRange: "The selected range contains no transactions."
        case .allFilteredOut:        "Every row was removed by the current filters."
        case .missingData:           "This report needs data that isn't in the store yet."
        }
    }
}

// MARK: - Page frame

private struct PageFrame<Content: View>: View {
    let title: String
    let margin: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(PrintTheme.accent)

            Rectangle().fill(PrintTheme.hairline).frame(height: 0.5)

            content()

            Spacer()
        }
        .padding(margin)
    }
}

// MARK: - Formatting helpers

private enum PrintFmt {
    static func currency(_ d: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        nf.maximumFractionDigits = 2
        return nf.string(from: NSDecimalNumber(decimal: d)) ?? "\(d)"
    }

    static func currencyCompact(_ d: Decimal) -> String {
        let v = Double(truncating: d as NSDecimalNumber)
        if abs(v) >= 1_000_000 { return String(format: "$%.1fM", v / 1_000_000) }
        if abs(v) >= 1_000     { return String(format: "$%.1fK", v / 1_000) }
        return String(format: "$%.0f", v)
    }

    static func percent(_ p: Double) -> String {
        "\(Int((p * 100).rounded()))%"
    }

    static func date(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func kpi(_ k: ReportKPI) -> String {
        format(k.value, as: k.valueFormat)
    }

    static func format(_ d: Decimal, as f: ReportKPI.ValueFormat) -> String {
        switch f {
        case .currency: return currency(d)
        case .percent:  return "\(Int(truncating: d as NSDecimalNumber))%"
        case .integer:  return "\(Int(truncating: d as NSDecimalNumber))"
        }
    }
}

// MARK: - Array chunks

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
