import Foundation

// Minimal Office Open XML spreadsheet writer. Builds a 2-sheet workbook
// (Summary + Data) with inline strings, a few shared number formats
// (currency / percent / date), and zips the whole bundle via
// SimpleZipWriter. No third-party deps — portable to any macOS machine.

struct XLSXExporter: ReportExporter {
    let format: ReportExportFormat = .xlsx

    // Style indexes wired into styles.xml below.
    private enum S {
        static let general  = 0
        static let currency = 1
        static let percent  = 2
        static let date     = 3
        static let header   = 4
        static let bold     = 5
    }

    func data(for result: ReportResult) throws -> Data {
        let summarySheet = buildSummarySheet(result)
        let (dataSheetXML, dataSheetName) = buildDataSheet(result)

        let parts: [SimpleZipWriter.Entry] = [
            .init(path: "[Content_Types].xml", data: contentTypes.data(using: .utf8)!),
            .init(path: "_rels/.rels", data: rootRels.data(using: .utf8)!),
            .init(path: "xl/workbook.xml", data: workbookXML(dataSheetName: dataSheetName).data(using: .utf8)!),
            .init(path: "xl/_rels/workbook.xml.rels", data: workbookRels.data(using: .utf8)!),
            .init(path: "xl/styles.xml", data: stylesXML.data(using: .utf8)!),
            .init(path: "xl/worksheets/sheet1.xml", data: summarySheet.data(using: .utf8)!),
            .init(path: "xl/worksheets/sheet2.xml", data: dataSheetXML.data(using: .utf8)!)
        ]

        return SimpleZipWriter.make(parts)
    }

    // MARK: - Sheet builders

    private func buildSummarySheet(_ r: ReportResult) -> String {
        let iso = ISO8601DateFormatter()
        var rows: [[Cell]] = [
            [.text("Field", style: S.header), .text("Value", style: S.header)],
            [.text("Report"),      .text(r.summary.title, style: S.bold)],
            [.text("Kind"),        .text(r.definition.kind.rawValue)],
            [.text("Range start"), .text(iso.string(from: r.summary.rangeStart))],
            [.text("Range end"),   .text(iso.string(from: r.summary.rangeEnd))],
            [.text("Group by"),    .text(r.definition.groupBy.rawValue)],
            [.text("Comparison"),  .text(r.definition.comparison.rawValue)],
            [.text("Generated"),   .text(iso.string(from: r.generatedAt))],
            [.text("Transactions"), .number(Decimal(r.summary.transactionCount))],
            [.text("Currency"),    .text(r.summary.currencyCode)],
            [],
            [.text("KPI", style: S.header), .text("Value", style: S.header)]
        ]

        for kpi in r.summary.kpis {
            rows.append([
                .text(kpi.label),
                cell(for: kpi.value, format: kpi.valueFormat)
            ])
            if let delta = kpi.deltaVsBaseline {
                rows.append([
                    .text("  Δ vs baseline"),
                    cell(for: delta, format: kpi.valueFormat)
                ])
            }
        }

        return renderSheet(name: "Summary", rows: rows)
    }

