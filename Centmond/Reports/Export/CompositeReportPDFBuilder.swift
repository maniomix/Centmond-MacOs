import Foundation
import SwiftUI
import CoreGraphics
import AppKit
import Charts

// Purpose-built PDF for a CompositeReport. Produces a single branded
// document — cover + TOC + one-or-more pages per section + running
// footer — rather than merging per-section PDFs (which duplicated
// covers and lost the composite framing). This is the only PDF path
// for composite exports; the original PDFExporter still handles the
// legacy per-result case.

@MainActor
enum CompositeReportPDFBuilder {

    private static let pageSize = CGSize(width: 612, height: 792)  // US Letter @ 72dpi
    private static let margin: CGFloat = 48
    private static let rowsPerContinuationPage = 32
    private static let previewRowsOnSectionPage = 10

    static func build(_ c: CompositeReport) throws -> Data {
        // Two-pass: plan first so the TOC can print real page numbers,
        // then materialize views.
        let plans = buildPlans(c)
        var pages: [AnyView] = []

        let totalPages = plans.reduce(2) { $0 + $1.totalPages } // cover + toc
        pages.append(AnyView(CoverPage(composite: c)))
        pages.append(AnyView(TOCPage(composite: c, plans: plans, totalPages: totalPages)))

        for plan in plans {
            pages.append(AnyView(SectionPage(composite: c, plan: plan)))
            for (idx, chunk) in plan.continuationChunks.enumerated() {
                pages.append(AnyView(ContinuationTablePage(
                    section: plan.section,
                    title: plan.tableTitle,
                    headers: plan.tableHeaders,
                    rows: chunk,
                    part: idx + 2,                        // part 1 is on the section page
                    total: plan.continuationChunks.count + 1
                )))
            }
        }

        return try renderPages(pages, composite: c)
    }

    // MARK: - Plan

    fileprivate struct SectionPlan {
        let section: ReportSection
        let result: ReportResult
        let startPage: Int                     // 1-indexed, includes cover+toc offset
        let tableTitle: String
        let tableHeaders: [String]
        let previewRows: [[String]]            // shown on section page, may be empty
        let continuationChunks: [[[String]]]   // each chunk becomes one overflow page
        let showsInlineTable: Bool

        var totalPages: Int { 1 + continuationChunks.count }
    }

    private static func buildPlans(_ c: CompositeReport) -> [SectionPlan] {
        var plans: [SectionPlan] = []
        var pageCursor = 3  // cover=1, toc=2, first section starts at 3

        for section in c.sections {
            guard let result = c.results[section] else { continue }
            let (title, headers, rows) = tableData(for: result.body)

            let inline = showsInlineTable(for: result.body)
            let previewCount = inline ? min(previewRowsOnSectionPage, rows.count) : 0
            let preview = Array(rows.prefix(previewCount))
            let overflow = Array(rows.dropFirst(previewCount))
            let chunks = overflow.chunked(into: rowsPerContinuationPage)

            let plan = SectionPlan(
                section: section,
                result: result,
                startPage: pageCursor,
                tableTitle: title,
                tableHeaders: headers,
                previewRows: preview,
                continuationChunks: chunks,
                showsInlineTable: inline
            )
            plans.append(plan)
            pageCursor += plan.totalPages
        }
        return plans
    }

    /// Sections whose hero already lays the data out as structured rows
    /// (category legend, merchant rank ladder, goal cards) skip the inline
    /// table on the main page — showing the same values twice wastes space.
    /// Sections with abstract charts (bars, lines, areas) pack the full
    /// tabular data as a preview below the chart.
    private static func showsInlineTable(for body: ReportBody) -> Bool {
        switch body {
        case .periodSeries, .netWorth, .subscriptionRoster, .recurringRoster:
            return true
        case .categoryBreakdown, .merchantLeaderboard, .goalsProgress, .heatmap, .empty:
            return false
        }
    }

    // MARK: - Renderer

    private static func renderPages(_ pages: [AnyView], composite c: CompositeReport) throws -> Data {
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
        let footerText = "Centmond Report  ·  \(PrintFmt.rangeLong(c.resolvedStart, c.resolvedEnd))"

        for (index, page) in pages.enumerated() {
            let framed = page
                .environment(\.colorScheme, .light)
                .frame(width: pageSize.width, height: pageSize.height)
                .background(Color.white)

            let renderer = ImageRenderer(content: AnyView(framed))
            renderer.proposedSize = .init(width: pageSize.width, height: pageSize.height)

            ctx.beginPDFPage(nil)
            renderer.render { _, draw in draw(ctx) }
            // Cover page omits the footer — the cover has its own generated-on line.
            if index > 0 {
                drawFooter(ctx: ctx, page: index + 1, total: total, leftText: footerText)
            }
            ctx.endPDFPage()
        }

        ctx.closePDF()
        return data as Data
    }

