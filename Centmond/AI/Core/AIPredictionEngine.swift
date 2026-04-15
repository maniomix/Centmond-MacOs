import Foundation
import SwiftData

// ============================================================
// MARK: - AI Prediction Result (parsed from Gemma 4 output)
// ============================================================

struct AICategoryPrediction {
    let name: String
    let projected: Double
}

/// AI-detected behavioral trigger (time/pattern-based spending spike)
struct AITrigger: Identifiable {
    let id = UUID()
    let pattern: String         // e.g., "Late-night ordering"
    let description: String     // e.g., "3 food delivery orders after 10 PM totaling $47"
    let amount: Double
}

/// AI-detected anomaly (unusual transaction that doesn't fit the profile)
struct AIAnomaly: Identifiable {
    let id = UUID()
    let merchant: String
    let amount: Double
    let description: String     // e.g., "Gaming purchase 3x your usual entertainment spend"
}

/// AI-generated aggressive action to save money
struct AICombatAction: Identifiable {
    let id = UUID()
    let action: String          // e.g., "Cancel Netflix Basic"
    let savings: Double         // Dollar amount saved
    let reason: String          // e.g., "No activity in 3 weeks"
}

struct AIPredictionResult {
    let projectedMonthlySpending: Double
    let savingsRate: Double          // 0-100
    let riskLevel: String            // "low", "medium", "high"
    let weeklyTrend: String          // "accelerating", "decelerating", "stable"
    let categoryPredictions: [AICategoryPrediction]
    let breakEvenDay: Int?           // Day of month when budget runs out (nil if under budget)
    let triggers: [AITrigger]        // Behavioral spending triggers
    let anomalies: [AIAnomaly]       // Budget-killing anomalies
    let combatPlan: [AICombatAction] // Aggressive savings actions

    /// Parse the ---PREDICTIONS--- JSON block from AI output
    static func parse(from rawText: String, fallback data: PredictionData?) -> AIPredictionResult? {
        // Extract JSON between ---PREDICTIONS--- markers
        guard let startRange = rawText.range(of: "---PREDICTIONS---") else { return nil }
        let afterStart = rawText[startRange.upperBound...]
        guard let endRange = afterStart.range(of: "---PREDICTIONS---") else { return nil }
        let jsonStr = String(afterStart[..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        let projected = json["projectedSpending"] as? Double ?? data?.forecast.projectedSpending ?? 0
        let savings = json["savingsRate"] as? Double ?? 0
        let risk = json["riskLevel"] as? String ?? "medium"
        let trend = json["weeklyTrend"] as? String ?? "stable"
        let breakEven = json["breakEvenDay"] as? Int

        var catPredictions: [AICategoryPrediction] = []
        if let cats = json["categories"] as? [[String: Any]] {
            for cat in cats {
                if let name = cat["name"] as? String, let amount = cat["projected"] as? Double {
                    catPredictions.append(AICategoryPrediction(name: name, projected: amount))
                }
            }
        }

        // Parse structured intelligence: triggers
        var triggers: [AITrigger] = []
        if let trigs = json["triggers"] as? [[String: Any]] {
            for t in trigs {
                triggers.append(AITrigger(
                    pattern: t["pattern"] as? String ?? "",
                    description: t["description"] as? String ?? "",
                    amount: t["amount"] as? Double ?? 0
                ))
            }
        }

        // Parse structured intelligence: anomalies
        var anomalies: [AIAnomaly] = []
        if let anoms = json["anomalies"] as? [[String: Any]] {
            for a in anoms {
                anomalies.append(AIAnomaly(
                    merchant: a["merchant"] as? String ?? "",
                    amount: a["amount"] as? Double ?? 0,
                    description: a["description"] as? String ?? ""
                ))
            }
        }

        // Parse structured intelligence: combat plan
        var combatPlan: [AICombatAction] = []
        if let actions = json["combatPlan"] as? [[String: Any]] {
            for a in actions {
                combatPlan.append(AICombatAction(
                    action: a["action"] as? String ?? "",
                    savings: a["savings"] as? Double ?? 0,
                    reason: a["reason"] as? String ?? ""
                ))
            }
        }

        return AIPredictionResult(
            projectedMonthlySpending: projected,
            savingsRate: savings,
            riskLevel: risk,
            weeklyTrend: trend,
            categoryPredictions: catPredictions,
            breakEvenDay: breakEven,
            triggers: triggers,
            anomalies: anomalies,
            combatPlan: combatPlan
        )
    }

    /// Fallback when AI is unavailable — use basic math
    static func fallback(from data: PredictionData) -> AIPredictionResult {
        // Compute break-even day from basic math
        let f = data.forecast
        let breakEven: Int? = {
            guard f.totalBudget > 0, f.dailyAverage > 0, f.projectedSpending > f.totalBudget else { return nil }
            let remaining = f.totalBudget - f.spentSoFar
            guard remaining > 0 else { return f.daysPassed }
            let daysUntilBreak = Int(remaining / f.dailyAverage)
            return min(f.daysPassed + daysUntilBreak, f.daysPassed + f.daysLeft)
        }()

        return AIPredictionResult(
            projectedMonthlySpending: data.forecast.projectedSpending,
            savingsRate: data.savingsRate * 100,
            riskLevel: data.forecast.isOverBudget ? "high" : "low",
            weeklyTrend: data.weeklyComparison.isUp ? "accelerating" : "decelerating",
            categoryPredictions: data.categoryProjections.map {
                AICategoryPrediction(name: $0.name, projected: $0.projected)
            },
            breakEvenDay: breakEven,
            triggers: [],
            anomalies: [],
            combatPlan: []
        )
    }
}

// ============================================================
// MARK: - AI Prediction Engine
// ============================================================
//
// Computes spending predictions, category projections, and
// end-of-month forecasts from SwiftData. Feeds data to
// AIPredictionView and optionally asks the AI model for
// qualitative "key signals" analysis.
//
// ============================================================

// MARK: - Data Models

struct SpendingDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let amount: Double         // cumulative
    let isProjected: Bool
}

/// Per-day spending bar data
struct DailySpendingBar: Identifiable {
    let id = UUID()
    let dayOfMonth: Int
    let date: Date
    let amount: Double         // that day's total spending
    let isProjected: Bool
}

/// Confidence band point for projected range
struct ConfidenceBandPoint: Identifiable {
    let id = UUID()
    let date: Date
    let low: Double
    let high: Double
}

struct CategoryProjection: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let colorHex: String
    let spent: Double
    let budget: Double
    let projected: Double
    let trend: Trend

    enum Trend: String {
        case rising = "arrow.up.right"
        case falling = "arrow.down.right"
        case stable = "arrow.right"
    }

    var projectedRatio: Double {
        guard budget > 0 else { return 0 }
        return min(projected / budget, 2.0)
    }

    var spentRatio: Double {
        guard budget > 0 else { return 0 }
        return min(spent / budget, 2.0)
    }
}

struct MonthForecast {
    let projectedSpending: Double
    let totalBudget: Double
    let incomeReceived: Double
    let expectedIncome: Double
    let spentSoFar: Double
    let daysLeft: Int
    let daysPassed: Int

    var delta: Double { totalBudget - projectedSpending }
    var dailyAverage: Double { daysPassed > 0 ? spentSoFar / Double(daysPassed) : 0 }
    var projectedDaily: Double { daysLeft > 0 ? (projectedSpending - spentSoFar) / Double(daysLeft) : 0 }
    var isOverBudget: Bool { projectedSpending > totalBudget && totalBudget > 0 }

