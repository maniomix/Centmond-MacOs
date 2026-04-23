import Foundation

// Builds a single-sheet .xlsx for a CompositeReport. Each enabled section
// appears as a labeled block (bold section header row → headers →
// data rows → blank line). Reuses the same styles.xml + zip plumbing
// pattern as the per-report XLSXExporter so Windows Excel opens it
// without a squawk. Upgrading to one-sheet-per-section is a later pass.

enum CompositeXLSXBuilder {

    private enum S {
        static let general  = 0
        static let currency = 1
        static let percent  = 2
        static let date     = 3
        static let header   = 4
        static let bold     = 5
    }

    private enum Cell {
        case text(String, style: Int = 0)
        case number(Decimal, style: Int = 0)
        case empty
    }

    static func build(composite c: CompositeReport) throws -> Data {
        var rows: [[Cell]] = []

        // Friendly cover block — human dates, no ISO-8601 Z-timestamps.
        rows.append([.text("Centmond Report", style: S.bold)])
        rows.append([.text("Date range", style: S.bold), .text("\(prettyDate(c.resolvedStart)) – \(prettyDate(c.resolvedEnd))")])
        rows.append([.text("Sections", style: S.bold),   .text(c.sections.map(\.title).joined(separator: ", "))])
        rows.append([.text("Transactions", style: S.bold), .number(Decimal(c.transactionCount))])
        rows.append([.text("Currency", style: S.bold),   .text(c.currencyCode)])
        rows.append([.text("Generated", style: S.bold),  .text(prettyDateTime(c.generatedAt))])
        rows.append([])

        for section in c.sections {
            guard let result = c.results[section] else { continue }
            rows.append([.text(section.title.uppercased(), style: S.header)])

            // KPI strip
            rows.append([.text("KPI", style: S.bold), .text("Value", style: S.bold)])
            for kpi in result.summary.kpis {
                rows.append([.text(kpi.label), kpiCell(kpi)])
            }
            rows.append([])

            // Body rows
            let (headers, data) = bodyRows(for: result.body)
            if !headers.isEmpty {
                rows.append(headers.map { .text($0, style: S.bold) })
                rows.append(contentsOf: data)
            }
            rows.append([])
            rows.append([])
        }

        let sheetXML = renderSheet(rows: rows)

        let parts: [SimpleZipWriter.Entry] = [
            .init(path: "[Content_Types].xml", data: contentTypes.data(using: .utf8)!),
            .init(path: "_rels/.rels",          data: rootRels.data(using: .utf8)!),
            .init(path: "xl/workbook.xml",      data: workbookXML.data(using: .utf8)!),
            .init(path: "xl/_rels/workbook.xml.rels", data: workbookRels.data(using: .utf8)!),
            .init(path: "xl/styles.xml",        data: stylesXML.data(using: .utf8)!),
            .init(path: "xl/worksheets/sheet1.xml", data: sheetXML.data(using: .utf8)!)
        ]

        return SimpleZipWriter.make(parts)
    }

    // MARK: - Body expansion