    private static func drawFooter(ctx: CGContext, page: Int, total: Int, leftText: String) {
        let muted = NSColor(white: 0.55, alpha: 1)
        let hairline = NSColor(white: 0.88, alpha: 1)

        ctx.saveGState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        // Hairline above the footer
        hairline.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: margin, y: 38))
        path.line(to: NSPoint(x: pageSize.width - margin, y: 38))
        path.lineWidth = 0.5
        path.stroke()

        let leftAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: muted
        ]
        let rightAttrs = leftAttrs
        let left = NSAttributedString(string: leftText, attributes: leftAttrs)
        let right = NSAttributedString(string: "Page \(page) of \(total)", attributes: rightAttrs)
        left.draw(at: CGPoint(x: margin, y: 20))
        let rSize = right.size()
        right.draw(at: CGPoint(x: pageSize.width - margin - rSize.width, y: 20))

        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    // MARK: - Table data extraction

    fileprivate static func tableData(for body: ReportBody) -> (title: String, headers: [String], rows: [[String]]) {
        switch body {
        case .periodSeries(let s):
            return (
                "Period breakdown",
                ["Period", "Income", "Expense", "Net", "Tx"],
                s.buckets.map { [$0.label, PrintFmt.currency($0.income), PrintFmt.currency($0.expense), PrintFmt.currency($0.net), String($0.transactionCount)] }
            )
        case .categoryBreakdown(let c):
            return (
                "Category breakdown",
                ["Category", "Amount", "Tx", "% total"],
                c.slices.map { [$0.name, PrintFmt.currency($0.amount), String($0.transactionCount), PrintFmt.percent($0.percentOfTotal)] }
            )
        case .merchantLeaderboard(let m):
            return (
                "Top merchants",
                ["Rank", "Merchant", "Amount", "Tx", "Average", "% total"],
                m.rows.enumerated().map { i, r in
                    [String(i+1), r.displayName, PrintFmt.currency(r.amount), String(r.transactionCount), PrintFmt.currency(r.averageAmount), PrintFmt.percent(r.percentOfTotal)]
                }
            )
        case .netWorth(let n):
            return (
                "Snapshots",
                ["Date", "Assets", "Liabilities", "Net worth"],
                n.snapshots.map { [PrintFmt.date($0.date), PrintFmt.currency($0.assets), PrintFmt.currency($0.liabilities), PrintFmt.currency($0.netWorth)] }
            )
        case .subscriptionRoster(let r):
            return (
                "Subscriptions",
                ["Service", "Category", "Status", "Monthly", "Annual"],
                r.rows.map { [$0.serviceName, $0.categoryName, $0.statusLabel, PrintFmt.currency($0.monthlyCost), PrintFmt.currency($0.annualCost)] }
            )
        case .recurringRoster(let r):
            let rows = (r.expenseRows + r.incomeRows).map { row -> [String] in
                [row.name, row.isIncome ? "Income" : "Expense", row.frequencyLabel, PrintFmt.currency(row.amount), PrintFmt.currency(row.normalizedMonthly)]
            }
            return ("Recurring", ["Name", "Kind", "Frequency", "Amount", "Monthly"], rows)
        case .goalsProgress(let g):
            return (
                "Goals",
                ["Goal", "Progress", "Current", "Target", "Monthly"],
                g.rows.map { [$0.name, PrintFmt.percent($0.percentComplete), PrintFmt.currency($0.currentAmount), PrintFmt.currency($0.targetAmount), $0.monthlyContribution.map(PrintFmt.currency) ?? "—"] }
            )
        case .heatmap, .empty:
            return ("", [], [])
        }
    }
}

// MARK: - Print palette

enum PrintPalette {
    static let ink       = Color(red: 0.10, green: 0.12, blue: 0.16)
    static let text      = Color(white: 0.15)
    static let secondary = Color(white: 0.35)
    static let muted     = Color(white: 0.55)
    static let hairline  = Color(white: 0.88)
    static let stripe    = Color(white: 0.96)
    static let cardBG    = Color(red: 0.97, green: 0.98, blue: 1.00)
    static let accent    = Color(red: 0.20, green: 0.45, blue: 0.95)
    static let accentSoft = Color(red: 0.20, green: 0.45, blue: 0.95).opacity(0.08)
    static let positive  = Color(red: 0.10, green: 0.55, blue: 0.30)
    static let negative  = Color(red: 0.80, green: 0.20, blue: 0.20)
    static let warning   = Color(red: 0.85, green: 0.55, blue: 0.10)
}

// MARK: - Cover page