    var statusLabel: String {
        if totalBudget <= 0 { return "No budget set" }
        if delta >= 0 { return "On Track" }
        return "Over Budget"
    }
}

/// Top merchant by spending
struct TopMerchant: Identifiable {
    let id = UUID()
    let name: String
    let amount: Double
    let txCount: Int
}

/// Week-over-week comparison
struct WeeklyComparison {
    let thisWeekSpending: Double
    let lastWeekSpending: Double
    var changePercent: Double {
        guard lastWeekSpending > 0 else { return 0 }
        return ((thisWeekSpending - lastWeekSpending) / lastWeekSpending) * 100
    }
    var isUp: Bool { thisWeekSpending > lastWeekSpending }
}

/// Account health snapshot
struct AccountSnapshot: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let balance: Double
    let creditLimit: Double?     // nil if not credit card
    let utilization: Double?     // 0-1 for credit cards
}

/// Subscription pressure
struct SubscriptionPressure {
    let monthlyTotal: Double
    let annualTotal: Double
    let nextBillName: String
    let nextBillAmount: Double
    let nextBillDate: Date
    let count: Int
}

/// Individual transaction detail for AI context injection
struct RecentTransaction: Identifiable {
    let id = UUID()
    let date: Date
    let payee: String
    let amount: Double
    let categoryName: String
    let isWeekend: Bool
    let hourOfDay: Int
    let dayOfWeek: String            // "Mon", "Tue", etc.
}

/// Pre-computed emotional/behavioral spending analysis
struct EmotionalSpendingProfile {
    let lateNightCount: Int          // Transactions between 10PM–5AM
    let lateNightTotal: Double
    let weekendCount: Int
    let weekendTotal: Double
    let impulseCount: Int            // Small charges < $15 at high-frequency merchants
    let impulseTotal: Double
    let highFrequencyMerchants: [(name: String, count: Int, total: Double)]  // 3+ visits
    let peakSpendingHour: Int        // Hour with highest total spend
    let peakSpendingDay: String      // Day of week with highest total spend
    let avgTransactionSize: Double
    let hourlySpending: [Int: Double] // Hour (0-23) → total spending amount
}

/// Monthly spending for the year overview chart
struct MonthlySpendingData: Identifiable {
    let id = UUID()
    let month: Int              // 1-12
    let year: Int               // calendar year (so multi-year windows render unique budgets per Jan '25 vs Jan '26)
    let monthLabel: String      // "Jan", "Feb", etc.
    let actual: Double          // Actual spending (0 for future months)
    let forecast: Double        // Forecast/projected spending
    let income: Double          // Income received that month (or expected, for future)
    let budget: Double          // Per-month MonthlyTotalBudget (0 if none set for that month)
    let isCurrent: Bool         // Is this the current month?
    let isFuture: Bool          // Is this a future month?
}

struct PredictionData {
    let spendingTrajectory: [SpendingDataPoint]
    let dailyBars: [DailySpendingBar]
    let confidenceBand: [ConfidenceBandPoint]
    let forecast: MonthForecast
    let categoryProjections: [CategoryProjection]
    let topMerchants: [TopMerchant]
    let weeklyComparison: WeeklyComparison
    let accountSnapshots: [AccountSnapshot]
    let subscriptionPressure: SubscriptionPressure?
    let savingsRate: Double           // income > 0 ? (income - spending) / income : 0
    let lastMonthSpending: Double     // for month-over-month comparison
    let topInsights: [String]
    let recentTransactions: [RecentTransaction]  // Last 50 transactions for AI context
    let emotionalProfile: EmotionalSpendingProfile
    let monthlyOverview: [MonthlySpendingData]   // 12-month actual vs forecast
}

// MARK: - Analysis Window

/// User-selectable historical window that widens the dataset the engine
/// feeds to the AI (transactions, emotional profile, monthly overview).
/// The current month is ALWAYS included, even when the window is `.thisMonth`
/// and there is no data for it yet — the forecast/trajectory section always
/// centres on the current month regardless of this value.
enum PredictionTimeRange: String, CaseIterable, Identifiable {
    case thisMonth = "This Month"
    case lastMonth = "Last Month"
    case last3Months = "Last 3 Months"
    case last6Months = "Last 6 Months"
    case lastYear = "Last Year"

    var id: String { rawValue }

    /// How many whole months of history to include BEFORE the current month.
    /// Current month is always included on top of this, so the rendered
    /// window is exactly `monthsBack + 1` calendar months — matching the
    /// short label (1M / 2M / 3M / 6M / 1Y). Previously `last3Months`
    /// returned 3 which produced 4 months on screen (Jan + Feb + Mar + Apr
    /// when today is Apr 15) — user reported "i can see 4 months in 3 month
    /// timeline".
    var monthsBack: Int {
        switch self {
        case .thisMonth:    return 0
        case .lastMonth:    return 1
        case .last3Months:  return 2
        case .last6Months:  return 5
        case .lastYear:     return 11
        }
    }

    /// Short SF-Symbol-free label for compact picker chips.
    var shortLabel: String {
        switch self {
        case .thisMonth:    return "1M"
        case .lastMonth:    return "2M"
        case .last3Months:  return "3M"
        case .last6Months:  return "6M"
        case .lastYear:     return "1Y"
        }
    }
}

// MARK: - Engine

enum AIPredictionEngine {

