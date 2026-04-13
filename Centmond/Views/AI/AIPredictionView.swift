import SwiftUI
import SwiftData
import Charts
import os

private let log = Logger(subsystem: "com.centmond.ai", category: "PredictionView")

// MARK: - Loading Phases

enum LoadPhase: Equatable {
    case loadingModel
    case analyzingData
    case ready
}

struct AIPredictionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    @State private var phase: LoadPhase = .loadingModel
    @State private var predictionData: PredictionData?
    @State private var aiAnalysisText = ""
    @State private var aiPredictions: AIPredictionResult?
    @State private var isStreamingAI = false
    @State private var aiParsedFromStream = false
    @State private var hoveredDay: Int?
    @State private var hoverLocation: CGPoint = .zero

    private let aiManager = AIManager.shared

    // MARK: - Card Height Constants
    private let intelligenceCardHeight: CGFloat = 130
    private var deepAnalysisCardHeight: CGFloat { intelligenceCardHeight * 3 + CentmondTheme.Spacing.sm * 2 }
    private let dataCardHeight: CGFloat = 280

    var body: some View {
        ScrollView {
            if phase == .ready, let data = predictionData, let ai = aiPredictions {
                VStack(spacing: CentmondTheme.Spacing.sm) {
                    // Row 1: Compact forecast strip + inline stats
                    compactForecastStrip(data.forecast, ai: ai)

                    // Row 2: THE CHART — the visual star, full width
                    spendingTrajectoryChart(data, aiProjected: ai.projectedMonthlySpending)

                    // Row 3: Intelligence (left, stacked) + Deep Analysis (right, tall)
                    HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
                        // Left column: 3 intelligence cards stacked
                        VStack(spacing: CentmondTheme.Spacing.sm) {
                            triggerAnalysisCard(ai.triggers)
                            anomalyDetectionCard(ai.anomalies)
                            combatPlanCard(ai.combatPlan)
                        }
                        .frame(maxWidth: .infinity)

                        // Right column: AI Deep Analysis (fills height naturally)
                        aiAnalysisCard
                            .frame(maxWidth: .infinity)
                    }

                    // Row 4: Categories + Merchants (2-column, equal)
                    HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
                        categoryProjectionsCard(ai.categoryPredictions.isEmpty ? data.categoryProjections : applyCategoryPredictions(base: data.categoryProjections, ai: ai.categoryPredictions))
                        topMerchantsCard(data.topMerchants)
                    }

                    // Row 5: Accounts + Subscriptions (2-column)
                    HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
                        accountHealthCard(data.accountSnapshots)
                        if let sub = data.subscriptionPressure {
                            subscriptionCard(sub)
                        }
                    }
                }
                .padding(CentmondTheme.Spacing.sm)
            } else {
                loadingPhaseContent
            }
        }
        .background(CentmondTheme.Colors.bgPrimary)
        .animation(CentmondTheme.Motion.layout, value: phase)
        .task {
            await startPipeline()
        }
    }

    // MARK: - Loading Phase Content

    private var loadingPhaseContent: some View {
        let icon: String
        let title: String
        let subtitle: String

        switch phase {
        case .loadingModel:
            icon = "brain.head.profile.fill"
            title = "Loading Gemma 4"
            subtitle = "Preparing AI model for analysis..."
        case .analyzingData:
            icon = "chart.bar.doc.horizontal"
            title = "Analyzing Your Finances"
            subtitle = "Gemma 4 is reviewing all your data and building predictions..."
        case .ready:
            icon = "checkmark.circle"
            title = "Preparing"
            subtitle = "Almost ready..."
        }

        return VStack(spacing: CentmondTheme.Spacing.xxl) {
            Spacer(minLength: 60)

            VStack(spacing: CentmondTheme.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(CentmondTheme.Colors.accent.opacity(0.08))
                        .frame(width: 80, height: 80)

                    Image(systemName: icon)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .symbolEffect(.pulse, options: .repeating)
                }

                Text(title)
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                Text(subtitle)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .multilineTextAlignment(.center)

                ProgressView()
                    .scaleEffect(1.0)
                    .padding(.top, CentmondTheme.Spacing.sm)
            }

            // Skeleton preview of what's coming
            VStack(spacing: CentmondTheme.Spacing.md) {
                SkeletonCard(height: 120)
                HStack(spacing: CentmondTheme.Spacing.md) {
                    SkeletonCard(height: 60)
                    SkeletonCard(height: 60)
                    SkeletonCard(height: 60)
                    SkeletonCard(height: 60)
                }
                SkeletonCard(height: 200)
                SkeletonCard(height: 160)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .opacity(0.4)

            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
        .padding(CentmondTheme.Spacing.xxl)
    }

    // MARK: - Pipeline

    private func startPipeline() async {
        log.info("Pipeline: starting, aiManager.status = \(String(describing: aiManager.status))")

        // Phase 1: Ensure model is loaded
        phase = .loadingModel

        // Check if model needs loading
        switch aiManager.status {
        case .ready:
            log.info("Pipeline: model already ready, skipping load")
        case .generating:
            log.info("Pipeline: model generating, waiting for it to finish")
            // Wait for generation to finish (max 30s)
            for _ in 0..<60 {
                if aiManager.status == .ready { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        case .loading:
            log.info("Pipeline: model already loading, waiting...")
        case .downloading:
            log.info("Pipeline: model downloading, showing fallback")
            showFallback(message: "AI model is downloading. Showing basic projections.")
            return
        case .notLoaded, .error:
            if aiManager.isModelDownloaded {
                log.info("Pipeline: loading model...")
                aiManager.loadModel()
            } else {
                log.info("Pipeline: model not downloaded, showing fallback")
                showFallback(message: "AI model is not downloaded. Download Gemma 4 in Settings to enable AI predictions.")
                return
            }
        }

        // Wait for model to be ready (poll every 500ms, timeout 45s)
        log.info("Pipeline: waiting for model ready...")
        let deadline = Date().addingTimeInterval(45)
        while aiManager.status != .ready && Date() < deadline {
            if case .error = aiManager.status {
                log.error("Pipeline: model error during wait")
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        log.info("Pipeline: after wait, status = \(String(describing: aiManager.status))")

        guard aiManager.status == .ready else {
            let errorMsg: String
            if case .error(let msg) = aiManager.status {
                errorMsg = "AI model error: \(msg). Showing basic projections."
            } else if case .loading = aiManager.status {
                errorMsg = "AI model is still loading. Showing basic projections for now."
            } else {
                errorMsg = "AI model could not be loaded. Showing basic projections based on your data."
            }
            log.warning("Pipeline: model not ready, showing fallback: \(errorMsg)")
            showFallback(message: errorMsg)
            return
        }

        // Phase 2: Compute base data
        log.info("Pipeline: Phase 2 — computing base data")
        phase = .analyzingData

        let rawData = AIPredictionEngine.compute(context: modelContext)
        log.info("Pipeline: data computed, categories=\(rawData.categoryProjections.count), merchants=\(rawData.topMerchants.count)")

        // Transition to ready with fallback predictions so UI is visible during streaming
        let fallbackAI = AIPredictionResult.fallback(from: rawData)
        predictionData = rawData
        aiPredictions = fallbackAI
        phase = .ready
        log.info("Pipeline: phase = .ready, starting AI stream")

        // Build comprehensive prompt and get AI predictions
        let prompt = AIPredictionEngine.buildAnalysisPrompt(data: rawData)
        let contextStr = AIContextBuilder.build(context: modelContext)
        let systemPrompt = """
        You are a high-stakes Financial Strategist and Behavioral Psychologist. Your job is NOT to summarize.
        Your job is to find the "WHY" behind the failure. Be brutally honest. If the user is being impulsive, call it out.
        Do NOT describe what is already visible on the screen. Find what is HIDDEN.
        Use a direct, professional, and slightly critical tone if the budget exceeds $500.

        IMPORTANT: Start your response with a JSON block between ---PREDICTIONS--- markers.
        The JSON MUST include triggers, anomalies, and combatPlan arrays.

        ---PREDICTIONS---
        {
          "projectedSpending": <number>,
          "savingsRate": <0-100>,
          "riskLevel": "<low/medium/high>",
          "weeklyTrend": "<accelerating/decelerating/stable>",
          "breakEvenDay": <day of month budget runs out, or null>,
          "categories": [{"name": "<cat>", "projected": <amount>}],
          "triggers": [
            {"pattern": "<trigger name>", "description": "<specific detail with $ and dates>", "amount": <total $>}
          ],
          "anomalies": [
            {"merchant": "<name>", "amount": <$>, "description": "<why this is abnormal>"}
          ],
          "combatPlan": [
            {"action": "<specific cut>", "savings": <$>, "reason": "<why and from where>"}
          ]
        }
        ---PREDICTIONS---

        Then write the full strategic report with ## headers:
        ## Monthly Outlook — Will the budget survive? Strategic assessment only.
        ## Trigger Analysis — Time-based spending patterns (late-night, weekend, payday).
        ## Anomaly Detection — Transactions that don't fit the profile. The "Budget Killers."
        ## Spending Psychology — 1-sentence behavioral profile. Impulse? Emotional? Subscription creep?
        ## Combat Plan — 3 aggressive, specific actions. Not "save more." Name the merchant, the amount, the math.
        ## Category Risks — Which categories breach budget and when.

        Every sentence must contain a dollar amount, percentage, or date. No generic advice.

        FINANCIAL CONTEXT:
        \(contextStr)
        """

        isStreamingAI = true
        var buffer = ""
        let stream = aiManager.stream(
            messages: [AIMessage(role: .user, content: prompt)],
            systemPrompt: systemPrompt
        )

        var lastUpdate = Date()
        var tokenCount = 0
        for await token in stream {
            buffer += token
            tokenCount += 1

            let now = Date()
            if now.timeIntervalSince(lastUpdate) > 0.1 {
                updateFromStream(buffer)
                lastUpdate = now
            }
        }

        log.info("Pipeline: stream finished, \(tokenCount) tokens, buffer length=\(buffer.count)")

        // Final parse — AI predictions override the fallback
        let cleaned = cleanModelOutput(buffer)
        let parsed = AIPredictionResult.parse(from: buffer, fallback: rawData)
            ?? fallbackAI

        aiAnalysisText = cleaned
        aiPredictions = parsed
        isStreamingAI = false
        log.info("Pipeline: complete")
    }

    /// Show fallback data immediately (no AI)
    private func showFallback(message: String) {
        let raw = AIPredictionEngine.compute(context: modelContext)
        predictionData = raw
        aiPredictions = AIPredictionResult.fallback(from: raw)
        aiAnalysisText = message
        phase = .ready
    }

    private func updateFromStream(_ buffer: String) {
        let cleaned = cleanModelOutput(buffer)
        aiAnalysisText = cleaned

        // Try to parse AI predictions as JSON block streams in (update once)
        if !aiParsedFromStream {
            if let parsed = AIPredictionResult.parse(from: buffer, fallback: predictionData) {
                withAnimation(CentmondTheme.Motion.default) {
                    aiPredictions = parsed
                    aiParsedFromStream = true
                }
            }
        }
    }

    private func cleanModelOutput(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "<|turn|>", with: "")
            .replacingOccurrences(of: "<end_of_turn>", with: "")

        // Remove the JSON predictions block from display text
        if let startRange = text.range(of: "---PREDICTIONS---"),
           let endRange = text.range(of: "---PREDICTIONS---", range: startRange.upperBound..<text.endIndex) {
            text.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        } else if let startRange = text.range(of: "---PREDICTIONS---") {
            // Partial — first marker found but not second (still streaming JSON block)
            text.removeSubrange(startRange.lowerBound..<text.endIndex)
        }
        // Handle partial marker tokens during streaming (e.g., "---PREDICT" at end)
        if let partial = text.range(of: "---PRED", options: .backwards),
           partial.upperBound == text.endIndex || text[partial.upperBound...].allSatisfy({ $0 == "-" || $0.isLetter }) {
            text.removeSubrange(partial.lowerBound..<text.endIndex)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Apply AI category predictions to base projections
    private func applyCategoryPredictions(base: [CategoryProjection], ai: [AICategoryPrediction]) -> [CategoryProjection] {
        base.map { cat in
            if let aiCat = ai.first(where: { $0.name.lowercased() == cat.name.lowercased() }) {
                return CategoryProjection(
                    name: cat.name,
                    icon: cat.icon,
                    colorHex: cat.colorHex,
                    spent: cat.spent,
                    budget: cat.budget,
                    projected: aiCat.projected,
                    trend: cat.trend
                )
            }
            return cat
        }
    }

    // MARK: - Compact Forecast Strip

    private func compactForecastStrip(_ forecast: MonthForecast, ai: AIPredictionResult) -> some View {
        let aiProjected = ai.projectedMonthlySpending
        let isOverBudget = forecast.totalBudget > 0 && aiProjected > forecast.totalBudget
        let delta = forecast.totalBudget - aiProjected
        let w = predictionData?.weeklyComparison
        let momChange = (predictionData?.lastMonthSpending ?? 0) > 0
            ? ((aiProjected - (predictionData?.lastMonthSpending ?? 0)) / (predictionData?.lastMonthSpending ?? 1)) * 100 : 0

        return HStack(spacing: CentmondTheme.Spacing.md) {
            // Left: Projected spending (primary number)
            HStack(spacing: CentmondTheme.Spacing.sm) {
                // Risk dot
                Circle()
                    .fill(riskColor(ai.riskLevel))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text("PROJECTED")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .tracking(0.5)
                    Text(CurrencyFormat.compact(Decimal(aiProjected)))
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(isOverBudget ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                // Delta badge
                if forecast.totalBudget > 0 {
                    let deltaAbs = abs(delta)
                    let isPositive = delta >= 0
                    Text("\(isPositive ? "-" : "+")\(CurrencyFormat.compact(Decimal(deltaAbs)))")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isPositive ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((isPositive ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            Spacer()

            // Right: Inline stat chips
            HStack(spacing: CentmondTheme.Spacing.sm) {
                chipStat("Spent", CurrencyFormat.compact(Decimal(forecast.spentSoFar)), CentmondTheme.Colors.negative)
                chipStat("Avg/Day", CurrencyFormat.compact(Decimal(forecast.dailyAverage)), CentmondTheme.Colors.accent)
                chipStat("Days Left", "\(forecast.daysLeft)", CentmondTheme.Colors.textPrimary)
                chipStat("Savings", "\(String(format: "%.0f", ai.savingsRate))%", ai.savingsRate > 10 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                chipStat("vs Last Mo", "\(String(format: "%+.0f", momChange))%", momChange <= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)

                if let weekChange = w, weekChange.lastWeekSpending > 0 {
                    let trendColor: Color = ai.weeklyTrend == "accelerating" ? CentmondTheme.Colors.negative : ai.weeklyTrend == "decelerating" ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary
                    chipStat("Trend", ai.weeklyTrend.prefix(5).capitalized + ".", trendColor)
                }
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    private func chipStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .tracking(0.3)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(CentmondTheme.Colors.bgTertiary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func riskColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "high": CentmondTheme.Colors.negative
        case "medium": CentmondTheme.Colors.warning
        default: CentmondTheme.Colors.positive
        }
    }

    // MARK: - AI Full Analysis Card

    private var aiAnalysisCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Image(systemName: "brain.head.profile.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.accent)

                    Text("Deep Analysis")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    if isAnalyzing {
                        HStack(spacing: CentmondTheme.Spacing.xs) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Gemma 4 analyzing...")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                        }
                    } else if !aiAnalysisText.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CentmondTheme.Colors.positive)
                    }
                }

                if aiAnalysisText.isEmpty && !isAnalyzing {
                    // Model not ready state
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "brain")
                            .font(.system(size: 24))
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        Text("AI model is not loaded. Load Gemma 4 in Settings to get predictions.")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CentmondTheme.Spacing.xxl)
                } else if aiAnalysisText.isEmpty && isAnalyzing {
                    // Loading skeleton
                    SkeletonLoader()
                        .padding(.vertical, CentmondTheme.Spacing.sm)
                } else {
                    // Scrollable AI text — card has fixed height, content scrolls
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            aiReportContent(aiAnalysisText)
                                .id("analysisBottom")
                        }
                        .onChange(of: aiAnalysisText) {
                            if isStreamingAI {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo("analysisBottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: deepAnalysisCardHeight)
    }

    @ViewBuilder
    private func aiReportContent(_ text: String) -> some View {
        let sections = text.components(separatedBy: "\n")

        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Spacer().frame(height: CentmondTheme.Spacing.sm)
                } else if trimmed.hasPrefix("## ") {
                    // Section header
                    Text(trimmed.replacingOccurrences(of: "## ", with: ""))
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .padding(.top, CentmondTheme.Spacing.sm)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    // Bullet point
                    HStack(alignment: .top, spacing: CentmondTheme.Spacing.xs) {
                        Circle()
                            .fill(CentmondTheme.Colors.accent)
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(trimmed.dropFirst(2))
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if trimmed.hasPrefix("#") {
                    // Any header
                    Text(trimmed.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces))
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .padding(.top, CentmondTheme.Spacing.xs)
                } else {
                    Text(trimmed)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Trigger Analysis Card

    private func triggerAnalysisCard(_ triggers: [AITrigger]) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.warning)

                    Text("Triggers")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }

                if isStreamingAI && !aiParsedFromStream {
                    SmallSkeletonLoader()
                } else if triggers.isEmpty {
                    Text("No triggers detected")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: CentmondTheme.Spacing.xs) {
                            ForEach(triggers) { trigger in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(trigger.pattern)
                                            .font(CentmondTheme.Typography.captionMedium)
                                            .foregroundStyle(CentmondTheme.Colors.warning)
                                            .lineLimit(1)

                                        Spacer()

                                        Text(CurrencyFormat.compact(Decimal(trigger.amount)))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(CentmondTheme.Colors.negative)
                                    }

                                    Text(trigger.description)
                                        .font(.system(size: 10))
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                        .lineLimit(2)
                                }
                                .padding(CentmondTheme.Spacing.xs)
                                .background(CentmondTheme.Colors.warning.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
                            }
                        }
                    }
                }
            }
        }
        .frame(height: intelligenceCardHeight)
    }

    // MARK: - Anomaly Detection Card

    private func anomalyDetectionCard(_ anomalies: [AIAnomaly]) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.negative)

                    Text("Anomalies")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }

                if isStreamingAI && !aiParsedFromStream {
                    SmallSkeletonLoader()
                } else if anomalies.isEmpty {
                    Text("No anomalies detected")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: CentmondTheme.Spacing.xs) {
                            ForEach(anomalies) { anomaly in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Image(systemName: "bolt.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(CentmondTheme.Colors.negative)

                                        Text(anomaly.merchant)
                                            .font(CentmondTheme.Typography.captionMedium)
                                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                            .lineLimit(1)

                                        Spacer()

                                        Text(CurrencyFormat.compact(Decimal(anomaly.amount)))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(CentmondTheme.Colors.negative)
                                    }

                                    Text(anomaly.description)
                                        .font(.system(size: 10))
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                        .lineLimit(2)
                                }
                                .padding(CentmondTheme.Spacing.xs)
                                .background(CentmondTheme.Colors.negative.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
                            }
                        }
                    }
                }
            }
        }
        .frame(height: intelligenceCardHeight)
    }

    // MARK: - Combat Plan Card

    private func combatPlanCard(_ actions: [AICombatAction]) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "target")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.positive)

                    Text("Combat Plan")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    if !actions.isEmpty {
                        let totalSavings = actions.reduce(0.0) { $0 + $1.savings }
                        Text("Save \(CurrencyFormat.compact(Decimal(totalSavings)))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CentmondTheme.Colors.positive)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(CentmondTheme.Colors.positive.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                if isStreamingAI && !aiParsedFromStream {
                    SmallSkeletonLoader()
                } else if actions.isEmpty {
                    Text("No savings actions found")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: CentmondTheme.Spacing.xs) {
                            ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
                                HStack(alignment: .top, spacing: CentmondTheme.Spacing.xs) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(CentmondTheme.Colors.positive)
                                        .frame(width: 16, height: 16)
                                        .background(CentmondTheme.Colors.positive.opacity(0.12))
                                        .clipShape(Circle())

                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack {
                                            Text(action.action)
                                                .font(CentmondTheme.Typography.captionMedium)
                                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                                .lineLimit(2)

                                            Spacer()

                                            Text("-\(CurrencyFormat.compact(Decimal(action.savings)))")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundStyle(CentmondTheme.Colors.positive)
                                        }

                                        Text(action.reason)
                                            .font(.system(size: 10))
                                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(CentmondTheme.Spacing.xs)
                                .background(CentmondTheme.Colors.positive.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
                            }
                        }
                    }
                }
            }
        }
        .frame(height: intelligenceCardHeight)
    }

    // MARK: - Top Merchants Card

    private func topMerchantsCard(_ merchants: [TopMerchant]) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Top Merchants")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                if merchants.isEmpty {
                    Text("No transactions this month")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        let maxAmount = merchants.first?.amount ?? 1
                        VStack(spacing: CentmondTheme.Spacing.sm) {
                            ForEach(merchants.prefix(6)) { merchant in
                                VStack(spacing: CentmondTheme.Spacing.xs) {
                                    HStack(spacing: CentmondTheme.Spacing.sm) {
                                        Text(merchant.name)
                                            .font(CentmondTheme.Typography.bodyMedium)
                                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                            .lineLimit(1)

                                        Text("\(merchant.txCount)x")
                                            .font(CentmondTheme.Typography.caption)
                                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                                        Spacer()

                                        Text(CurrencyFormat.compact(Decimal(merchant.amount)))
                                            .font(CentmondTheme.Typography.mono)
                                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                            .monospacedDigit()
                                    }

                                    // Mini bar
                                    GeometryReader { geo in
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(CentmondTheme.Colors.accent.opacity(0.2))
                                            .frame(width: geo.size.width * (merchant.amount / maxAmount), height: 3)
                                    }
                                    .frame(height: 3)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: dataCardHeight)
    }

    // MARK: - Account Health Card

    private func accountHealthCard(_ accounts: [AccountSnapshot]) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Account Health")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                if accounts.isEmpty {
                    Text("No active accounts")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: CentmondTheme.Spacing.xs) {
                            ForEach(accounts) { acct in
                                VStack(spacing: CentmondTheme.Spacing.xs) {
                                    HStack {
                                        Image(systemName: accountIcon(acct.type))
                                            .font(.system(size: 12))
                                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                            .frame(width: 20)

                                        Text(acct.name)
                                            .font(CentmondTheme.Typography.bodyMedium)
                                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                            .lineLimit(1)

                                        Text(acct.type)
                                            .font(CentmondTheme.Typography.caption)
                                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(CentmondTheme.Colors.bgTertiary)
                                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))

                                        Spacer()

                                        Text(CurrencyFormat.compact(Decimal(acct.balance)))
                                            .font(CentmondTheme.Typography.mono)
                                            .foregroundStyle(acct.balance >= 0 ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.negative)
                                            .monospacedDigit()
                                    }

                                    // Credit utilization bar
                                    if let util = acct.utilization, let limit = acct.creditLimit, limit > 0 {
                                        HStack(spacing: CentmondTheme.Spacing.xs) {
                                            GeometryReader { geo in
                                                ZStack(alignment: .leading) {
                                                    RoundedRectangle(cornerRadius: 2)
                                                        .fill(CentmondTheme.Colors.bgTertiary)
                                                        .frame(height: 4)
                                                    RoundedRectangle(cornerRadius: 2)
                                                        .fill(utilizationColor(util))
                                                        .frame(width: geo.size.width * min(util, 1.0), height: 4)
                                                }
                                            }
                                            .frame(height: 4)

                                            Text("\(String(format: "%.0f", util * 100))%")
                                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                .foregroundStyle(utilizationColor(util))
                                                .frame(width: 30)
                                        }
                                    }
                                }
                                .padding(.vertical, CentmondTheme.Spacing.xs)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: dataCardHeight)
    }

    private func accountIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "checking": return "building.columns"
        case "savings": return "banknote"
        case "creditcard": return "creditcard"
        case "investment": return "chart.line.uptrend.xyaxis"
        case "cash": return "dollarsign.circle"
        default: return "building.columns"
        }
    }

    private func utilizationColor(_ util: Double) -> Color {
        if util > 0.8 { return CentmondTheme.Colors.negative }
        if util > 0.5 { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.positive
    }

    // MARK: - Subscription Pressure Card

    private func subscriptionCard(_ sub: SubscriptionPressure) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Subscription Load")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                // Monthly / Annual
                HStack(spacing: CentmondTheme.Spacing.xxl) {
                    VStack(spacing: 2) {
                        Text("MONTHLY")
                            .font(CentmondTheme.Typography.overline)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.5)
                        Text(CurrencyFormat.compact(Decimal(sub.monthlyTotal)))
                            .font(CentmondTheme.Typography.monoLarge)
                            .foregroundStyle(CentmondTheme.Colors.accent)
                            .monospacedDigit()
                    }
                    VStack(spacing: 2) {
                        Text("ANNUAL")
                            .font(CentmondTheme.Typography.overline)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.5)
                        Text(CurrencyFormat.compact(Decimal(sub.annualTotal)))
                            .font(CentmondTheme.Typography.monoLarge)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .monospacedDigit()
                    }
                    VStack(spacing: 2) {
                        Text("ACTIVE")
                            .font(CentmondTheme.Typography.overline)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.5)
                        Text("\(sub.count)")
                            .font(CentmondTheme.Typography.monoLarge)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }
                }

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                // Next bill
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(CentmondTheme.Colors.warning)
                    Text("Next: \(sub.nextBillName)")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    Text(CurrencyFormat.compact(Decimal(sub.nextBillAmount)))
                        .font(CentmondTheme.Typography.mono)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                    Text(sub.nextBillDate.formatted(.dateTime.month(.abbreviated).day()))
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }
        }
        .frame(height: dataCardHeight)
    }

    /// Whether AI is currently streaming analysis
    private var isAnalyzing: Bool {
        isStreamingAI
    }

    // MARK: - Spending Trajectory Chart (Advanced)

    private func spendingTrajectoryChart(_ data: PredictionData, aiProjected: Double) -> some View {
        // Reshape trajectory to target AI's predicted end-of-month total
        let points: [SpendingDataPoint] = {
            let actual = data.spendingTrajectory.filter { !$0.isProjected }
            let projected = data.spendingTrajectory.filter { $0.isProjected }
            guard !projected.isEmpty else { return actual }

            let spentSoFar = actual.last?.amount ?? 0
            let remaining = max(0, aiProjected - spentSoFar)
            let projCount = Double(projected.count)
            let aiDailyAvg = projCount > 0 ? remaining / projCount : 0

            var cum = spentSoFar
            let reshaped: [SpendingDataPoint] = projected.enumerated().map { i, pt in
                let noise = sin(Double(i * 7 + projected.count)) * aiDailyAvg * 0.15
                cum += max(0, aiDailyAvg + noise)
                return SpendingDataPoint(date: pt.date, amount: cum, isProjected: true)
            }
            return actual + reshaped
        }()
        let bars = data.dailyBars
        let band = data.confidenceBand
        let forecast = data.forecast
        let daysPassed = forecast.daysPassed
        let breakEvenDay = aiPredictions?.breakEvenDay

        return CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                // Header + legend
                HStack {
                    Text("Spending Trajectory")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    HStack(spacing: CentmondTheme.Spacing.md) {
                        legendItem(color: CentmondTheme.Colors.accent, label: "Actual", dashed: false)
                        legendItem(color: CentmondTheme.Colors.accent.opacity(0.4), label: "Projected", dashed: true)
                        if forecast.totalBudget > 0 {
                            legendItem(color: CentmondTheme.Colors.negative.opacity(0.6), label: "Budget", dashed: true)
                        }
                        if breakEvenDay != nil {
                            legendItem(color: CentmondTheme.Colors.warning, label: "Break-even", dashed: false)
                        }
                    }
                }

                // Main chart
                ZStack(alignment: .topLeading) {
                    Chart {
                        // Layer 1: Daily spending bars
                        ForEach(bars) { bar in
                            BarMark(
                                x: .value("Day", bar.dayOfMonth),
                                y: .value("Amount", bar.amount)
                            )
                            .foregroundStyle(
                                bar.isProjected
                                    ? CentmondTheme.Colors.accent.opacity(hoveredDay == bar.dayOfMonth ? 0.25 : 0.12)
                                    : CentmondTheme.Colors.accent.opacity(hoveredDay == bar.dayOfMonth ? 0.6 : 0.35)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        }

                        // Layer 2: Confidence band (projected zone)
                        ForEach(band) { pt in
                            AreaMark(
                                x: .value("Day", dayForDate(pt.date)),
                                yStart: .value("Low", pt.low),
                                yEnd: .value("High", pt.high)
                            )
                            .foregroundStyle(CentmondTheme.Colors.accent.opacity(0.06))
                            .interpolationMethod(.monotone)
                        }

                        // Layer 3: Actual cumulative line
                        ForEach(points.filter({ !$0.isProjected })) { point in
                            LineMark(
                                x: .value("Day", dayForDate(point.date)),
                                y: .value("Cumulative", point.amount)
                            )
                            .foregroundStyle(CentmondTheme.Colors.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                        }

                        // Layer 4: Actual area fill under cumulative
                        ForEach(points.filter({ !$0.isProjected })) { point in
                            AreaMark(
                                x: .value("Day", dayForDate(point.date)),
                                y: .value("Cumulative", point.amount)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [CentmondTheme.Colors.accent.opacity(0.18), CentmondTheme.Colors.accent.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.monotone)
                        }

                        // Layer 5: Projected cumulative line (dashed, bridge from last actual)
                        let projectedBridge: [SpendingDataPoint] = {
                            let actual = points.filter { !$0.isProjected }
                            let projected = points.filter { $0.isProjected }
                            if let last = actual.last {
                                return [last] + projected
                            }
                            return projected
                        }()
                        ForEach(projectedBridge) { point in
                            LineMark(
                                x: .value("Day", dayForDate(point.date)),
                                y: .value("Cumulative", point.amount)
                            )
                            .foregroundStyle(CentmondTheme.Colors.accent.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                            .interpolationMethod(.monotone)
                        }

                        // Layer 6: Today marker
                        RuleMark(x: .value("Today", daysPassed))
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .center) {
                                Text("Today")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(CentmondTheme.Colors.bgTertiary)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }

                        // Layer 7: Budget line
                        if forecast.totalBudget > 0 {
                            RuleMark(y: .value("Budget", forecast.totalBudget))
                                .foregroundStyle(CentmondTheme.Colors.negative.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                                .annotation(position: .top, alignment: .trailing) {
                                    Text("Budget \(CurrencyFormat.compact(Decimal(forecast.totalBudget)))")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(CentmondTheme.Colors.negative.opacity(0.7))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(CentmondTheme.Colors.negativeMuted.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                        }

                        // Layer 8: Break-even marker (when budget runs out)
                        if let beDay = breakEvenDay {
                            RuleMark(x: .value("BreakEven", beDay))
                                .foregroundStyle(CentmondTheme.Colors.warning.opacity(0.8))
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 2]))
                                .annotation(position: .top, alignment: .center) {
                                    VStack(spacing: 1) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(CentmondTheme.Colors.warning)
                                        Text("Budget Out")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(CentmondTheme.Colors.warning)
                                        Text("Day \(beDay)")
                                            .font(.system(size: 7, weight: .medium))
                                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(CentmondTheme.Colors.warning.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                        }

                        // Layer 9: Hover vertical rule
                        if let day = hoveredDay {
                            RuleMark(x: .value("Hover", day))
                                .foregroundStyle(CentmondTheme.Colors.accent.opacity(0.6))
                                .lineStyle(StrokeStyle(lineWidth: 1))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                            AxisValueLabel {
                                if let val = value.as(Double.self) {
                                    Text(CurrencyFormat.abbreviated(val))
                                        .font(CentmondTheme.Typography.caption)
                                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                }
                            }
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.3))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: 5)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                                .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.15))
                            AxisValueLabel {
                                if let day = value.as(Int.self) {
                                    Text("\(day)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                }
                            }
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: true))
                    .chartLegend(.hidden)
                    .chartPlotStyle { plot in
                        plot.frame(minHeight: 340).padding(.horizontal, 4).clipped()
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        hoverLocation = location
                                        guard let plotFrameKey = proxy.plotFrame else {
                                            withAnimation(.easeOut(duration: 0.15)) { hoveredDay = nil }
                                            return
                                        }
                                        let plotFrame = geometry[plotFrameKey]
                                        let xInPlot = location.x - plotFrame.origin.x
                                        guard xInPlot >= 0, xInPlot <= plotFrame.width else {
                                            withAnimation(.easeOut(duration: 0.15)) { hoveredDay = nil }
                                            return
                                        }
                                        if let day: Int = proxy.value(atX: xInPlot) {
                                            let clamped = max(1, min(day, bars.count))
                                            withAnimation(.easeOut(duration: 0.1)) { hoveredDay = clamped }
                                        }
                                    case .ended:
                                        withAnimation(.easeOut(duration: 0.15)) { hoveredDay = nil }
                                    }
                                }
                        }
                    }

                    // Tooltip overlay
                    if let day = hoveredDay, let bar = bars.first(where: { $0.dayOfMonth == day }) {
                        trajectoryTooltip(bar: bar, cumulative: cumulativeAt(day: day, in: points), forecast: forecast)
                            .offset(x: tooltipX(day: day, barCount: bars.count), y: 8)
                            .transition(.opacity)
                            .animation(.easeOut(duration: 0.12), value: hoveredDay)
                    }
                }

                // Bottom explanation
                HStack(spacing: CentmondTheme.Spacing.md) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    Text("Bars show daily spending. Line tracks cumulative total. Shaded band shows projected confidence range ($\(String(format: "%.0f", forecast.dailyAverage))/day avg).")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
        }
    }

    // Chart helpers

    private func dayForDate(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.component(.day, from: date)
    }

    private func cumulativeAt(day: Int, in points: [SpendingDataPoint]) -> Double {
        let cal = Calendar.current
        if let match = points.last(where: { cal.component(.day, from: $0.date) <= day }) {
            return match.amount
        }
        return 0
    }

    private func tooltipX(day: Int, barCount: Int) -> CGFloat {
        // Position tooltip near hover point, clamped to avoid going off-screen
        let fraction = CGFloat(day) / CGFloat(max(barCount, 1))
        let offset = fraction * 600  // approximate chart width
        return min(max(offset - 80, 10), 450)
    }

    private func trajectoryTooltip(bar: DailySpendingBar, cumulative: Double, forecast: MonthForecast) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Date header
            Text(bar.date.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)

            if bar.isProjected {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9))
                    Text("Projected")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(CentmondTheme.Colors.accent.opacity(0.7))
            }

            Divider().opacity(0.25)

            // Day spending
            HStack(spacing: CentmondTheme.Spacing.xs) {
                Circle().fill(bar.isProjected ? CentmondTheme.Colors.accent.opacity(0.35) : CentmondTheme.Colors.accent).frame(width: 6, height: 6)
                Text("Day")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Spacer()
                Text(CurrencyFormat.standard(Decimal(bar.amount)))
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
            }

            // Cumulative
            HStack(spacing: CentmondTheme.Spacing.xs) {
                Circle().fill(CentmondTheme.Colors.accent).frame(width: 6, height: 6)
                Text("Total")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Spacer()
                Text(CurrencyFormat.standard(Decimal(cumulative)))
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
            }

            // Budget % if available
            if forecast.totalBudget > 0 {
                Divider().opacity(0.25)
                let pct = Int(cumulative / forecast.totalBudget * 100)
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Text("Budget used")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Spacer()
                    Text("\(pct)%")
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(pct > 100 ? CentmondTheme.Colors.negative : pct > 80 ? CentmondTheme.Colors.warning : CentmondTheme.Colors.positive)
                        .monospacedDigit()
                }
            }
        }
        .frame(width: 160)
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private func legendItem(color: Color, label: String, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            if dashed {
                // Dashed line indicator
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color)
                            .frame(width: 4, height: 2)
                    }
                }
                .frame(width: 16)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
    }

    // MARK: - Category Projections

    private func categoryProjectionsCard(_ categories: [CategoryProjection]) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Category Projections")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                if categories.isEmpty {
                    Text("No spending data this month yet")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: CentmondTheme.Spacing.xs) {
                            ForEach(categories.prefix(10)) { cat in
                                categoryRow(cat)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: dataCardHeight)
    }

    private func categoryRow(_ cat: CategoryProjection) -> some View {
        VStack(spacing: CentmondTheme.Spacing.xs) {
            HStack {
                Image(systemName: cat.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: cat.colorHex))
                    .frame(width: 24)

                Text(cat.name)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                Image(systemName: cat.trend.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(trendColor(cat.trend))

                Spacer()

                // Spent / Projected
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Text(CurrencyFormat.compact(Decimal(cat.spent)))
                        .font(CentmondTheme.Typography.mono)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()

                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)

                    Text(CurrencyFormat.compact(Decimal(cat.projected)))
                        .font(CentmondTheme.Typography.mono)
                        .foregroundStyle(projectedColor(cat))
                        .monospacedDigit()

                    if cat.budget > 0 {
                        Text("/ \(CurrencyFormat.compact(Decimal(cat.budget)))")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            .monospacedDigit()
                    }
                }
            }

            // Progress bar
            if cat.budget > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: 2)
                            .fill(CentmondTheme.Colors.bgTertiary)
                            .frame(height: 4)

                        // Projected (translucent, behind spent)
                        if cat.projectedRatio > cat.spentRatio {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(progressColor(cat).opacity(0.3))
                                .frame(width: geo.size.width * min(cat.projectedRatio, 1.0), height: 4)
                        }

                        // Spent (solid, on top)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(progressColor(cat))
                            .frame(width: geo.size.width * min(cat.spentRatio, 1.0), height: 4)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.vertical, CentmondTheme.Spacing.xs)
    }

    private func trendColor(_ trend: CategoryProjection.Trend) -> Color {
        switch trend {
        case .rising: CentmondTheme.Colors.negative
        case .falling: CentmondTheme.Colors.positive
        case .stable: CentmondTheme.Colors.textQuaternary
        }
    }

    private func projectedColor(_ cat: CategoryProjection) -> Color {
        if cat.budget > 0 && cat.projected > cat.budget {
            return CentmondTheme.Colors.negative
        }
        return CentmondTheme.Colors.textSecondary
    }

    private func progressColor(_ cat: CategoryProjection) -> Color {
        let ratio = cat.spentRatio
        if ratio > 1.0 { return CentmondTheme.Colors.negative }
        if ratio > 0.8 { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.accent
    }

}