private struct CoverPage: View {
    let composite: CompositeReport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(PrintPalette.accent)
                        .frame(width: 4, height: 20)
                    Text("CENTMOND")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(3)
                        .foregroundStyle(PrintPalette.ink)
                }
                Spacer()
                Text(PrintFmt.generated(composite.generatedAt))
                    .font(CentmondTheme.Typography.micro)
                    .foregroundStyle(PrintPalette.muted)
            }

            Spacer().frame(height: 56)

            Text("FINANCIAL REPORT")
                .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
                .tracking(3)
                .foregroundStyle(PrintPalette.accent)

            Text(heroTitle)
                .font(CentmondTheme.Typography.display)
                .foregroundStyle(PrintPalette.ink)
                .padding(.top, 6)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            Text(PrintFmt.rangeLong(composite.resolvedStart, composite.resolvedEnd))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(PrintPalette.secondary)
                .padding(.top, 16)

            Rectangle()
                .fill(PrintPalette.hairline)
                .frame(height: 1)
                .padding(.top, 40)

            kpiOverview
                .padding(.top, 32)

            Spacer()

            HStack(spacing: 12) {
                coverMeta(label: "Transactions", value: "\(composite.transactionCount)")
                coverMeta(label: "Sections",     value: "\(composite.sections.count)")
                coverMeta(label: "Currency",     value: composite.currencyCode)
                Spacer()
            }
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 64)
    }

    // Tries to surface 4 headline KPIs from the Summary / Cash Flow section.
    // Falls back to an empty banner if no source section is present.
    @ViewBuilder
    private var kpiOverview: some View {
        if let kpis = coverKPIs, !kpis.isEmpty {
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
                ForEach(kpis) { kpi in
                    kpiTile(kpi)
                }
            }
        }
    }

    private var coverKPIs: [ReportKPI]? {
        if let summary = composite.results[.summary]?.summary.kpis { return summary }
        if let cash = composite.results[.cashFlow]?.summary.kpis   { return cash }
        return composite.results.values.first?.summary.kpis
    }

    private func kpiTile(_ kpi: ReportKPI) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kpi.label.uppercased())
                .font(CentmondTheme.Typography.microBold.weight(.semibold))
                .tracking(1)
                .foregroundStyle(PrintPalette.muted)
                .lineLimit(1)
            Text(PrintFmt.kpiCompact(kpi))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(color(for: kpi.tone))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrintPalette.cardBG)
        .overlay(Rectangle().stroke(PrintPalette.hairline, lineWidth: 0.5))
    }

    /// Hero title. If the composite has a custom title (user-typed when
    /// scheduling the report) prefer that; otherwise fall back to the
    /// section-count phrasing. Singular "section" when count == 1.
    private var heroTitle: String {
        let count = composite.sections.count
        return count == 1
            ? "A snapshot across 1 section"
            : "A snapshot across \(count) sections"
    }

    private func coverMeta(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 7, weight: .semibold))
                .tracking(1)
                .foregroundStyle(PrintPalette.muted)
            Text(value)
                .font(CentmondTheme.Typography.captionSmall.weight(.medium))
                .foregroundStyle(PrintPalette.text)
        }
    }

    private func color(for tone: ReportKPI.Tone) -> Color {
        switch tone {
        case .neutral:  PrintPalette.ink
        case .positive: PrintPalette.positive
        case .negative: PrintPalette.negative
        case .warning:  PrintPalette.warning
        }
    }
}

// MARK: - TOC page