    static func compute(
        context: ModelContext,
        range: PredictionTimeRange = .thisMonth
    ) -> PredictionData {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let startOfMonth = cal.date(from: comps)!
        // Window math: span from `monthsBack` months ago up to and including
        // the current month. For .thisMonth this collapses to the current
        // calendar month and the original behaviour is preserved.
        let windowStart = cal.date(byAdding: .month, value: -range.monthsBack, to: startOfMonth)!
        let nextMonthStart = cal.date(byAdding: .month, value: 1, to: startOfMonth)!
        let windowEnd = cal.date(byAdding: .day, value: -1, to: nextMonthStart)!
        let totalDays = cal.dateComponents([.day], from: windowStart, to: windowEnd).day! + 1
        let daysPassed = max(1, cal.dateComponents([.day], from: windowStart, to: now).day! + 1)
        let daysLeft = max(0, totalDays - daysPassed)
        // Aliases retained so the rest of compute reads naturally — they are
        // the *window* anchors, not the calendar-month anchors any more.
        let rangeStart = windowStart
        let rangeEnd = nextMonthStart

        let (year, month) = (comps.year!, comps.month!)

        // Fetch all transactions in the window (start..<today+1)
        let fetchUpper = min(rangeEnd, cal.date(byAdding: .day, value: 1, to: now)!)
        let txns = fetchTransactions(context: context, from: windowStart, to: fetchUpper)
        let expenses = txns.filter { !$0.isIncome && BalanceService.isSpendingExpense($0) }
        let income = txns.filter { $0.isIncome }.reduce(0.0) { $0 + nsDecToDouble($1.amount) }

        // Expected income from recurring (from now until window end)
        let expectedIncome = fetchExpectedIncome(context: context, after: now, before: rangeEnd)

        // Total budget — sum of MonthlyTotalBudget across every month in the
        // window. For .thisMonth this is identical to the single-month budget.
        var totalBudget: Double = 0
        do {
            var cursor = windowStart
            while cursor < rangeEnd {
                let y = cal.component(.year, from: cursor)
                let m = cal.component(.month, from: cursor)
                totalBudget += nsDecToDouble(fetchTotalBudget(context: context, year: y, month: m))
                cursor = cal.date(byAdding: .month, value: 1, to: cursor) ?? rangeEnd
            }
        }

        // Build daily totals map indexed by day-offset from window start.
        var dailyTotals: [Int: Double] = [:]
        for tx in expenses {
            let dayIdx = cal.dateComponents([.day], from: windowStart, to: tx.date).day ?? 0
            dailyTotals[dayIdx, default: 0] += nsDecToDouble(tx.amount)
        }

        let spentSoFar = expenses.reduce(0.0) { $0 + nsDecToDouble($1.amount) }
        let dailyAvg = spentSoFar / Double(daysPassed)

        // Standard deviation for confidence band
        let dailyAmounts = (0..<daysPassed).map { dailyTotals[$0] ?? 0 }
        let stdDev = standardDeviation(dailyAmounts)

        // Build trajectory across the window: actual days + projected days.
        // Helper accepts `startOfMonth` arg name but treats it as a generic
        // window anchor (it just adds dayIdx to whatever Date you pass).
        let trajectory = buildTrajectory(
            dailyTotals: dailyTotals,
            startOfMonth: windowStart,
            daysPassed: daysPassed,
            totalDays: totalDays,
            dailyAvg: dailyAvg,
            cal: cal
        )

        // Build daily bars across the window
        let bars = buildDailyBars(
            dailyTotals: dailyTotals,
            startOfMonth: windowStart,
            daysPassed: daysPassed,
            totalDays: totalDays,
            dailyAvg: dailyAvg,
            cal: cal
        )

        // Build confidence band for projected portion (today → window end)
        let band = buildConfidenceBand(
            startOfMonth: windowStart,
            daysPassed: daysPassed,
            totalDays: totalDays,
            cumulativeAtToday: spentSoFar,
            dailyAvg: dailyAvg,
            stdDev: stdDev,
            cal: cal
        )

        let projectedSpending = spentSoFar + (dailyAvg * Double(daysLeft))

        let forecast = MonthForecast(
            projectedSpending: projectedSpending,
            totalBudget: totalBudget,
            incomeReceived: income,
            expectedIncome: expectedIncome,
            spentSoFar: spentSoFar,
            daysLeft: daysLeft,
            daysPassed: daysPassed
        )

        // Category projections — uses window expenses + window day ratio.
        // Budget lookup still pulls current-month per-category targets; for
        // multi-month windows we scale them by the number of months covered
        // so the breach math stays meaningful.
        let monthsInWindow = max(1, range.monthsBack + 1)
        let catProjections = buildCategoryProjections(
            context: context,
            expenses: expenses,
            year: year,
            month: month,
            daysPassed: daysPassed,
            totalDays: totalDays,
            budgetMultiplier: monthsInWindow
        )

        // Top merchants
        let topMerchants = buildTopMerchants(expenses: expenses)

        // Weekly comparison
        let weeklyComparison = buildWeeklyComparison(context: context, now: now, cal: cal)

        // Account snapshots
        let accountSnapshots = buildAccountSnapshots(context: context)

        // Subscription pressure
        let subscriptionPressure = buildSubscriptionPressure(context: context, now: now)

        // Savings rate
        let totalIncome = income + expectedIncome
        let savingsRate = totalIncome > 0 ? (totalIncome - projectedSpending) / totalIncome : 0

        // Last month spending for comparison
        let lastMonthStart = cal.date(byAdding: .month, value: -1, to: startOfMonth)!
        let lastMonthTxns = fetchTransactions(context: context, from: lastMonthStart, to: startOfMonth)
        let lastMonthSpending = lastMonthTxns
            .filter { !$0.isIncome && BalanceService.isSpendingExpense($0) }
            .reduce(0.0) { $0 + nsDecToDouble($1.amount) }

        // Quick rule-based insights (AI signals added separately via streaming)
        let insights = generateInsights(forecast: forecast, categories: catProjections)

        // Recent transactions with full detail for AI context injection.
        // Fetch across the user-selected historical window (rangeStart..<rangeEnd)
        // so the AI sees multi-month patterns when asked for wider analysis.
        // Cap the sample so the prompt stays within the model context window.
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let rangeTxns = fetchTransactions(context: context, from: rangeStart, to: rangeEnd)
        let rangeExpenses = rangeTxns.filter { !$0.isIncome && BalanceService.isSpendingExpense($0) }
        // Sample ceiling scales with the range so wider windows carry more signal
        // without blowing up the prompt — 50 (1M) → 200 (12M).
        let sampleCap: Int = {
            switch range {
            case .thisMonth:    return 50
            case .lastMonth:    return 80
            case .last3Months:  return 120
            case .last6Months:  return 160
            case .lastYear:     return 200
            }
        }()
        let recentTxns: [RecentTransaction] = rangeExpenses
            .sorted(by: { $0.date > $1.date })
            .prefix(sampleCap)
            .map { tx in
                let hour = cal.component(.hour, from: tx.date)
                let weekday = cal.component(.weekday, from: tx.date)
                return RecentTransaction(
                    date: tx.date,
                    payee: tx.payee.isEmpty ? "Unknown" : tx.payee,
                    amount: nsDecToDouble(tx.amount),
                    categoryName: tx.category?.name ?? "Uncategorized",
                    isWeekend: weekday == 1 || weekday == 7,
                    hourOfDay: hour,
                    dayOfWeek: dayNames[weekday - 1]
                )
            }

        // Emotional Spending Detector — pre-computed behavioral signals
        let emotionalProfile = buildEmotionalProfile(transactions: recentTxns)

        // Monthly overview — spans the selected range and always ends on the
        // current month (even when the current month has zero data yet).
        let monthlyOverview = buildMonthlyOverview(
            context: context,
            rangeStart: rangeStart,
            currentMonthStart: startOfMonth,
            currentMonthSpent: spentSoFar,
            currentMonthProjected: projectedSpending,
            currentMonthIncome: income,
            expectedMonthIncome: expectedIncome,
            dailyAvg: dailyAvg,
            cal: cal
        )

        return PredictionData(
            spendingTrajectory: trajectory,
            dailyBars: bars,
            confidenceBand: band,
            forecast: forecast,
            categoryProjections: catProjections,
            topMerchants: topMerchants,
            weeklyComparison: weeklyComparison,
            accountSnapshots: accountSnapshots,
            subscriptionPressure: subscriptionPressure,
            savingsRate: savingsRate,
            lastMonthSpending: lastMonthSpending,
            topInsights: insights,
            recentTransactions: recentTxns,
            emotionalProfile: emotionalProfile,
            monthlyOverview: monthlyOverview
        )
    }

    // MARK: - AI Analysis Prompt (Financial Strategist)

