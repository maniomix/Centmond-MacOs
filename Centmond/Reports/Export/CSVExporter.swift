import Foundation

// Human-readable CSV per body type. Opens cleanly in Numbers, Excel,
// and Google Sheets without the "raw database dump" feeling the older
// version had. Design goals (2026-04-23 user feedback — "excel and csv
// export are not understable they has to be user firendly and bueatiful
// and clean."):
//   - No internal UUIDs / sliceIDs / payeeKeys in user-facing columns.
//   - Dates as `yyyy-MM-dd`, not ISO-8601 Z-timestamps.
//   - Money rounded to 2 decimals, written with a leading currency
//     symbol ("$75,596.81") so the file is readable as-is.
//   - Percentages as `21.6%`, not `0.2164`.
//   - Meta header shows only stuff a human cares about (title, range,
//     transactions, currency, generated) — no `kind` / `groupBy` /
//     `comparison` technical fields.
//   - UTF-8 BOM + RFC 4180 quoting preserved for Excel-on-Windows compat.

struct CSVExporter: ReportExporter {
    let format: ReportExportFormat = .csv

    func data(for result: ReportResult) throws -> Data {
        var out = ""
        out += metaHeader(result)
        out += "\r\n\r\n"
        out += bodyRows(result)

        guard let utf8 = out.data(using: .utf8) else {
            return Data()
        }
        return bom + utf8
    }

    // MARK: - Meta header

    private func metaHeader(_ r: ReportResult) -> String {
        var lines: [[String]] = [
            ["Report",        r.summary.title],
            ["Date range",    "\(prettyDate(r.summary.rangeStart)) – \(prettyDate(r.summary.rangeEnd))"],
            ["Transactions",  formatInt(r.summary.transactionCount)],
            ["Currency",      r.summary.currencyCode],
            ["Generated",     prettyDateTime(r.generatedAt)]
        ]
        if !r.summary.kpis.isEmpty {
            lines.append(["", ""])
            lines.append(["Highlight", "Value"])
            for k in r.summary.kpis {
                lines.append([k.label, formatKPI(k, currency: r.summary.currencyCode)])
            }
        }
        return lines.map(encodeRow).joined(separator: "\r\n")
    }

    private func formatKPI(_ kpi: ReportKPI, currency: String) -> String {
        switch kpi.valueFormat {
        case .currency: return money(kpi.value, currency: currency)
        case .percent:  return percent(Double(truncating: kpi.value as NSDecimalNumber) / 100)
        case .integer:  return formatInt(Int(truncating: kpi.value as NSDecimalNumber))
        }
    }

    // MARK: - Body

    private func bodyRows(_ r: ReportResult) -> String {
        switch r.body {
        case .periodSeries(let s):        return periodSeriesCSV(s, currency: r.summary.currencyCode)
        case .categoryBreakdown(let c):   return categoryCSV(c, currency: r.summary.currencyCode)
        case .merchantLeaderboard(let m): return merchantCSV(m, currency: r.summary.currencyCode)
        case .heatmap(let h):             return heatmapCSV(h, currency: r.summary.currencyCode)
        case .netWorth(let n):            return netWorthCSV(n, currency: r.summary.currencyCode)
        case .subscriptionRoster(let s):  return subsCSV(s, currency: r.summary.currencyCode)
        case .recurringRoster(let r2):    return recurringCSV(r2, currency: r.summary.currencyCode)
        case .goalsProgress(let g):       return goalsCSV(g, currency: r.summary.currencyCode)
        case .empty:                      return "No data in range."
        }
    }