private struct TOCPage: View {
    let composite: CompositeReport
    let plans: [CompositeReportPDFBuilder.SectionPlan]
    let totalPages: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Rectangle().fill(PrintPalette.accent).frame(width: 4, height: 20)
                Text("TABLE OF CONTENTS")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(3)
                    .foregroundStyle(PrintPalette.ink)
            }

            Text("In this report")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(PrintPalette.ink)
                .padding(.top, 18)

            Text("\(composite.sections.count) sections · \(totalPages) pages · \(composite.transactionCount) transactions")
                .font(CentmondTheme.Typography.captionSmall)
                .foregroundStyle(PrintPalette.muted)
                .padding(.top, 4)

            Rectangle().fill(PrintPalette.hairline).frame(height: 1).padding(.top, 14)

            VStack(spacing: 0) {
                ForEach(Array(plans.enumerated()), id: \.offset) { idx, plan in
                    tocRow(index: idx + 1, plan: plan)
                }
            }
            .padding(.top, 4)

            Spacer()

            // Chrome guide strip at bottom
            HStack(spacing: 12) {
                legend(symbol: "chart.bar.fill", text: "Hero visualization")
                legend(symbol: "tablecells",     text: "Detailed table")
                legend(symbol: "sparkles",       text: "Key findings")
                Spacer()
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 60)
    }

    private func tocRow(index: Int, plan: CompositeReportPDFBuilder.SectionPlan) -> some View {
        let pageRange: String = {
            if plan.totalPages == 1 { return "\(plan.startPage)" }
            return "\(plan.startPage)–\(plan.startPage + plan.totalPages - 1)"
        }()

        return HStack(spacing: 14) {
            Text(String(format: "%02d", index))
                .font(CentmondTheme.Typography.captionSmallSemibold.monospacedDigit())
                .foregroundStyle(PrintPalette.muted)
                .frame(width: 26, alignment: .leading)

            Image(systemName: plan.section.symbol)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(PrintPalette.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(plan.section.title)
                    .font(CentmondTheme.Typography.bodyLarge.weight(.semibold))
                    .foregroundStyle(PrintPalette.ink)
                Text(plan.section.subtitle)
                    .font(CentmondTheme.Typography.overlineRegular)
                    .foregroundStyle(PrintPalette.muted)
                    .lineLimit(1)
            }

            // Dotted leader
            DottedLeader()
                .frame(height: 1)
                .padding(.horizontal, 8)

            Text(pageRange)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(PrintPalette.ink)
                .frame(minWidth: 42, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private func legend(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(CentmondTheme.Typography.micro)
                .foregroundStyle(PrintPalette.accent)
            Text(text)
                .font(CentmondTheme.Typography.micro)
                .foregroundStyle(PrintPalette.muted)
        }
    }
}

private struct DottedLeader: View {
    var body: some View {
        GeometryReader { geo in
            let dotCount = Int(geo.size.width / 4)
            HStack(spacing: 2) {
                ForEach(0..<max(1, dotCount), id: \.self) { _ in
                    Circle()
                        .fill(PrintPalette.hairline)
                        .frame(width: 1.5, height: 1.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: geo.size.height, alignment: .center)
        }
    }
}

// MARK: - Section page (hero + KPI + Key Findings + inline preview table)

private struct SectionPage: View {
    let composite: CompositeReport
    let plan: CompositeReportPDFBuilder.SectionPlan

    private var section: ReportSection { plan.section }
    private var result: ReportResult { plan.result }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionBanner

            keyFindings
                .padding(.top, 14)

            kpiStrip
                .padding(.top, 12)

            hero
                .padding(.top, 14)

            if plan.showsInlineTable && !plan.previewRows.isEmpty {
                inlineTable
                    .padding(.top, 14)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 48)
    }

    // MARK: Inline preview table

    private var inlineTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(CentmondTheme.Typography.micro.weight(.semibold))
                    .foregroundStyle(PrintPalette.accent)
                Text(plan.tableTitle.uppercased())
                    .font(CentmondTheme.Typography.micro.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(PrintPalette.accent)
                if !plan.continuationChunks.isEmpty {
                    Text("· showing \(plan.previewRows.count) of \(plan.previewRows.count + plan.continuationChunks.reduce(0) { $0 + $1.count }) rows, full table on p.\(plan.startPage + 1)")
                        .font(CentmondTheme.Typography.micro.weight(.regular))
                        .foregroundStyle(PrintPalette.muted)
                }
            }

            Rectangle().fill(PrintPalette.hairline).frame(height: 0.5)

            HStack(spacing: 0) {
                ForEach(Array(plan.tableHeaders.enumerated()), id: \.offset) { idx, h in
                    Text(h.uppercased())
                        .font(.system(size: 7.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(PrintPalette.muted)
                        .frame(maxWidth: .infinity, alignment: idx == 0 ? .leading : .trailing)
                }
            }
            .padding(.vertical, 5)

            Rectangle().fill(PrintPalette.hairline).frame(height: 0.5)

            ForEach(Array(plan.previewRows.enumerated()), id: \.offset) { rIdx, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { cIdx, cell in
                        Text(cell)
                            .font(.system(size: 9, design: cIdx == 0 ? .default : .monospaced))
                            .foregroundStyle(PrintPalette.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: cIdx == 0 ? .leading : .trailing)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 3)
                .background(rIdx.isMultiple(of: 2) ? Color.clear : PrintPalette.stripe)
            }
        }
    }

    // MARK: Banner

    private var sectionBanner: some View {
        HStack(alignment: .center, spacing: 16) {
            Rectangle().fill(PrintPalette.accent).frame(width: 5, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: section.symbol)
                        .font(CentmondTheme.Typography.bodyMedium.weight(.semibold))
                        .foregroundStyle(PrintPalette.accent)
                    Text(section.title.uppercased())
                        .font(CentmondTheme.Typography.captionSmallSemibold.weight(.bold))
                        .tracking(2)
                        .foregroundStyle(PrintPalette.accent)
                }
                Text(section.subtitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(PrintPalette.ink)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    // MARK: Key Findings callout

    private var keyFindings: some View {
        let findings = KeyFindings.derive(section: section, result: result)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(CentmondTheme.Typography.overlineSemibold)
                    .foregroundStyle(PrintPalette.accent)
                Text("KEY FINDINGS")
                    .font(CentmondTheme.Typography.micro.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(PrintPalette.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(findings.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 7) {
                        Text("•")
                            .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
                            .foregroundStyle(PrintPalette.accent)
                        Text(line)
                            .font(.system(size: 10.5))
                            .foregroundStyle(PrintPalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrintPalette.accentSoft)
        .overlay(alignment: .leading) {
            Rectangle().fill(PrintPalette.accent).frame(width: 2)
        }
    }

    // MARK: KPI strip

    @ViewBuilder
    private var kpiStrip: some View {
        let kpis = result.summary.kpis
        if !kpis.isEmpty {
            HStack(spacing: 10) {
                ForEach(kpis) { kpi in
                    kpiTile(kpi)
                }
            }
        }
    }

    private func kpiTile(_ kpi: ReportKPI) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(color(for: kpi.tone))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(kpi.label.uppercased())
                    .font(.system(size: 7.5, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(PrintPalette.muted)
                Text(PrintFmt.kpi(kpi))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(color(for: kpi.tone))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if let d = kpi.deltaVsBaseline {
                    Text((d >= 0 ? "▲ " : "▼ ") + PrintFmt.currency(abs(d)))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(d >= 0 ? PrintPalette.positive : PrintPalette.negative)
                }
            }
            .padding(9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrintPalette.cardBG)
        .overlay(Rectangle().stroke(PrintPalette.hairline, lineWidth: 0.5))
    }

    // MARK: Hero visual dispatch

    @ViewBuilder
    private var hero: some View {
        switch result.body {
        case .periodSeries(let s):
            PeriodHero(series: s).frame(height: 190)        // inline-table: shorter
        case .categoryBreakdown(let c):
            CategoryHero(breakdown: c).frame(height: 300)   // hero IS the data
        case .merchantLeaderboard(let m):
            MerchantHero(rows: Array(m.rows.prefix(12))).frame(minHeight: 300)
        case .heatmap(let h):
            HeatmapHero(heatmap: h).frame(minHeight: 320)
        case .netWorth(let n):
            NetWorthHero(payload: n).frame(height: 190)     // inline-table: shorter
        case .subscriptionRoster(let r):
            SubscriptionHero(roster: r).frame(height: 120)
        case .recurringRoster(let r):
            RecurringHero(roster: r).frame(height: 120)
        case .goalsProgress(let g):
            GoalsHero(rows: Array(g.rows.prefix(8))).frame(minHeight: 280)
        case .empty(let reason):
            emptyBox(reason)
        }
    }

    private func emptyBox(_ r: ReportBody.EmptyReason) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(CentmondTheme.Typography.heading1.weight(.regular))
                .foregroundStyle(PrintPalette.muted)
            Text(emptyMsg(r))
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(PrintPalette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(24)
        .background(PrintPalette.stripe)
    }

    private func emptyMsg(_ r: ReportBody.EmptyReason) -> String {
        switch r {
        case .noTransactionsInRange: return "No transactions in this range."
        case .allFilteredOut:        return "Filters removed every result."
        case .missingData:           return "No data available for this section yet."
        }
    }

    private func color(for tone: ReportKPI.Tone) -> Color {
        switch tone {
        case .neutral:  PrintPalette.ink
        case .positive: PrintPalette.positive
        case .negative: PrintPalette.negative
        case .warning:  PrintPalette.warning
        }
    }
}

// MARK: - Continuation table page (overflow rows)

private struct ContinuationTablePage: View {
    let section: ReportSection
    let title: String
    let headers: [String]
    let rows: [[String]]
    let part: Int                   // 2-indexed (1 was the preview)
    let total: Int                  // total parts including preview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Rectangle().fill(PrintPalette.accent).frame(width: 4, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title.uppercased())
                        .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
                        .tracking(2)
                        .foregroundStyle(PrintPalette.accent)
                    Text("\(title) · continued \(part) of \(total)")
                        .font(CentmondTheme.Typography.bodyMedium.weight(.semibold))
                        .foregroundStyle(PrintPalette.ink)
                }
                Spacer()
                Image(systemName: "tablecells")
                    .font(CentmondTheme.Typography.bodyLarge)
                    .foregroundStyle(PrintPalette.muted)
            }
            .padding(.bottom, 12)

            Rectangle().fill(PrintPalette.hairline).frame(height: 0.5)

            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { idx, h in
                    Text(h.uppercased())
                        .font(CentmondTheme.Typography.microBold)
                        .tracking(0.5)
                        .foregroundStyle(PrintPalette.muted)
                        .frame(maxWidth: .infinity, alignment: idx == 0 ? .leading : .trailing)
                }
            }
            .padding(.vertical, 7)

            Rectangle().fill(PrintPalette.hairline).frame(height: 0.5)

            ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { cIdx, cell in
                        Text(cell)
                            .font(.system(size: 9.5, design: cIdx == 0 ? .default : .monospaced))
                            .foregroundStyle(PrintPalette.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: cIdx == 0 ? .leading : .trailing)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .background(rIdx.isMultiple(of: 2) ? Color.clear : PrintPalette.stripe)
            }

            Spacer()
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 48)
    }
}

// MARK: - Hero visuals

private struct PeriodHero: View {
    let series: PeriodSeries
    var body: some View {
        Chart(series.buckets) { b in
            BarMark(x: .value("Period", b.label),
                    y: .value("Income", NSDecimalNumber(decimal: b.income).doubleValue))
                .foregroundStyle(PrintPalette.positive)
                .position(by: .value("Type", "Income"))
            BarMark(x: .value("Period", b.label),
                    y: .value("Expense", NSDecimalNumber(decimal: b.expense).doubleValue))
                .foregroundStyle(PrintPalette.negative)
                .position(by: .value("Type", "Expense"))
            LineMark(x: .value("Period", b.label),
                     y: .value("Net", NSDecimalNumber(decimal: b.net).doubleValue))
                .foregroundStyle(PrintPalette.accent)
                .interpolationMethod(.monotone)
        }
        .chartLegend(position: .bottom)
    }
}

private struct CategoryHero: View {
    let breakdown: CategoryBreakdown
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            Chart(breakdown.slices.prefix(10)) { slice in
                SectorMark(
                    angle: .value("Amount", NSDecimalNumber(decimal: slice.amount).doubleValue),
                    innerRadius: .ratio(0.55),
                    angularInset: 1.2
                )
                .foregroundStyle(by: .value("Category", slice.name))
            }
            .frame(width: 220)
            .chartLegend(position: .bottom, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(breakdown.slices.prefix(10)) { slice in
                    HStack(spacing: 8) {
                        Text(slice.name)
                            .font(CentmondTheme.Typography.overlineRegular)
                            .foregroundStyle(PrintPalette.text)
                            .lineLimit(1)
                        Spacer()
                        Text(PrintFmt.currency(slice.amount))
                            .font(CentmondTheme.Typography.overlineSemibold.monospacedDigit())
                            .foregroundStyle(PrintPalette.text)
                        Text(PrintFmt.percent(slice.percentOfTotal))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(PrintPalette.muted)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(PrintPalette.hairline).frame(height: 0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct MerchantHero: View {
    let rows: [MerchantLeaderboard.Row]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { idx, row in
                HStack(spacing: 10) {
                    Text(String(format: "%02d", idx + 1))
                        .font(CentmondTheme.Typography.overlineSemibold.monospacedDigit())
                        .foregroundStyle(PrintPalette.muted)
                        .frame(width: 24, alignment: .leading)
                    Text(row.displayName)
                        .font(CentmondTheme.Typography.captionSmall.weight(.medium))
                        .foregroundStyle(PrintPalette.text)
                        .lineLimit(1)
                    Spacer()
                    ProgressBar(pct: row.percentOfTotal)
                        .frame(width: 90, height: 6)
                    Text(PrintFmt.currency(row.amount))
                        .font(CentmondTheme.Typography.captionSmallSemibold.monospacedDigit())
                        .foregroundStyle(PrintPalette.text)
                        .frame(width: 90, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(PrintPalette.hairline).frame(height: 0.5)
                }
            }
        }
    }
}

private struct ProgressBar: View {
    let pct: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(PrintPalette.stripe)
                Rectangle().fill(PrintPalette.accent)
                    .frame(width: geo.size.width * min(1, max(0, pct)))
            }
        }
    }
}

private struct HeatmapHero: View {
    let heatmap: Heatmap
    var body: some View {
        let maxValue = max(1, heatmap.cells.map { Double(truncating: $0.value as NSDecimalNumber) }.max() ?? 1)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text("").frame(width: 110, alignment: .leading)
                ForEach(Array(heatmap.columnLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(CentmondTheme.Typography.micro.weight(.regular))
                        .foregroundStyle(PrintPalette.muted)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                }
            }
            ForEach(Array(heatmap.rowLabels.prefix(14).enumerated()), id: \.offset) { rIdx, rowLabel in
                HStack(spacing: 2) {
                    Text(rowLabel)
                        .font(CentmondTheme.Typography.micro)
                        .foregroundStyle(PrintPalette.text)
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)
                    ForEach(heatmap.cells.filter { $0.row == rIdx }.sorted { $0.column < $1.column }, id: \.column) { cell in
                        cellView(cell, maxValue: maxValue)
                    }
                }
            }
        }
    }

    private func cellView(_ cell: Heatmap.Cell, maxValue: Double) -> some View {
        let v = Double(truncating: cell.value as NSDecimalNumber)
        let intensity = min(1, v / maxValue)
        let fill = cell.overBudget
            ? PrintPalette.negative.opacity(0.15 + 0.5 * intensity)
            : PrintPalette.accent.opacity(0.08 + 0.45 * intensity)
        return Rectangle()
            .fill(fill)
            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
            .overlay(
                Text(PrintFmt.currencyCompact(cell.value))
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(PrintPalette.text)
            )
    }
}

private struct NetWorthHero: View {
    let payload: NetWorthBody
    var body: some View {
        Chart(payload.snapshots) { p in
            AreaMark(x: .value("Date", p.date), y: .value("Net worth", NSDecimalNumber(decimal: p.netWorth).doubleValue))
                .foregroundStyle(LinearGradient(
                    colors: [PrintPalette.accent.opacity(0.35), PrintPalette.accent.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Date", p.date), y: .value("Net worth", NSDecimalNumber(decimal: p.netWorth).doubleValue))
                .foregroundStyle(PrintPalette.accent)
                .interpolationMethod(.monotone)
        }
    }
}

private struct SubscriptionHero: View {
    let roster: SubscriptionRoster
    var body: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, spacing: 10) {
            summaryBox(label: "Monthly",  value: PrintFmt.currency(roster.totalMonthly))
            summaryBox(label: "Annual",   value: PrintFmt.currency(roster.totalAnnual))
            summaryBox(label: "Active",   value: "\(roster.activeCount)")
            summaryBox(label: "Paused",   value: "\(roster.pausedCount)")
        }
    }
    private func summaryBox(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.microBold.weight(.semibold)).tracking(1)
                .foregroundStyle(PrintPalette.muted)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(PrintPalette.ink)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(PrintPalette.cardBG)
        .overlay(Rectangle().stroke(PrintPalette.hairline, lineWidth: 0.5))
    }
}

private struct RecurringHero: View {
    let roster: RecurringRoster
    var body: some View {
        HStack(spacing: 14) {
            block(label: "Monthly income",  value: roster.totalMonthlyIncome,  tone: .positive)
            block(label: "Monthly expense", value: roster.totalMonthlyExpense, tone: .negative)
            block(label: "Net",             value: roster.totalMonthlyIncome - roster.totalMonthlyExpense,
                  tone: roster.totalMonthlyIncome >= roster.totalMonthlyExpense ? .positive : .negative)
        }
    }
    private func block(label: String, value: Decimal, tone: ReportKPI.Tone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.micro.weight(.semibold)).tracking(1)
                .foregroundStyle(PrintPalette.muted)
            Text(PrintFmt.currency(value))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(toneColor(tone))
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PrintPalette.cardBG)
        .overlay(Rectangle().stroke(PrintPalette.hairline, lineWidth: 0.5))
    }
    private func toneColor(_ t: ReportKPI.Tone) -> Color {
        switch t {
        case .positive: PrintPalette.positive
        case .negative: PrintPalette.negative
        case .warning:  PrintPalette.warning
        case .neutral:  PrintPalette.ink
        }
    }
}