    static func buildAnalysisPrompt(data: PredictionData) -> String {
        let f = data.forecast
        var lines: [String] = []

        lines.append("STOP summarizing what is already visible on the screen.")
        lines.append("You are a Financial Strategist. Your job is to find what the user CANNOT see.")
        lines.append("Identify hidden patterns, anomalies, and behavioral triggers in the transaction data.")
        lines.append("Every sentence must contain a specific dollar amount, percentage, or date.")
        lines.append("If the projected spending exceeds $500, use a direct, critical tone.")
        lines.append("")

        // Section 1: Forecast
        lines.append("=== MONTHLY FORECAST ===")
        lines.append("Spent so far: $\(fmt(f.spentSoFar)) in \(f.daysPassed) days")
        lines.append("Projected end-of-month total: $\(fmt(f.projectedSpending))")
        lines.append("Monthly budget: $\(fmt(f.totalBudget))")
        lines.append("Delta (budget - projected): $\(fmt(f.delta))")
        lines.append("Days left: \(f.daysLeft)")
        lines.append("Daily average: $\(fmt(f.dailyAverage))/day")
        lines.append("Safe daily spend to stay on budget: $\(fmt(f.daysLeft > 0 && f.totalBudget > 0 ? max(0, (f.totalBudget - f.spentSoFar) / Double(f.daysLeft)) : 0))/day")
        lines.append("Income received: $\(fmt(f.incomeReceived))")
        lines.append("Expected income remaining: $\(fmt(f.expectedIncome))")
        lines.append("Savings rate: \(String(format: "%.0f", data.savingsRate * 100))%")
        lines.append("Last month total spending: $\(fmt(data.lastMonthSpending))")
        let momChange = data.lastMonthSpending > 0 ? ((f.projectedSpending - data.lastMonthSpending) / data.lastMonthSpending) * 100 : 0
        lines.append("Month-over-month change: \(String(format: "%+.0f", momChange))%")
        lines.append("")

        // Section 2: Weekly
        let w = data.weeklyComparison
        lines.append("=== WEEKLY COMPARISON ===")
        lines.append("This week spending: $\(fmt(w.thisWeekSpending))")
        lines.append("Last week spending: $\(fmt(w.lastWeekSpending))")
        lines.append("Change: \(String(format: "%+.0f", w.changePercent))%")
        lines.append("")

        // Section 3: Categories
        lines.append("=== CATEGORY PROJECTIONS ===")
        for cat in data.categoryProjections.prefix(8) {
            let budgetStr = cat.budget > 0 ? " / budget $\(fmt(cat.budget))" : ""
            let overStr = cat.budget > 0 && cat.projected > cat.budget
                ? " [OVER by $\(fmt(cat.projected - cat.budget))]" : ""
            lines.append("  \(cat.name): spent $\(fmt(cat.spent)) -> projected $\(fmt(cat.projected))\(budgetStr)\(overStr) trend:\(cat.trend.rawValue)")
        }
        lines.append("")

        // Section 4: Top merchants
        if !data.topMerchants.isEmpty {
            lines.append("=== TOP MERCHANTS ===")
            for m in data.topMerchants.prefix(5) {
                lines.append("  \(m.name): $\(fmt(m.amount)) (\(m.txCount) transactions)")
            }
            lines.append("")
        }

        // Section 5 — Individual Transaction Log (for anomaly detection)
        if !data.recentTransactions.isEmpty {
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "MMM d, h:mm a"
            // Cap at 25 — was 50. Halves the largest section of the prompt
            // without losing anomaly-detection signal (newest-first ordering
            // means the most relevant txns are kept).
            let txCap = 25
            lines.append("=== RAW TRANSACTION HISTORY (last \(txCap), newest first) ===")
            lines.append("Scan for time-based triggers, anomalous amounts, merchant clustering.")
            for tx in data.recentTransactions.prefix(txCap) {
                let timeLabel = tx.hourOfDay >= 22 || tx.hourOfDay < 5 ? " [LATE NIGHT]" : ""
                let weekendLabel = tx.isWeekend ? " [WEEKEND]" : ""
                lines.append("  \(tx.dayOfWeek) \(dateFmt.string(from: tx.date))\(weekendLabel)\(timeLabel) — \(tx.payee) — $\(fmt(tx.amount)) [\(tx.categoryName)]")
            }
            lines.append("")
        }

        // Section 5b — Pre-computed Behavioral Signals (Emotional Spending Detector output)
        let ep = data.emotionalProfile
        lines.append("=== BEHAVIORAL SIGNALS (pre-computed) ===")
        lines.append("Late-night purchases (10PM-5AM): \(ep.lateNightCount) transactions, $\(fmt(ep.lateNightTotal)) total")
        lines.append("Weekend spending: \(ep.weekendCount) transactions, $\(fmt(ep.weekendTotal)) total")
        lines.append("Impulse charges (<$15): \(ep.impulseCount) transactions, $\(fmt(ep.impulseTotal)) total")
        lines.append("Average transaction size: $\(fmt(ep.avgTransactionSize))")
        lines.append("Peak spending hour: \(ep.peakSpendingHour):00")
        lines.append("Peak spending day: \(ep.peakSpendingDay)")
        if !ep.highFrequencyMerchants.isEmpty {
            lines.append("HIGH-FREQUENCY MERCHANTS (3+ visits — potential addiction/habit):")
            for m in ep.highFrequencyMerchants.prefix(5) {
                lines.append("  \(m.name): \(m.count) visits, $\(fmt(m.total)) total (avg $\(fmt(m.total / Double(m.count)))/visit)")
            }
        }
        lines.append("")

        // Section 6: Accounts
        if !data.accountSnapshots.isEmpty {
            lines.append("=== ACCOUNTS ===")
            for a in data.accountSnapshots {
                var line = "  \(a.name) (\(a.type)): $\(fmt(a.balance))"
                if let util = a.utilization, let limit = a.creditLimit {
                    line += " — \(String(format: "%.0f", util * 100))% of $\(fmt(limit)) limit"
                }
                lines.append(line)
            }
            lines.append("")
        }

        // Section 7: Subscriptions
        if let sub = data.subscriptionPressure {
            lines.append("=== SUBSCRIPTIONS ===")
            lines.append("Active count: \(sub.count)")
            lines.append("Monthly cost: $\(fmt(sub.monthlyTotal))")
            lines.append("Annual cost: $\(fmt(sub.annualTotal))")
            lines.append("Next bill: \(sub.nextBillName) — $\(fmt(sub.nextBillAmount)) on \(shortDate(sub.nextBillDate))")
            lines.append("")
        }

        // Output format — Quant-Psychologist, not summarizer
        lines.append("=== YOUR OUTPUT FORMAT ===")
        lines.append("Write your analysis in these exact sections, using markdown headers.")
        lines.append("DO NOT repeat numbers the user already sees. ONLY reveal what is HIDDEN.")
        lines.append("Use the BEHAVIORAL SIGNALS above as hard evidence for your analysis.")
        lines.append("")
        lines.append("## Monthly Outlook")
        lines.append("2-3 sentences ONLY. Will the budget survive? Strategic assessment, not a recap.")
        lines.append("")
        lines.append("## Trigger Analysis")
        lines.append("Identify spending TRIGGERS — time-based patterns the user is blind to:")
        lines.append("- Late-night boredom spending (use the 10PM-5AM data above)")
        lines.append("- Weekend escapism (use weekend data)")
        lines.append("- Payday splurge pattern (spending spikes after income)")
        lines.append("- Specific hour clustering (use peak spending hour)")
        lines.append("Name the merchants, the times, the amounts. Be forensic.")
        lines.append("")
        lines.append("## Anomaly Detection")
        lines.append("Find the 'Budget Killers' — transactions that don't fit the user's usual profile:")
        lines.append("- One-off large purchases way above average transaction size ($\(fmt(ep.avgTransactionSize)))")
        lines.append("- Merchant you've never seen before with a big charge")
        lines.append("- Category spending that jumped 50%+ vs prior pattern")
        lines.append("Be specific: merchant name, amount, why it's abnormal.")
        lines.append("")
        lines.append("## Spending Psychology")
        lines.append("Give a 1-sentence psychological profile of this spender based on the behavioral signals.")
        lines.append("Then explain the dominant pattern: impulse buyer, emotional spender, subscription hoarder, or routine overspender.")
        lines.append("Use the impulse count (\(ep.impulseCount) charges <$15) and late-night count (\(ep.lateNightCount)) as evidence.")
        lines.append("")
        lines.append("## Combat Plan")
        lines.append("Exactly 3 aggressive, specific actions to save $100+ in 7 days.")
        lines.append("Each action: what to cut + which merchant + exact dollar savings + the math.")
        lines.append("Format: 'ACTION: [what] -> SAVE $XX ([calculation])'")
        lines.append("BANNED phrases: 'cook at home', 'make a budget', 'track spending', 'save more'.")
        lines.append("Use actual merchant names from the transaction log.")
        lines.append("")
        lines.append("## Category Risks")
        lines.append("Which categories breach budget, by how much, and the estimated breach date.")
        lines.append("")
        lines.append("Be direct, sharp, and slightly critical if over budget. Every sentence = a number.")

        return lines.joined(separator: "\n")
    }