    private static func bodyRows(for body: ReportBody) -> (headers: [String], rows: [[Cell]]) {
        switch body {
        case .periodSeries(let s):
            let data = s.buckets.map { b -> [Cell] in
                [
                    .text(b.label),
                    .text(prettyDate(b.start)),
                    .number(b.income, style: S.currency),
                    .number(b.expense, style: S.currency),
                    .number(b.net, style: S.currency),
                    .number(Decimal(b.transactionCount))
                ]
            }
            return (["Period", "Start", "Income", "Expenses", "Net", "Transactions"], data)

        case .categoryBreakdown(let c):
            var data = c.slices.map { slice -> [Cell] in
                [
                    .text(slice.name),
                    .number(slice.amount, style: S.currency),
                    .number(Decimal(slice.transactionCount)),
                    .number(Decimal(slice.percentOfTotal), style: S.percent)
                ]
            }
            if c.uncategorizedAmount > 0 {
                data.append([.text("Uncategorized"), .number(c.uncategorizedAmount, style: S.currency), .empty, .empty])
            }
            return (["Category", "Amount", "Transactions", "% of total"], data)

        case .merchantLeaderboard(let m):
            let data = m.rows.enumerated().map { idx, row -> [Cell] in
                [
                    .number(Decimal(idx + 1)),
                    .text(row.displayName),
                    .number(row.amount, style: S.currency),
                    .number(Decimal(row.transactionCount)),
                    .number(row.averageAmount, style: S.currency),
                    .number(Decimal(row.percentOfTotal), style: S.percent)
                ]
            }
            return (["Rank", "Merchant", "Amount", "Tx", "Average", "% of total"], data)

        case .heatmap(let h):
            let data = h.cells.map { cell -> [Cell] in
                let r = cell.row < h.rowLabels.count ? h.rowLabels[cell.row] : ""
                let co = cell.column < h.columnLabels.count ? h.columnLabels[cell.column] : ""
                return [
                    .text(r),
                    .text(co),
                    .number(cell.value, style: S.currency),
                    cell.baseline.map { .number($0, style: S.currency) } ?? .empty,
                    .text(cell.overBudget ? "over" : "ok")
                ]
            }
            return (["Category", "Month", "Actual", "Budget", "Status"], data)

        case .netWorth(let n):
            let data = n.snapshots.map { p -> [Cell] in
                [
                    .text(prettyDate(p.date)),
                    .number(p.assets, style: S.currency),
                    .number(p.liabilities, style: S.currency),
                    .number(p.netWorth, style: S.currency)
                ]
            }
            return (["Date", "Assets", "Liabilities", "Net worth"], data)

        case .subscriptionRoster(let r):
            let data = r.rows.map { row -> [Cell] in
                [
                    .text(row.serviceName),
                    .text(row.categoryName),
                    .text(row.statusLabel),
                    .number(row.monthlyCost, style: S.currency),
                    .number(row.annualCost, style: S.currency),
                    row.nextPaymentDate.map { .text(prettyDate($0)) } ?? .empty
                ]
            }
            return (["Service", "Category", "Status", "Monthly", "Annual", "Next payment"], data)

        case .recurringRoster(let r):
            let all = r.expenseRows + r.incomeRows
            let data = all.map { row -> [Cell] in
                [
                    .text(row.name),
                    .text(row.isIncome ? "Income" : "Expense"),
                    .text(row.frequencyLabel),
                    .number(row.amount, style: S.currency),
                    .number(row.normalizedMonthly, style: S.currency),
                    .text(prettyDate(row.nextOccurrence))
                ]
            }
            return (["Name", "Kind", "Frequency", "Amount", "Monthly equivalent", "Next occurrence"], data)

        case .goalsProgress(let g):
            let data = g.rows.map { row -> [Cell] in
                [
                    .text(row.name),
                    .number(row.currentAmount, style: S.currency),
                    .number(row.targetAmount, style: S.currency),
                    .number(Decimal(row.percentComplete), style: S.percent),
                    row.monthlyContribution.map { .number($0, style: S.currency) } ?? .empty,
                    row.projectedCompletion.map { .text(prettyDate($0)) } ?? .empty
                ]
            }
            return (["Goal", "Current", "Target", "Progress", "Monthly contribution", "Projected completion"], data)

        case .empty:
            return (["Message"], [[.text("No data in range")]])
        }
    }

    private static func kpiCell(_ kpi: ReportKPI) -> Cell {
        switch kpi.valueFormat {
        case .currency: return .number(kpi.value, style: S.currency)
        case .percent:  return .number(kpi.value / 100, style: S.percent)
        case .integer:  return .number(kpi.value)
        }
    }

    // MARK: - XML rendering

    private static func renderSheet(rows: [[Cell]]) -> String {
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
        xml += "</sheetData></worksheet>"
        return xml
    }

    private static func renderCell(_ cell: Cell, row: Int, col: Int) -> String? {
        let ref = cellRef(row: row, col: col)
        switch cell {
        case .empty:
            return nil
        case .text(let s, let style):
            let styleAttr = style > 0 ? " s=\"\(style)\"" : ""
            return "<c r=\"\(ref)\"\(styleAttr) t=\"inlineStr\"><is><t>\(escapeXML(s))</t></is></c>"
        case .number(let d, let style):
            let styleAttr = style > 0 ? " s=\"\(style)\"" : ""
            return "<c r=\"\(ref)\"\(styleAttr)><v>\(NSDecimalNumber(decimal: d).stringValue)</v></c>"
        }
    }

    private static func cellRef(row: Int, col: Int) -> String {
        var n = col
        var letters = ""
        repeat {
            let rem = n % 26
            letters = String(UnicodeScalar(rem + 65)!) + letters
            n = n / 26 - 1
        } while n >= 0
        return "\(letters)\(row)"
    }

    private static func prettyDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private static func prettyDateTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Static XML parts

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    </Types>
    """

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static let workbookXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <sheets>
    <sheet name="Report" sheetId="1" r:id="rId1"/>
    </sheets>
    </workbook>
    """

    private static let workbookRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    private static let stylesXML = """
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