private struct GoalsHero: View {
    let rows: [GoalsProgressBody.Row]
    var body: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(row.name)
                            .font(CentmondTheme.Typography.captionSmallSemibold)
                            .foregroundStyle(PrintPalette.text)
                            .lineLimit(1)
                        Spacer()
                        Text(PrintFmt.percent(row.percentComplete))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(PrintPalette.accent)
                    }
                    ProgressBar(pct: row.percentComplete).frame(height: 6)
                    HStack {
                        Text(PrintFmt.currency(row.currentAmount))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(PrintPalette.muted)
                        Text(" / ")
                            .font(CentmondTheme.Typography.micro)
                            .foregroundStyle(PrintPalette.muted)
                        Text(PrintFmt.currency(row.targetAmount))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(PrintPalette.muted)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PrintPalette.cardBG)
                .overlay(Rectangle().stroke(PrintPalette.hairline, lineWidth: 0.5))
            }
        }
    }
}

// MARK: - Key Findings derivation

private enum KeyFindings {
    static func derive(section: ReportSection, result: ReportResult) -> [String] {
        switch result.body {
        case .periodSeries(let s):
            var lines: [String] = []
            lines.append("Income totaled \(PrintFmt.currency(s.totals.income)) across \(s.buckets.count) periods.")
            let net = s.totals.net
            lines.append("Net \(net >= 0 ? "surplus" : "shortfall") of \(PrintFmt.currency(abs(net))) vs expenses of \(PrintFmt.currency(s.totals.expense)).")
            if let sr = s.totals.savingsRate {
                lines.append("Savings rate came in at \(Int((sr * 100).rounded()))%.")
            }
            return lines

        case .categoryBreakdown(let c):
            var lines: [String] = []
            if let top = c.slices.first {
                lines.append("\(top.name) is the largest category at \(PrintFmt.currency(top.amount)) (\(PrintFmt.percent(top.percentOfTotal))).")
            }
            lines.append("\(c.slices.count) categories accounted for \(PrintFmt.currency(c.totalAmount)) in spending.")
            if c.uncategorizedAmount > 0 {
                lines.append("\(PrintFmt.currency(c.uncategorizedAmount)) remains uncategorized — consider tagging it.")
            }
            return lines

        case .merchantLeaderboard(let m):
            var lines: [String] = []
            if let top = m.rows.first {
                lines.append("\(top.displayName) led all merchants at \(PrintFmt.currency(top.amount)) (\(PrintFmt.percent(top.percentOfTotal))).")
            }
            let top3 = m.rows.prefix(3).reduce(Decimal.zero) { $0 + $1.amount }
            let share = m.totalAmount > 0 ? Double(truncating: (top3 / m.totalAmount) as NSDecimalNumber) : 0
            lines.append("Top 3 merchants represent \(PrintFmt.percent(share)) of total spend.")
            lines.append("\(m.rows.count) merchants ranked this period.")
            return lines

        case .heatmap(let h):
            let total = h.cells.reduce(Decimal.zero) { $0 + $1.value }
            let budget = h.cells.reduce(Decimal.zero) { $0 + ($1.baseline ?? 0) }
            let over = h.cells.filter(\.overBudget).count
            var lines: [String] = []
            lines.append("Actual spend of \(PrintFmt.currency(total)) vs budget of \(PrintFmt.currency(budget)).")
            lines.append("\(over) category-month\(over == 1 ? "" : "s") went over budget.")
            if budget > 0 {
                let ratio = Double(truncating: (total / budget) as NSDecimalNumber)
                lines.append(ratio > 1 ? "Overall \(Int((ratio - 1) * 100))% over the budgeted amount." : "Running \(Int((1 - ratio) * 100))% under the budgeted amount.")
            }
            return lines

        case .netWorth(let n):
            let delta = n.endingNetWorth - n.startingNetWorth
            var lines: [String] = []
            lines.append("Net worth ended at \(PrintFmt.currency(n.endingNetWorth)) (\(delta >= 0 ? "+" : "−")\(PrintFmt.currency(abs(delta))) vs period start).")
            lines.append("Assets at period close: \(PrintFmt.currency(n.assetsEnd)).")
            lines.append("Liabilities at period close: \(PrintFmt.currency(n.liabilitiesEnd)).")
            return lines

        case .subscriptionRoster(let r):
            var lines: [String] = []
            lines.append("\(r.activeCount) active subscription\(r.activeCount == 1 ? "" : "s") cost \(PrintFmt.currency(r.totalMonthly)) per month (\(PrintFmt.currency(r.totalAnnual)) annualized).")
            if r.pausedCount > 0 {
                lines.append("\(r.pausedCount) paused subscription\(r.pausedCount == 1 ? "" : "s") — review before they restart.")
            }
            if r.cancelledCount > 0 {
                lines.append("\(r.cancelledCount) cancelled this period.")
            }
            return lines

        case .recurringRoster(let r):
            var lines: [String] = []
            lines.append("Recurring income of \(PrintFmt.currency(r.totalMonthlyIncome))/month against \(PrintFmt.currency(r.totalMonthlyExpense))/month in expenses.")
            let net = r.totalMonthlyIncome - r.totalMonthlyExpense
            lines.append("Net recurring cash flow is \(PrintFmt.currency(net))/month.")
            lines.append("\(r.expenseRows.count + r.incomeRows.count) recurring item\(r.expenseRows.count + r.incomeRows.count == 1 ? "" : "s") tracked.")
            return lines

        case .goalsProgress(let g):
            var lines: [String] = []
            lines.append("\(g.rows.count) goal\(g.rows.count == 1 ? "" : "s") tracked — \(PrintFmt.currency(g.totalCurrent)) saved of \(PrintFmt.currency(g.totalTarget)) targeted.")
            if g.contributionsInRange > 0 {
                lines.append("Contributions during this period totaled \(PrintFmt.currency(g.contributionsInRange)).")
            }
            if let leader = g.rows.max(by: { $0.percentComplete < $1.percentComplete }) {
                lines.append("\(leader.name) leads progress at \(PrintFmt.percent(leader.percentComplete)).")
            }
            return lines

        case .empty(let reason):
            switch reason {
            case .noTransactionsInRange: return ["No transactions in the selected range."]
            case .allFilteredOut:        return ["Current filters removed every result."]
            case .missingData:           return ["This section needs data that isn't in the store yet."]
            }
        }
    }
}

