import Foundation

// Tidy-long-form CSV per body type. UTF-8 BOM for Excel-on-Windows
// compatibility, RFC 4180 quoting, ISO-8601 dates. Amounts written
// as raw decimals; a separate `currency` column carries the ISO code
// so pivots work without stripping glyphs.

struct CSVExporter: ReportExporter {
    let format: ReportExportFormat = .csv

    func data(for result: ReportResult) throws -> Data {
        var out = ""
        out += metaHeader(result)
        out += "\n"
        out += bodyRows(result)

        guard let utf8 = out.data(using: .utf8) else {
            return Data()
        }
        return bom + utf8
    }

    // MARK: - Meta header

    private func metaHeader(_ r: ReportResult) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [[String]] = [
            ["field", "value"],
            ["report",      r.summary.title],
            ["kind",        r.definition.kind.rawValue],
            ["rangeStart",  iso.string(from: r.summary.rangeStart)],
            ["rangeEnd",    iso.string(from: r.summary.rangeEnd)],
            ["groupBy",     r.definition.groupBy.rawValue],
            ["comparison",  r.definition.comparison.rawValue],
            ["generatedAt", iso.string(from: r.generatedAt)],
            ["txCount",     String(r.summary.transactionCount)],
            ["currency",    r.summary.currencyCode]
        ]
        lines.append(["", ""])
        lines.append(["kpi", "value"])
        for k in r.summary.kpis {
            lines.append([k.label, NSDecimalNumber(decimal: k.value).stringValue])
        }
        return lines.map(encodeRow).joined(separator: "\r\n")
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
        case .empty:                      return ""
        }
    }

    private func periodSeriesCSV(_ s: PeriodSeries, currency: String) -> String {
        let iso = ISO8601DateFormatter()
        var rows: [[String]] = [
            ["series", "bucketID", "label", "start", "end", "income", "expense", "net", "transactions", "currency"]
        ]
        for b in s.buckets {
            rows.append([
                "actual", b.id, b.label, iso.string(from: b.start), iso.string(from: b.end),
                num(b.income), num(b.expense), num(b.net), String(b.transactionCount), currency
            ])
        }
        if let baseline = s.baselineBuckets {
            for b in baseline {
                rows.append([
                    "baseline", b.id, b.label, iso.string(from: b.start), iso.string(from: b.end),
                    num(b.income), num(b.expense), num(b.net), String(b.transactionCount), currency
                ])
            }
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func categoryCSV(_ c: CategoryBreakdown, currency: String) -> String {
        var rows: [[String]] = [
            ["sliceID", "name", "amount", "transactions", "percentOfTotal", "deltaVsBaseline", "currency"]
        ]
        for s in c.slices {
            rows.append([
                s.id, s.name, num(s.amount), String(s.transactionCount),
                pct(s.percentOfTotal), s.deltaVsBaseline.map(num) ?? "",
                currency
            ])
        }
        if c.uncategorizedAmount > 0 {
            rows.append(["", "Uncategorized", num(c.uncategorizedAmount), "", "", "", currency])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func merchantCSV(_ m: MerchantLeaderboard, currency: String) -> String {
        let iso = ISO8601DateFormatter()
        var rows: [[String]] = [
            ["rank", "payeeKey", "displayName", "amount", "transactions", "averageAmount", "percentOfTotal", "firstSeen", "lastSeen", "currency"]
        ]
        for (idx, row) in m.rows.enumerated() {
            rows.append([
                String(idx + 1), row.id, row.displayName,
                num(row.amount), String(row.transactionCount), num(row.averageAmount),
                pct(row.percentOfTotal),
                iso.string(from: row.firstSeen), iso.string(from: row.lastSeen),
                currency
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func heatmapCSV(_ h: Heatmap, currency: String) -> String {
        var rows: [[String]] = [
            ["row", "rowLabel", "column", "columnLabel", "value", "budget", "overBudget", "currency"]
        ]
        for cell in h.cells {
            let r = cell.row < h.rowLabels.count ? h.rowLabels[cell.row] : ""
            let c = cell.column < h.columnLabels.count ? h.columnLabels[cell.column] : ""
            rows.append([
                String(cell.row), r, String(cell.column), c,
                num(cell.value), cell.baseline.map(num) ?? "",
                cell.overBudget ? "true" : "false",
                currency
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func netWorthCSV(_ n: NetWorthBody, currency: String) -> String {
        let iso = ISO8601DateFormatter()
        var rows: [[String]] = [
            ["date", "assets", "liabilities", "netWorth", "currency"]
        ]
        for p in n.snapshots {
            rows.append([
                iso.string(from: p.date),
                num(p.assets), num(p.liabilities), num(p.netWorth),
                currency
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func subsCSV(_ s: SubscriptionRoster, currency: String) -> String {
        let iso = ISO8601DateFormatter()
        var rows: [[String]] = [
            ["id", "serviceName", "category", "status", "monthlyCost", "annualCost", "nextPayment", "firstCharge", "isTrial", "currency"]
        ]
        for row in s.rows {
            rows.append([
                row.id, row.serviceName, row.categoryName, row.statusLabel,
                num(row.monthlyCost), num(row.annualCost),
                row.nextPaymentDate.map(iso.string(from:)) ?? "",
                row.firstChargeDate.map(iso.string(from:)) ?? "",
                row.isTrial ? "true" : "false",
                currency
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func recurringCSV(_ r: RecurringRoster, currency: String) -> String {
        let iso = ISO8601DateFormatter()
        var rows: [[String]] = [
            ["id", "name", "kind", "amount", "frequency", "normalizedMonthly", "nextOccurrence", "active", "currency"]
        ]
        for row in r.expenseRows + r.incomeRows {
            rows.append([
                row.id, row.name, row.isIncome ? "income" : "expense",
                num(row.amount), row.frequencyLabel, num(row.normalizedMonthly),
                iso.string(from: row.nextOccurrence),
                row.isActive ? "true" : "false",
                currency
            ])
        }
        return rows.map(encodeRow).joined(separator: "\r\n")
    }

    private func goalsCSV(_ g: GoalsProgressBody, currency: String) -> String {
        let iso = ISO8601DateFormatter()
        var rows: [[String]] = [
            ["id", "name", "current", "target", "percentComplete", "monthlyContribution", "projectedCompletion", "contributionsInRange", "currency"]
        ]
        for row in g.rows {
            rows.append([
                row.id, row.name,
                num(row.currentAmount), num(row.targetAmount),
                pct(row.percentComplete),
                row.monthlyContribution.map(num) ?? "",
                row.projectedCompletion.map(iso.string(from:)) ?? "",
                num(row.contributionsInRange),
                currency
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

    private func num(_ d: Decimal) -> String {
        NSDecimalNumber(decimal: d).stringValue
    }

    private func pct(_ p: Double) -> String {
        String(format: "%.4f", p)
    }
}