    // ============================================================
    // MARK: - Multi-Range Analysis Prompt
    // ============================================================
    //
    // Single prompt that covers ALL 5 time windows. Instructs Gemma to
    // tag every claim with `[This Month]` / `[Last Month]` / etc. so the
    // resulting markdown is meaningful when shown on any range view.
    // The prediction page uses ONE generation for all ranges (llama.cpp
    // can't truly parallelise on a single context); this prompt makes the
    // shared output explicit and informative instead of monthly-only.
    //
    // ============================================================

    static func buildMultiRangeAnalysisPrompt(
        allData: [PredictionTimeRange: PredictionData]
    ) -> String {
        var lines: [String] = []

        lines.append("You are a Financial Strategist analyzing this user's spending across 5 time windows.")
        lines.append("Find HIDDEN patterns. Every paragraph must reference a specific window via a bracketed tag.")
        lines.append("")
        lines.append("VALID WINDOW TAGS — use these EXACT strings (with brackets):")
        lines.append("[This Month] [Last Month] [Last 3 Months] [Last 6 Months] [Last Year]")
        lines.append("")
        lines.append("Every paragraph in the report MUST start with one of those tags.")
        lines.append("Do NOT write a paragraph without a tag. Compare windows where it strengthens the insight.")
        lines.append("")

        // Per-window summary blocks
        let order: [PredictionTimeRange] = [.thisMonth, .lastMonth, .last3Months, .last6Months, .lastYear]
        for range in order {
            guard let data = allData[range] else { continue }
            let f = data.forecast
            lines.append("=== \(range.rawValue.uppercased()) ===")
            lines.append("Spent: $\(fmt(f.spentSoFar)) / Budget $\(fmt(f.totalBudget)) / Projected $\(fmt(f.projectedSpending))")
            lines.append("Daily avg: $\(fmt(f.dailyAverage))/day  Days passed: \(f.daysPassed)  Days left in current month: \(f.daysLeft)")
            lines.append("Income: $\(fmt(f.incomeReceived))  Savings rate: \(String(format: "%.0f", data.savingsRate * 100))%")
            if !data.categoryProjections.isEmpty {
                let topCats = data.categoryProjections.prefix(5).map { "\($0.name) $\(fmt($0.spent))" }.joined(separator: ", ")
                lines.append("Top categories: \(topCats)")
            }
            if !data.topMerchants.isEmpty {
                let topMerch = data.topMerchants.prefix(4).map { "\($0.name) $\(fmt($0.amount)) (\($0.txCount)x)" }.joined(separator: ", ")
                lines.append("Top merchants: \(topMerch)")
            }
            let ep = data.emotionalProfile
            lines.append("Behavioral: late-night \(ep.lateNightCount) txns ($\(fmt(ep.lateNightTotal))), weekend \(ep.weekendCount) txns ($\(fmt(ep.weekendTotal))), impulse \(ep.impulseCount) txns ($\(fmt(ep.impulseTotal)))")
            lines.append("")
        }

        // Shared raw transaction history — pull from the widest available window
        // so the AI can reason across periods. Cap at 30 to keep prompt tight.
        let widest = allData[.lastYear] ?? allData[.last6Months] ?? allData[.last3Months] ?? allData[.thisMonth]
        if let data = widest, !data.recentTransactions.isEmpty {
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "MMM d, h:mm a"
            lines.append("=== RAW TRANSACTION HISTORY (last 30 across widest window, newest first) ===")
            for tx in data.recentTransactions.prefix(30) {
                let timeLabel = tx.hourOfDay >= 22 || tx.hourOfDay < 5 ? " [LATE]" : ""
                let weekendLabel = tx.isWeekend ? " [WKND]" : ""
                lines.append("  \(tx.dayOfWeek) \(dateFmt.string(from: tx.date))\(weekendLabel)\(timeLabel) — \(tx.payee) — $\(fmt(tx.amount)) [\(tx.categoryName)]")
            }
            lines.append("")
        }

        // Output spec
        lines.append("=== OUTPUT FORMAT ===")
        lines.append("Start with a JSON block between ---PREDICTIONS--- markers.")
        lines.append("The numerics in the JSON describe THIS MONTH (the focal forecast period):")
        lines.append("")
        lines.append("---PREDICTIONS---")
        lines.append("{")
        lines.append("  \"projectedSpending\": <number>,")
        lines.append("  \"savingsRate\": <0-100>,")
        lines.append("  \"riskLevel\": \"<low/medium/high>\",")
        lines.append("  \"weeklyTrend\": \"<accelerating/decelerating/stable>\",")
        lines.append("  \"breakEvenDay\": <day or null>,")
        lines.append("  \"categories\": [{\"name\": \"<cat>\", \"projected\": <amount>}],")
        lines.append("  \"triggers\": [{\"pattern\": \"<name>\", \"description\": \"<detail>\", \"amount\": <$>}],")
        lines.append("  \"anomalies\": [{\"merchant\": \"<name>\", \"amount\": <$>, \"description\": \"<why>\"}],")
        lines.append("  \"combatPlan\": [{\"action\": \"<cut>\", \"savings\": <$>, \"reason\": \"<why>\"}]")
        lines.append("}")
        lines.append("---PREDICTIONS---")
        lines.append("")
        lines.append("Then write the full report. EVERY paragraph MUST begin with one of the window tags.")
        lines.append("Use these ## headers in this order:")
        lines.append("")
        lines.append("## Monthly Outlook")
        lines.append("2-4 paragraphs comparing windows. Example: '[This Month] You are on pace to spend $X...' '[Last 3 Months] The trend has been accelerating: $Y/mo average vs $Z six months ago.'")
        lines.append("")
        lines.append("## Trigger Analysis")
        lines.append("Time-based patterns. One paragraph per relevant window. Tag each.")
        lines.append("Example: '[This Month] 6 late-night DoorDash orders totaling $87.' '[Last Year] Late-night ordering accounts for 14% of restaurant spend across the year.'")
        lines.append("")
        lines.append("## Anomaly Detection")
        lines.append("Budget killers. One tagged paragraph per window where anomalies appear.")
        lines.append("")
        lines.append("## Spending Psychology")
        lines.append("1-2 paragraphs. Each tagged. Use the longest window available for the strongest signal.")
        lines.append("")
        lines.append("## Combat Plan")
        lines.append("3 specific actions. Each action prefixed with the window the data came from.")
        lines.append("Example: '[Last 3 Months] Cancel Hulu — 0 logins, $15.99/mo = $192/yr saved.'")
        lines.append("")
        lines.append("## Category Risks")
        lines.append("Tag each: which window, which categories, by how much.")
        lines.append("")
        lines.append("RULES:")
        lines.append("- EVERY paragraph starts with a [Window] tag.")
        lines.append("- Every sentence contains a dollar amount, percentage, or date.")
        lines.append("- Compare windows where it strengthens the insight.")
        lines.append("- BANNED phrases: 'cook at home', 'make a budget', 'track spending', 'save more'.")

        return lines.joined(separator: "\n")
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.0f", v) }
    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
    }

