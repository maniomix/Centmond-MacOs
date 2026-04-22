import Foundation

// Takes a ReportResult, serializes the headline numbers + top rows
// into a compact brief, asks the on-device model for a 3-bullet
// narrative. Kept off ReportEngine so the engine stays pure/offline.

@MainActor
enum ReportSummarizer {

    static func summarize(_ result: ReportResult) async throws -> String {
        let manager = AIManager.shared

        if manager.status != .ready {
            manager.loadModel()
        }

        let brief = buildBrief(result)
        let prompt = """
        Summarize this report as exactly 3 short bullet points (max 20 words each).
        Focus on: what happened, why it matters, one thing to consider.
        Use plain prose — no emoji, no markdown fences.

        Report brief:
        \(brief)
        """

        let system = """
        You are a financial analyst writing a short narrative for a report cover.
        Be concrete. Cite the numbers in the brief. No speculation beyond the data.
        Output ONLY the 3 bullet points, each prefixed with "- ". Nothing else.
        """

        let reply = await manager.generate(prompt, systemPrompt: system)
        let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw NSError(domain: "ReportSummarizer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "The model returned an empty summary."
            ])
        }
        return cleaned
    }

    // MARK: - Brief

    static func buildBrief(_ r: ReportResult) -> String {
        var lines: [String] = []

        lines.append("Title: \(r.summary.title)")
        lines.append("Range: \(PrettyDate.date(r.summary.rangeStart)) to \(PrettyDate.date(r.summary.rangeEnd))")
        lines.append("Transactions: \(r.summary.transactionCount)")
        if r.definition.comparison != .none {
            lines.append("Comparison: \(r.definition.comparison.label)")
        }

        lines.append("")
        lines.append("Headline KPIs:")
        for kpi in r.summary.kpis {
            var line = "- \(kpi.label): \(format(kpi.value, as: kpi.valueFormat))"
            if let d = kpi.deltaVsBaseline {
                line += " (Δ \(format(d, as: kpi.valueFormat)))"
            }
            lines.append(line)
        }

        lines.append("")
        lines.append(bodyBrief(r.body))

        return lines.joined(separator: "\n")
    }

    private static func bodyBrief(_ body: ReportBody) -> String {
        switch body {
        case .periodSeries(let s):
            let rows = s.buckets.map {
                "\($0.label): income \(fmtCur($0.income)), expense \(fmtCur($0.expense)), net \(fmtCur($0.net))"
            }.joined(separator: "\n")
            var out = "By period:\n\(rows)\nTotals: income \(fmtCur(s.totals.income)), expense \(fmtCur(s.totals.expense)), net \(fmtCur(s.totals.net))"
            if let sr = s.totals.savingsRate {
                out += ", savings rate \(Int(sr * 100))%"
            }
            return out

        case .categoryBreakdown(let c):
            let top = c.slices.prefix(8).map {
                let delta = $0.deltaVsBaseline.map { " (Δ \(fmtCur($0)))" } ?? ""
                return "\($0.name): \(fmtCur($0.amount)), \(Int(($0.percentOfTotal * 100).rounded()))%\(delta)"
            }.joined(separator: "\n")
            return "Top categories (of \(fmtCur(c.totalAmount))):\n\(top)"

        case .merchantLeaderboard(let m):
            let top = m.rows.prefix(8).enumerated().map { idx, r in
                "#\(idx + 1) \(r.displayName): \(fmtCur(r.amount)) over \(r.transactionCount) tx, avg \(fmtCur(r.averageAmount))"
            }.joined(separator: "\n")
            return "Top merchants (of \(fmtCur(m.totalAmount))):\n\(top)"

        case .heatmap(let h):
            let over = h.cells.filter(\.overBudget).count
            let totalSpend = h.cells.reduce(Decimal.zero) { $0 + $1.value }
            let totalBudget = h.cells.reduce(Decimal.zero) { $0 + ($1.baseline ?? 0) }
            return "Budget grid: \(h.rowLabels.count) categories × \(h.columnLabels.count) months. Total spend \(fmtCur(totalSpend)) vs budget \(fmtCur(totalBudget)). Over budget in \(over) cells."

        case .netWorth(let n):
            let delta = n.endingNetWorth - n.startingNetWorth
            return "Net worth: start \(fmtCur(n.startingNetWorth)), end \(fmtCur(n.endingNetWorth)), delta \(fmtCur(delta)). Assets \(fmtCur(n.assetsEnd)), liabilities \(fmtCur(n.liabilitiesEnd))."

        case .subscriptionRoster(let s):
            let top = s.rows.prefix(6).map {
                "\($0.serviceName) (\($0.statusLabel)): \(fmtCur($0.monthlyCost))/mo"
            }.joined(separator: "\n")
            return "Subscriptions: \(s.activeCount) active, \(s.pausedCount) paused, \(s.cancelledCount) cancelled. Monthly \(fmtCur(s.totalMonthly)), annual \(fmtCur(s.totalAnnual)).\n\(top)"

        case .recurringRoster(let r):
            return "Recurring: monthly income \(fmtCur(r.totalMonthlyIncome)), monthly expense \(fmtCur(r.totalMonthlyExpense)). \(r.expenseRows.count) expense items, \(r.incomeRows.count) income items."

        case .goalsProgress(let g):
            let top = g.rows.prefix(6).map {
                let pct = Int(($0.percentComplete * 100).rounded())
                return "\($0.name): \(pct)% (\(fmtCur($0.currentAmount)) of \(fmtCur($0.targetAmount)))"
            }.joined(separator: "\n")
            return "Goals progress: total saved \(fmtCur(g.totalCurrent)) of \(fmtCur(g.totalTarget)). Contributions in range: \(fmtCur(g.contributionsInRange)).\n\(top)"

        case .empty:
            return "No data in the selected range."
        }
    }

    // MARK: - Format helpers

    private static func fmtCur(_ d: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSDecimalNumber(decimal: d)) ?? "\(d)"
    }

    private static func format(_ d: Decimal, as f: ReportKPI.ValueFormat) -> String {
        switch f {
        case .currency: return fmtCur(d)
        case .percent:  return "\(Int(truncating: d as NSDecimalNumber))%"
        case .integer:  return "\(Int(truncating: d as NSDecimalNumber))"
        }
    }

    private enum PrettyDate {
        static func date(_ d: Date) -> String {
            d.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}