    private func buildDataSheet(_ r: ReportResult) -> (xml: String, name: String) {
        let (headers, rows, name): ([String], [[Cell]], String) = {
            switch r.body {
            case .periodSeries(let s):
                return (
                    ["Bucket", "Start", "End", "Income", "Expense", "Net", "Tx", "Series"],
                    s.buckets.map { mkPeriodRow($0, series: "actual") }
                        + (s.baselineBuckets ?? []).map { mkPeriodRow($0, series: "baseline") },
                    "Periods"
                )

            case .categoryBreakdown(let c):
                var data = c.slices.map { slice -> [Cell] in
                    [
                        .text(slice.name),
                        .number(slice.amount, style: S.currency),
                        .number(Decimal(slice.transactionCount)),
                        .number(Decimal(slice.percentOfTotal), style: S.percent),
                        slice.deltaVsBaseline.map { .number($0, style: S.currency) } ?? .empty
                    ]
                }
                if c.uncategorizedAmount > 0 {
                    data.append([
                        .text("Uncategorized"),
                        .number(c.uncategorizedAmount, style: S.currency),
                        .empty, .empty, .empty
                    ])
                }
                return (
                    ["Category", "Amount", "Transactions", "% of total", "Δ vs baseline"],
                    data,
                    "Categories"
                )

            case .merchantLeaderboard(let m):
                let iso = ISO8601DateFormatter()
                let data = m.rows.enumerated().map { idx, row -> [Cell] in
                    [
                        .number(Decimal(idx + 1)),
                        .text(row.displayName),
                        .number(row.amount, style: S.currency),
                        .number(Decimal(row.transactionCount)),
                        .number(row.averageAmount, style: S.currency),
                        .number(Decimal(row.percentOfTotal), style: S.percent),
                        .text(iso.string(from: row.firstSeen)),
                        .text(iso.string(from: row.lastSeen))
                    ]
                }
                return (
                    ["Rank", "Merchant", "Amount", "Transactions", "Average", "% of total", "First seen", "Last seen"],
                    data,
                    "Merchants"
                )

            case .heatmap(let h):
                let data = h.cells.map { cell -> [Cell] in
                    let r = cell.row < h.rowLabels.count ? h.rowLabels[cell.row] : ""
                    let c = cell.column < h.columnLabels.count ? h.columnLabels[cell.column] : ""
                    return [
                        .text(r),
                        .text(c),
                        .number(cell.value, style: S.currency),
                        cell.baseline.map { .number($0, style: S.currency) } ?? .empty,
                        .text(cell.overBudget ? "true" : "false")
                    ]
                }
                return (
                    ["Row", "Column", "Actual", "Budget", "Over budget"],
                    data,
                    "Budget heatmap"
                )

            case .netWorth(let n):
                let iso = ISO8601DateFormatter()
                let data = n.snapshots.map { p -> [Cell] in
                    [
                        .text(iso.string(from: p.date)),
                        .number(p.assets, style: S.currency),
                        .number(p.liabilities, style: S.currency),
                        .number(p.netWorth, style: S.currency)
                    ]
                }
                return (["Date", "Assets", "Liabilities", "Net worth"], data, "Snapshots")

            case .subscriptionRoster(let s):
                let iso = ISO8601DateFormatter()
                let data = s.rows.map { row -> [Cell] in
                    [
                        .text(row.serviceName),
                        .text(row.categoryName),
                        .text(row.statusLabel),
                        .number(row.monthlyCost, style: S.currency),
                        .number(row.annualCost, style: S.currency),
                        row.nextPaymentDate.map { .text(iso.string(from: $0)) } ?? .empty,
                        row.firstChargeDate.map { .text(iso.string(from: $0)) } ?? .empty,
                        .text(row.isTrial ? "true" : "false")
                    ]
                }
                return (
                    ["Service", "Category", "Status", "Monthly", "Annual", "Next payment", "First charge", "Trial"],
                    data,
                    "Subscriptions"
                )

            case .recurringRoster(let r):
                let iso = ISO8601DateFormatter()
                let all = r.expenseRows + r.incomeRows
                let data = all.map { row -> [Cell] in
                    [
                        .text(row.name),
                        .text(row.isIncome ? "Income" : "Expense"),
                        .text(row.frequencyLabel),
                        .number(row.amount, style: S.currency),
                        .number(row.normalizedMonthly, style: S.currency),
                        .text(iso.string(from: row.nextOccurrence)),
                        .text(row.isActive ? "true" : "false")
                    ]
                }
                return (
                    ["Name", "Kind", "Frequency", "Amount", "Monthly", "Next occurrence", "Active"],
                    data,
                    "Recurring"
                )

            case .goalsProgress(let g):
                let iso = ISO8601DateFormatter()
                let data = g.rows.map { row -> [Cell] in
                    [
                        .text(row.name),
                        .number(row.currentAmount, style: S.currency),
                        .number(row.targetAmount, style: S.currency),
                        .number(Decimal(row.percentComplete), style: S.percent),
                        row.monthlyContribution.map { .number($0, style: S.currency) } ?? .empty,
                        row.projectedCompletion.map { .text(iso.string(from: $0)) } ?? .empty,
                        .number(row.contributionsInRange, style: S.currency)
                    ]
                }
                return (
                    ["Goal", "Current", "Target", "Progress", "Monthly", "Projected completion", "Contributions in range"],
                    data,
                    "Goals"
                )

            case .empty:
                return (["Message"], [[.text("No data")]], "Empty")
            }
        }()

        var fullRows: [[Cell]] = []
        fullRows.append(headers.map { .text($0, style: S.header) })
        fullRows.append(contentsOf: rows)

        return (renderSheet(name: name, rows: fullRows), name)
    }