    // MARK: - Trajectory Builder

    private static func buildTrajectory(
        dailyTotals: [Int: Double],
        startOfMonth: Date,
        daysPassed: Int,
        totalDays: Int,
        dailyAvg: Double,
        cal: Calendar
    ) -> [SpendingDataPoint] {
        var points: [SpendingDataPoint] = []

        var cumulative = 0.0
        for day in 0..<daysPassed {
            cumulative += dailyTotals[day] ?? 0
            let date = cal.date(byAdding: .day, value: day, to: startOfMonth)!
            points.append(SpendingDataPoint(date: date, amount: cumulative, isProjected: false))
        }

        // Projection: per-day amount = trailing7DayAvg × weekday multiplier.
        // Multipliers come from this user's own weekday spending pattern, so
        // weekends spike, quiet weekdays dip — the line has honest ups and downs.
        let trailingAvg = trailing7DayWeightedAvg(dailyTotals: dailyTotals, daysPassed: daysPassed, fallback: dailyAvg)
        let weekdayMult = weekdayMultipliers(dailyTotals: dailyTotals, startOfMonth: startOfMonth, daysPassed: daysPassed, cal: cal)
        for day in daysPassed..<totalDays {
            let date = cal.date(byAdding: .day, value: day, to: startOfMonth)!
            let wd = cal.component(.weekday, from: date) // 1...7
            let mult = weekdayMult[wd] ?? 1.0
            cumulative += max(0, trailingAvg * mult)
            points.append(SpendingDataPoint(date: date, amount: cumulative, isProjected: true))
        }

        return points
    }

    /// Build per-weekday multipliers from historical daily spend (mean-weekday / mean-all).
    /// Returns multipliers keyed by Calendar weekday (1=Sunday...7=Saturday).
    /// Capped to [0.5, 1.6] so one anomaly day can't warp the projection.
    private static func weekdayMultipliers(
        dailyTotals: [Int: Double],
        startOfMonth: Date,
        daysPassed: Int,
        cal: Calendar
    ) -> [Int: Double] {
        guard daysPassed >= 7 else { return [:] }
        var perWeekday: [Int: [Double]] = [:]
        for day in 0..<daysPassed {
            let amt = dailyTotals[day] ?? 0
            guard let date = cal.date(byAdding: .day, value: day, to: startOfMonth) else { continue }
            let wd = cal.component(.weekday, from: date)
            perWeekday[wd, default: []].append(amt)
        }
        let allAmounts = perWeekday.values.flatMap { $0 }
        guard !allAmounts.isEmpty else { return [:] }
        let overallMean = allAmounts.reduce(0, +) / Double(allAmounts.count)
        guard overallMean > 0 else { return [:] }
        var result: [Int: Double] = [:]
        for (wd, amounts) in perWeekday where !amounts.isEmpty {
            let mean = amounts.reduce(0, +) / Double(amounts.count)
            let raw = mean / overallMean
            // Blend 70% observed pattern / 30% flat, then clamp — avoids wild swings on thin data
            let blended = raw * 0.7 + 0.3
            result[wd] = min(max(blended, 0.5), 1.6)
        }
        return result
    }

    /// Trailing 7-day weighted mean (most recent day weighted most). Deterministic, no noise.
    private static func trailing7DayWeightedAvg(dailyTotals: [Int: Double], daysPassed: Int, fallback: Double) -> Double {
        guard daysPassed > 0 else { return fallback }
        let window = min(7, daysPassed)
        var weightedSum = 0.0
        var weightTotal = 0.0
        for i in 0..<window {
            let dayIdx = daysPassed - 1 - i
            let w = Double(window - i) // 7, 6, 5, ... 1
            weightedSum += (dailyTotals[dayIdx] ?? 0) * w
            weightTotal += w
        }
        let avg = weightTotal > 0 ? weightedSum / weightTotal : fallback
        // Blend 70% recent / 30% month-average so a single spike day doesn't dominate
        return avg * 0.7 + fallback * 0.3
    }

    // MARK: - Daily Bars Builder

    private static func buildDailyBars(
        dailyTotals: [Int: Double],
        startOfMonth: Date,
        daysPassed: Int,
        totalDays: Int,
        dailyAvg: Double,
        cal: Calendar
    ) -> [DailySpendingBar] {
        var bars: [DailySpendingBar] = []

        for day in 0..<daysPassed {
            let date = cal.date(byAdding: .day, value: day, to: startOfMonth)!
            bars.append(DailySpendingBar(
                dayOfMonth: day + 1,
                date: date,
                amount: dailyTotals[day] ?? 0,
                isProjected: false
            ))
        }

        // Projected bars mirror the trajectory: trailing avg × weekday multiplier.
        // Bars and the cumulative line now agree, and both show natural weekly rhythm.
        let trailingAvg = trailing7DayWeightedAvg(dailyTotals: dailyTotals, daysPassed: daysPassed, fallback: dailyAvg)
        let weekdayMult = weekdayMultipliers(dailyTotals: dailyTotals, startOfMonth: startOfMonth, daysPassed: daysPassed, cal: cal)
        for day in daysPassed..<totalDays {
            let date = cal.date(byAdding: .day, value: day, to: startOfMonth)!
            let wd = cal.component(.weekday, from: date)
            let mult = weekdayMult[wd] ?? 1.0
            bars.append(DailySpendingBar(
                dayOfMonth: day + 1,
                date: date,
                amount: max(0, trailingAvg * mult),
                isProjected: true
            ))
        }

        return bars
    }

    // MARK: - Confidence Band Builder

    private static func buildConfidenceBand(
        startOfMonth: Date,
        daysPassed: Int,
        totalDays: Int,
        cumulativeAtToday: Double,
        dailyAvg: Double,
        stdDev: Double,
        cal: Calendar
    ) -> [ConfidenceBandPoint] {
        var points: [ConfidenceBandPoint] = []
        let spread = max(stdDev, dailyAvg * 0.1)

        // Build a thin ribbon around the projected cumulative line
        var cumCenter = cumulativeAtToday
        let totalProjectedDays = Double(totalDays - daysPassed)

        for day in daysPassed..<totalDays {
            let daysOut = Double(day - daysPassed + 1)
            cumCenter += dailyAvg
            // Band width grows with sqrt but stays narrow (±percentage of center)
            let bandWidth = min(sqrt(daysOut) * spread, cumCenter * 0.08)
            let date = cal.date(byAdding: .day, value: day, to: startOfMonth)!
            points.append(ConfidenceBandPoint(
                date: date,
                low: max(0, cumCenter - bandWidth),
                high: cumCenter + bandWidth
            ))
        }

        return points
    }