    private func periodSeriesCSV(_ s: PeriodSeries, currency: String) -> String {
        var rows: [[String]] = [
            ["Series", "Period", "Start", "End", "Income", "Expenses", "Net", "Transactions"]
        ]
        for b in s.buckets {
            rows.append([
                "Actual", b.label, prettyDate(b.start), prettyDate(b.end),
                money(b.income, currency: currency), money(b.expense, currency: currency),
                money(b.net, currency: currency), formatInt(b.transactionCount)
            ])
        }
        if let baseline = s.baselineBuckets {
            for b in baseline {
                rows.append([
                    "Baseline", b.label, prettyDate(b.start), prettyDate(b.end),
                    money(b.income, currency: currency), money(b.expense, currency: currency),
                    money(b.net, currency: currency), formatInt(b.transactionCount)
                ])
            }
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func categoryCSV(_ c: CategoryBreakdown, currency: String) -> String {
        var rows: [[String]] = [
            ["Category", "Amount", "Transactions", "% of total", "vs baseline"]
        ]
        for s in c.slices {
            rows.append([
                s.name,
                money(s.amount, currency: currency),
                formatInt(s.transactionCount),
                percent(s.percentOfTotal),
                s.deltaVsBaseline.map { money($0, currency: currency) } ?? "—"
            ])
        }
        if c.uncategorizedAmount > 0 {
            rows.append([
                "Uncategorized",
                money(c.uncategorizedAmount, currency: currency),
                "—", "—", "—"
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func merchantCSV(_ m: MerchantLeaderboard, currency: String) -> String {
        var rows: [[String]] = [
            ["Rank", "Merchant", "Amount", "Transactions", "Average", "% of total", "First seen", "Last seen"]
        ]
        for (idx, row) in m.rows.enumerated() {
            rows.append([
                formatInt(idx + 1),
                row.displayName,
                money(row.amount, currency: currency),
                formatInt(row.transactionCount),
                money(row.averageAmount, currency: currency),
                percent(row.percentOfTotal),
                prettyDate(row.firstSeen),
                prettyDate(row.lastSeen)
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func heatmapCSV(_ h: Heatmap, currency: String) -> String {
        var rows: [[String]] = [
            ["Category", "Month", "Actual", "Budget", "Status"]
        ]
        for cell in h.cells {
            let r = cell.row < h.rowLabels.count ? h.rowLabels[cell.row] : ""
            let c = cell.column < h.columnLabels.count ? h.columnLabels[cell.column] : ""
            rows.append([
                r, c,
                money(cell.value, currency: currency),
                cell.baseline.map { money($0, currency: currency) } ?? "—",
                cell.overBudget ? "Over budget" : "On track"
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func netWorthCSV(_ n: NetWorthBody, currency: String) -> String {
        var rows: [[String]] = [
            ["Date", "Assets", "Liabilities", "Net worth"]
        ]
        for p in n.snapshots {
            rows.append([
                prettyDate(p.date),
                money(p.assets, currency: currency),
                money(p.liabilities, currency: currency),
                money(p.netWorth, currency: currency)
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func subsCSV(_ s: SubscriptionRoster, currency: String) -> String {
        var rows: [[String]] = [
            ["Service", "Category", "Status", "Monthly", "Annual", "Next payment", "First charge", "Trial?"]
        ]
        for row in s.rows {
            rows.append([
                row.serviceName,
                row.categoryName,
                row.statusLabel,
                money(row.monthlyCost, currency: currency),
                money(row.annualCost, currency: currency),
                row.nextPaymentDate.map(prettyDate) ?? "—",
                row.firstChargeDate.map(prettyDate) ?? "—",
                row.isTrial ? "Yes" : "No"
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func recurringCSV(_ r: RecurringRoster, currency: String) -> String {
        var rows: [[String]] = [
            ["Name", "Kind", "Amount", "Frequency", "Monthly equivalent", "Next occurrence", "Active?"]
        ]
        for row in r.expenseRows + r.incomeRows {
            rows.append([
                row.name,
                row.isIncome ? "Income" : "Expense",
                money(row.amount, currency: currency),
                row.frequencyLabel,
                money(row.normalizedMonthly, currency: currency),
                prettyDate(row.nextOccurrence),
                row.isActive ? "Yes" : "No"
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func goalsCSV(_ g: GoalsProgressBody, currency: String) -> String {
        var rows: [[String]] = [
            ["Goal", "Current", "Target", "Progress", "Monthly contribution", "Projected completion", "Contributions in range"]
        ]
        for row in g.rows {
            rows.append([
                row.name,
                money(row.currentAmount, currency: currency),
                money(row.targetAmount, currency: currency),
                percent(row.percentComplete),
                row.monthlyContribution.map { money($0, currency: currency) } ?? "—",
                row.projectedCompletion.map(prettyDate) ?? "—",
                money(row.contributionsInRange, currency: currency)
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    // MARK: - CSV primitives

    private let bom = Data([0xEF, 0xBB, 0xBF])

    private func encodeRow(_ fields: [String]) -> String {
        fields.map(encodeField).joined(separator: ",")
    }

    private func encodeField(_ raw: String) -> String {
        let needsQuoting = raw.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        if needsQuoting {
            let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return raw
    }

    // MARK: - Friendly formatters

    private static let currencyFormatters: [String: NumberFormatter] = [:]

    private func money(_ d: Decimal, currency: String) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = currency
        fmt.maximumFractionDigits = 2
        fmt.minimumFractionDigits = 2
        fmt.usesGroupingSeparator = true
        return fmt.string(from: NSDecimalNumber(decimal: d)) ?? "0"
    }

    private func percent(_ p: Double) -> String {
        // Input is 0…1 range.
        let clean = (p * 1000).rounded() / 10  // one decimal place, e.g. 21.6
        if clean == clean.rounded() {
            return "\(Int(clean))%"
        }
        return String(format: "%.1f%%", clean)
    }

    private func formatInt(_ n: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.usesGroupingSeparator = true
        fmt.maximumFractionDigits = 0
        return fmt.string(from: NSNumber(value: n)) ?? String(n)
    }

    private func prettyDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private func prettyDateTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }
}