    // MARK: - Period row

    private func mkPeriodRow(_ b: PeriodSeries.Bucket, series: String) -> [Cell] {
        let iso = ISO8601DateFormatter()
        return [
            .text(b.label),
            .text(iso.string(from: b.start)),
            .text(iso.string(from: b.end)),
            .number(b.income, style: S.currency),
            .number(b.expense, style: S.currency),
            .number(b.net, style: S.currency),
            .number(Decimal(b.transactionCount)),
            .text(series)
        ]
    }

    // MARK: - Cell model

    private enum Cell {
        case text(String, style: Int = 0)
        case number(Decimal, style: Int = 0)
        case empty
    }

    private func cell(for value: Decimal, format: ReportKPI.ValueFormat) -> Cell {
        switch format {
        case .currency: return .number(value, style: S.currency)
        case .percent:  return .number(value / 100, style: S.percent)
        case .integer:  return .number(value)
        }
    }

    // MARK: - XML rendering

    private func renderSheet(name: String, rows: [[Cell]]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>
        """
        for (rIdx, row) in rows.enumerated() {
            let rowNum = rIdx + 1
            xml += "<row r=\"\(rowNum)\">"
            for (cIdx, cell) in row.enumerated() {
                guard let rendered = renderCell(cell, row: rowNum, col: cIdx) else { continue }
                xml += rendered
            }
            xml += "</row>"
        }
        xml += """
        </sheetData>
        </worksheet>
        """
        _ = name  // sheet name is declared in workbook.xml
        return xml
    }

    private func renderCell(_ cell: Cell, row: Int, col: Int) -> String? {
        let ref = cellRef(row: row, col: col)
        switch cell {
        case .empty:
            return nil
        case .text(let s, let style):
            let escaped = escapeXML(s)
            let styleAttr = style > 0 ? " s=\"\(style)\"" : ""
            return "<c r=\"\(ref)\"\(styleAttr) t=\"inlineStr\"><is><t>\(escaped)</t></is></c>"
        case .number(let d, let style):
            let styleAttr = style > 0 ? " s=\"\(style)\"" : ""
            let str = NSDecimalNumber(decimal: d).stringValue
            return "<c r=\"\(ref)\"\(styleAttr)><v>\(str)</v></c>"
        }
    }

    private func cellRef(row: Int, col: Int) -> String {
        // Excel columns: A, B, … Z, AA, AB, …
        var n = col
        var letters = ""
        repeat {
            let rem = n % 26
            letters = String(UnicodeScalar(rem + 65)!) + letters
            n = n / 26 - 1
        } while n >= 0
        return "\(letters)\(row)"
    }

    private func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Static XML parts

    private let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    </Types>
    """

    private let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private func workbookXML(dataSheetName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
        <sheet name="Summary" sheetId="1" r:id="rId1"/>
        <sheet name="\(escapeXML(dataSheetName))" sheetId="2" r:id="rId2"/>
        </sheets>
        </workbook>
        """
    }

    private let workbookRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    private let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <numFmts count="3">
    <numFmt numFmtId="164" formatCode="&quot;$&quot;#,##0.00"/>
    <numFmt numFmtId="165" formatCode="0.00%"/>
    <numFmt numFmtId="166" formatCode="yyyy-mm-dd"/>
    </numFmts>
    <fonts count="3">
    <font><sz val="11"/><name val="Calibri"/></font>
    <font><sz val="11"/><name val="Calibri"/><b/></font>
    <font><sz val="11"/><name val="Calibri"/><b/><color rgb="FFFFFFFF"/></font>
    </fonts>
    <fills count="3">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF1F2937"/></patternFill></fill>
    </fills>
    <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
    <cellXfs count="6">
    <xf numFmtId="0"   fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
    <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
    <xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
    <xf numFmtId="0"   fontId="2" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
    <xf numFmtId="0"   fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    </cellXfs>
    </styleSheet>
    """
}