// MARK: - Small Skeleton Loader (for intelligence cards)

private struct SmallSkeletonLoader: View {
    @State private var opacity = 0.3

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            smallSkeletonLine(width: 140)
            smallSkeletonLine(width: .infinity)
            smallSkeletonLine(width: 100)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(opacity)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: opacity)
        .onAppear { opacity = 0.7 }
    }

    private func smallSkeletonLine(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(CentmondTheme.Colors.bgTertiary)
            .frame(height: 10)
            .frame(maxWidth: width)
    }
}

// MARK: - Skeleton Loader

private struct SkeletonLoader: View {
    @State private var opacity = 0.3

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            skeletonLine(width: 180)
            skeletonLine(width: .infinity)
            skeletonLine(width: 320)
            skeletonLine(width: .infinity)
            skeletonLine(width: 240)
            skeletonLine(width: .infinity)
            skeletonLine(width: 280)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(opacity)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: opacity)
        .onAppear { opacity = 0.7 }
    }

    private func skeletonLine(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(CentmondTheme.Colors.bgTertiary)
            .frame(height: 12)
            .frame(maxWidth: width)
    }
}

// MARK: - Skeleton Card (loading placeholder)

private struct SkeletonCard: View {
    let height: CGFloat
    @State private var opacity = 0.3

    var body: some View {
        RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
            .fill(CentmondTheme.Colors.bgTertiary)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .opacity(opacity)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: opacity)
            .onAppear { opacity = 0.6 }
    }
}