    // MARK: - Standard Deviation

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return sqrt(variance)
    }

    // MARK: - Monthly Overview (range-aware)

    /// Build a month-by-month actual/forecast series from `rangeStart` up to
    /// and INCLUDING the current month. The current month is always the last
    /// entry regardless of whether it has any data. Months without
    /// transactions still appear with `actual = 0` so the user can see the
    /// gap in history.
    private static func buildMonthlyOverview(
        context: ModelContext,
        rangeStart: Date,
        currentMonthStart: Date,
        currentMonthSpent: Double,
        currentMonthProjected: Double,
        currentMonthIncome: Double,
        expectedMonthIncome: Double,
        dailyAvg: Double,
        cal: Calendar
    ) -> [MonthlySpendingData] {
        let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var result: [MonthlySpendingData] = []

        var cursor = rangeStart
        while cursor <= currentMonthStart {
            let m = cal.component(.month, from: cursor)
            let y = cal.component(.year, from: cursor)
            let isCurrent = cal.isDate(cursor, equalTo: currentMonthStart, toGranularity: .month)
            // Label: "Apr" normally; "Apr '25" across year boundaries so the
            // axis stays legible on 6M/1Y windows.
            let currentYear = cal.component(.year, from: currentMonthStart)
            let label = (y == currentYear)
                ? monthNames[m - 1]
                : "\(monthNames[m - 1]) '\(String(format: "%02d", y % 100))"

            // Per-month budget (MonthlyTotalBudget keyed by year+month). The
            // chart renders one budget rule PER bar so the user can see how
            // each month's actual stacks up against the budget that applied
            // that month — different months can have different budgets.
            let monthBudget = nsDecToDouble(fetchTotalBudget(context: context, year: y, month: m))

            if isCurrent {
                result.append(MonthlySpendingData(
                    month: m,
                    year: y,
                    monthLabel: label,
                    actual: currentMonthSpent,
                    forecast: max(0, currentMonthProjected - currentMonthSpent),
                    income: max(currentMonthIncome, expectedMonthIncome),
                    budget: monthBudget,
                    isCurrent: true,
                    isFuture: false
                ))
            } else {
                let monthEnd = cal.date(byAdding: .month, value: 1, to: cursor) ?? cursor
                let txns = fetchTransactions(context: context, from: cursor, to: monthEnd)
                let total = txns
                    .filter { !$0.isIncome && BalanceService.isSpendingExpense($0) }
                    .reduce(0.0) { $0 + nsDecToDouble($1.amount) }
                let incomeTotal = txns
                    .filter { $0.isIncome }
                    .reduce(0.0) { $0 + nsDecToDouble($1.amount) }
                result.append(MonthlySpendingData(
                    month: m,
                    year: y,
                    monthLabel: label,
                    actual: total,
                    forecast: 0,
                    income: incomeTotal,
                    budget: monthBudget,
                    isCurrent: false,
                    isFuture: false
                ))
            }
            cursor = cal.date(byAdding: .month, value: 1, to: cursor) ?? cursor.addingTimeInterval(31 * 86400)
        }
        return result
    }

    // MARK: - Category Projections

    private static func buildCategoryProjections(
        context: ModelContext,
        expenses: [Transaction],
        year: Int,
        month: Int,
        daysPassed: Int,
        totalDays: Int,
        budgetMultiplier: Int = 1
    ) -> [CategoryProjection] {
        // Group expenses by category
        var catSpending: [String: (spent: Double, icon: String, colorHex: String)] = [:]
        for tx in expenses {
            let name = tx.category?.name ?? "Uncategorized"
            let icon = tx.category?.icon ?? "questionmark.circle"
            let color = tx.category?.colorHex ?? "888888"
            catSpending[name, default: (0, icon, color)].spent += nsDecToDouble(tx.amount)
        }

        // Get budgets per category. Scaled by `budgetMultiplier` so a 6-month
        // window compares window-spend against 6 × per-month-budget.
        let catBudgets = fetchCategoryBudgets(context: context, year: year, month: month)

        let ratio = Double(totalDays) / Double(daysPassed)

        var projections: [CategoryProjection] = []
        for (name, data) in catSpending {
            let projected = data.spent * ratio
            let budget = (catBudgets[name] ?? 0) * Double(budgetMultiplier)

            // Determine trend from daily pattern
            let trend: CategoryProjection.Trend
            if daysPassed > 3 {
                let halfPoint = daysPassed / 2
                let firstHalf = expenses
                    .filter { ($0.category?.name ?? "Uncategorized") == name }
                    .prefix(while: {
                        let cal = Calendar.current
                        let day = cal.dateComponents([.day], from: cal.startOfDay(for: $0.date), to: cal.startOfDay(for: Date())).day ?? 0
                        return day >= halfPoint
                    })
                    .reduce(0.0) { $0 + nsDecToDouble($1.amount) }
                let secondHalf = data.spent - firstHalf

                if secondHalf > firstHalf * 1.2 {
                    trend = .rising
                } else if secondHalf < firstHalf * 0.8 {
                    trend = .falling
                } else {
                    trend = .stable
                }
            } else {
                trend = .stable
            }

            projections.append(CategoryProjection(
                name: name,
                icon: data.icon,
                colorHex: data.colorHex,
                spent: data.spent,
                budget: budget,
                projected: projected,
                trend: trend
            ))
        }

        return projections.sorted { $0.spent > $1.spent }
    }

    // MARK: - Quick Insights (rule-based)

    private static func generateInsights(forecast: MonthForecast, categories: [CategoryProjection]) -> [String] {
        var insights: [String] = []

        if forecast.isOverBudget {
            let over = forecast.projectedSpending - forecast.totalBudget
            insights.append("[exclamationmark.triangle.fill] On pace to exceed budget by $\(String(format: "%.0f", over))")
        } else if forecast.totalBudget > 0 {
            let under = forecast.totalBudget - forecast.projectedSpending
            insights.append("[checkmark.circle.fill] Projected to finish $\(String(format: "%.0f", under)) under budget")
        }

        // Categories over budget
        let overBudgetCats = categories.filter { $0.budget > 0 && $0.projected > $0.budget }
        for cat in overBudgetCats.prefix(2) {
            let over = cat.projected - cat.budget
            insights.append("[exclamationmark.triangle.fill] \(cat.name) projected $\(String(format: "%.0f", over)) over budget")
        }

        // Rising categories
        let risingCats = categories.filter { $0.trend == .rising && $0.spent > 50 }
        for cat in risingCats.prefix(1) {
            insights.append("[arrow.up.right] \(cat.name) spending is accelerating")
        }

        // Falling categories
        let fallingCats = categories.filter { $0.trend == .falling && $0.spent > 50 }
        for cat in fallingCats.prefix(1) {
            insights.append("[arrow.down.right] \(cat.name) spending is slowing down")
        }

        if forecast.daysLeft > 0 && forecast.totalBudget > 0 {
            let safeDaily = (forecast.totalBudget - forecast.spentSoFar) / Double(forecast.daysLeft)
            if safeDaily > 0 {
                insights.append("[calendar.badge.clock] Safe to spend $\(String(format: "%.0f", safeDaily))/day for the rest of the month")
            }
        }

        return insights
    }

    // MARK: - Top Merchants

    private static func buildTopMerchants(expenses: [Transaction]) -> [TopMerchant] {
        var merchantMap: [String: (amount: Double, count: Int)] = [:]
        for tx in expenses {
            let name = tx.payee.isEmpty ? "Unknown" : tx.payee
            merchantMap[name, default: (0, 0)].amount += nsDecToDouble(tx.amount)
            merchantMap[name, default: (0, 0)].count += 1
        }
        return merchantMap
            .map { TopMerchant(name: $0.key, amount: $0.value.amount, txCount: $0.value.count) }
            .sorted { $0.amount > $1.amount }
            .prefix(8)
            .map { $0 }
    }

    // MARK: - Weekly Comparison

    private static func buildWeeklyComparison(context: ModelContext, now: Date, cal: Calendar) -> WeeklyComparison {
        let startOfThisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let startOfLastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: startOfThisWeek)!

        let thisWeekTxns = fetchTransactions(context: context, from: startOfThisWeek, to: now)
        let lastWeekTxns = fetchTransactions(context: context, from: startOfLastWeek, to: startOfThisWeek)

        let thisWeek = thisWeekTxns
            .filter { !$0.isIncome && BalanceService.isSpendingExpense($0) }
            .reduce(0.0) { $0 + nsDecToDouble($1.amount) }
        let lastWeek = lastWeekTxns
            .filter { !$0.isIncome && BalanceService.isSpendingExpense($0) }
            .reduce(0.0) { $0 + nsDecToDouble($1.amount) }

        return WeeklyComparison(thisWeekSpending: thisWeek, lastWeekSpending: lastWeek)
    }

    // MARK: - Account Snapshots

    private static func buildAccountSnapshots(context: ModelContext) -> [AccountSnapshot] {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isArchived && !$0.isClosed }
        )
        guard let accounts = try? context.fetch(descriptor) else { return [] }

        return accounts.map { acct in
            AccountSnapshot(
                name: acct.name,
                type: acct.type.rawValue,
                balance: nsDecToDouble(acct.currentBalance),
                creditLimit: acct.creditLimit.map { nsDecToDouble($0) },
                utilization: acct.creditLimit.map { limit in
                    limit > 0 ? nsDecToDouble(acct.currentBalance) / nsDecToDouble(limit) : 0
                }
            )
        }
    }

    // MARK: - Subscription Pressure

    private static func buildSubscriptionPressure(context: ModelContext, now: Date) -> SubscriptionPressure? {
        let activeSub = SubscriptionStatus.active
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.status == activeSub }
        )
        guard let subs = try? context.fetch(descriptor), !subs.isEmpty else { return nil }

        let monthlyTotal = subs.reduce(0.0) { $0 + nsDecToDouble($1.monthlyCost) }
        let annualTotal = subs.reduce(0.0) { $0 + nsDecToDouble($1.annualCost) }

        let nextBill = subs
            .filter { $0.nextPaymentDate > now }
            .min(by: { $0.nextPaymentDate < $1.nextPaymentDate })

        return SubscriptionPressure(
            monthlyTotal: monthlyTotal,
            annualTotal: annualTotal,
            nextBillName: nextBill?.serviceName ?? "None",
            nextBillAmount: nextBill.map { nsDecToDouble($0.amount) } ?? 0,
            nextBillDate: nextBill?.nextPaymentDate ?? now,
            count: subs.count
        )
    }

    // MARK: - Emotional Spending Detector

    private static func buildEmotionalProfile(transactions: [RecentTransaction]) -> EmotionalSpendingProfile {
        guard !transactions.isEmpty else {
            return EmotionalSpendingProfile(
                lateNightCount: 0, lateNightTotal: 0,
                weekendCount: 0, weekendTotal: 0,
                impulseCount: 0, impulseTotal: 0,
                highFrequencyMerchants: [],
                peakSpendingHour: 12, peakSpendingDay: "Mon",
                avgTransactionSize: 0,
                hourlySpending: [:]
            )
        }

        // Late-night: 10PM–5AM
        let lateNight = transactions.filter { $0.hourOfDay >= 22 || $0.hourOfDay < 5 }
        let lateNightCount = lateNight.count
        let lateNightTotal = lateNight.reduce(0.0) { $0 + $1.amount }

        // Weekend spending
        let weekend = transactions.filter { $0.isWeekend }
        let weekendCount = weekend.count
        let weekendTotal = weekend.reduce(0.0) { $0 + $1.amount }

        // Impulse: small frequent charges < $15
        let impulse = transactions.filter { $0.amount < 15 && $0.amount > 0 }
        let impulseCount = impulse.count
        let impulseTotal = impulse.reduce(0.0) { $0 + $1.amount }

        // High-frequency merchants (3+ visits)
        var merchantFreq: [String: (count: Int, total: Double)] = [:]
        for tx in transactions {
            merchantFreq[tx.payee, default: (0, 0)].count += 1
            merchantFreq[tx.payee, default: (0, 0)].total += tx.amount
        }
        let highFreq = merchantFreq
            .filter { $0.value.count >= 3 }
            .map { (name: $0.key, count: $0.value.count, total: $0.value.total) }
            .sorted { $0.total > $1.total }

        // Peak spending hour
        var hourTotals = [Int: Double]()
        for tx in transactions { hourTotals[tx.hourOfDay, default: 0] += tx.amount }
        let peakHour = hourTotals.max(by: { $0.value < $1.value })?.key ?? 12

        // Peak spending day of week
        var dayTotals = [String: Double]()
        for tx in transactions { dayTotals[tx.dayOfWeek, default: 0] += tx.amount }
        let peakDay = dayTotals.max(by: { $0.value < $1.value })?.key ?? "Mon"

        let avgSize = transactions.reduce(0.0) { $0 + $1.amount } / Double(transactions.count)

        return EmotionalSpendingProfile(
            lateNightCount: lateNightCount,
            lateNightTotal: lateNightTotal,
            weekendCount: weekendCount,
            weekendTotal: weekendTotal,
            impulseCount: impulseCount,
            impulseTotal: impulseTotal,
            highFrequencyMerchants: highFreq,
            peakSpendingHour: peakHour,
            peakSpendingDay: peakDay,
            avgTransactionSize: avgSize,
            hourlySpending: hourTotals
        )
    }

    // MARK: - Data Fetching

    private static func fetchTransactions(context: ModelContext, from start: Date, to end: Date) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchTotalBudget(context: ModelContext, year: Int, month: Int) -> Decimal {
        let descriptor = FetchDescriptor<MonthlyTotalBudget>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        return (try? context.fetch(descriptor))?.first?.amount ?? 0
    }

    private static func fetchCategoryBudgets(context: ModelContext, year: Int, month: Int) -> [String: Double] {
        let catDescriptor = FetchDescriptor<BudgetCategory>()
        guard let categories = try? context.fetch(catDescriptor) else { return [:] }

        let overrideDescriptor = FetchDescriptor<MonthlyBudget>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        let overrides = (try? context.fetch(overrideDescriptor)) ?? []
        let overrideMap = Dictionary(uniqueKeysWithValues: overrides.map { ($0.categoryID, $0.amount) })

        var result: [String: Double] = [:]
        for cat in categories where cat.isExpenseCategory {
            let amount = overrideMap[cat.id] ?? cat.budgetAmount
            if amount > 0 {
                result[cat.name] = nsDecToDouble(amount)
            }
        }
        return result
    }

    private static func fetchExpectedIncome(context: ModelContext, after: Date, before: Date) -> Double {
        let descriptor = FetchDescriptor<RecurringTransaction>(
            predicate: #Predicate { $0.isActive && $0.isIncome }
        )
        guard let recurring = try? context.fetch(descriptor) else { return 0 }
        return recurring
            .filter { $0.nextOccurrence > after && $0.nextOccurrence <= before }
            .reduce(0.0) { $0 + nsDecToDouble($1.amount) }
    }

    private static func nsDecToDouble(_ d: Decimal) -> Double {
        NSDecimalNumber(decimal: d).doubleValue
    }
}