// MARK: - Formatting

private enum PrintFmt {
    static func currency(_ d: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        // Pin to en_US so the report always reads as "$184,381" instead of
        // following the device locale (which renders USD as "184.381 US$"
        // on DE/IT/etc. devices — periods for thousands, symbol trailing).
        nf.locale = Locale(identifier: "en_US")
        nf.maximumFractionDigits = 0
        return nf.string(from: NSDecimalNumber(decimal: d)) ?? "\(d)"
    }

    static func currencyCompact(_ d: Decimal) -> String {
        let v = Double(truncating: d as NSDecimalNumber)
        if abs(v) >= 1_000_000 { return String(format: "$%.1fM", v / 1_000_000) }
        if abs(v) >= 1_000     { return String(format: "$%.1fK", v / 1_000) }
        return String(format: "$%.0f", v)
    }

    /// KPI formatter for tight layouts (cover tiles, strips). Currency
    /// values use the compact form ($184K) so they fit a single line at
    /// 22pt bold; percent/integer fall through to the full formatter.
    static func kpiCompact(_ k: ReportKPI) -> String {
        switch k.valueFormat {
        case .currency: return currencyCompact(k.value)
        case .percent:  return "\(Int(truncating: k.value as NSDecimalNumber))%"
        case .integer:  return "\(Int(truncating: k.value as NSDecimalNumber))"
        }
    }

    static func percent(_ p: Double) -> String {
        "\(Int((p * 100).rounded()))%"
    }

    static func date(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func rangeLong(_ start: Date, _ end: Date) -> String {
        "\(date(start)) — \(date(end))"
    }

    static func generated(_ d: Date) -> String {
        "Generated " + d.formatted(date: .long, time: .shortened)
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

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
