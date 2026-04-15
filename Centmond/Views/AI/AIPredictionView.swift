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

// MARK: - Persistent Cache for Prediction Results
//
// Stores the raw AI text for every range to disk so re-opening the
// AI Prediction page does NOT have to load Gemma 4 (~5 GB RAM) and
// re-stream every analysis. The model is unloaded immediately after
// the initial generation finishes; the disk cache is the source of
// truth on next launch until the user explicitly hits Refresh.
//
// Cache invalidates automatically when the underlying data changes
// (we hash the current month's spent + transaction count so adding,
// editing or importing transactions forces a re-analysis).

private struct PredictionCachePayload: Codable {
    var fingerprint: String           // data signature; mismatch = stale
    var generatedAt: Date
    var texts: [String: String]       // PredictionTimeRange.rawValue -> AI text
}

private enum PredictionCacheStore {
    private static var url: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("AIPredictionCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("predictions.json")
    }

    static func load() -> PredictionCachePayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PredictionCachePayload.self, from: data)
    }

    static func save(_ payload: PredictionCachePayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Fingerprint that changes whenever the user's spending data changes,
    /// so the cache invalidates on import / new tx / edit. We use the
    /// current month's spent total + recent transaction count + today's
    /// date — cheap and sufficient for "did the data move?".
    static func fingerprint(from raw: PredictionData) -> String {
        let spent = Int(raw.forecast.spentSoFar.rounded())
        let txs = raw.recentTransactions.count
        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        return "\(today)|spent:\(spent)|txs:\(txs)"
    }
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
    // Hover state for the trajectory chart lives inside
    // `TrajectoryHoverOverlay` (see end of file). Hoisting it here used to
    // invalidate this entire view body at ~60 Hz on hover and pegged CPU.
    @State private var chartMode: ChartMode = .trajectory
    @State private var committedActions: Set<UUID> = []       // Combat Plan committed actions
    @State private var hoveredTriggerDays: Set<Int> = []      // Trigger → chart bar highlight
    @State private var timeRange: PredictionTimeRange = .thisMonth  // Historical window the AI analyses

    // Per-range caches. Engine data is pre-computed upfront for ALL ranges
    // on first load (cheap — just SwiftData fetches). AI results stream in
    // the background and populate as each range completes, so switching
    // between ranges is an instant cache lookup with no model reload.
    @State private var rawDataByRange: [PredictionTimeRange: PredictionData] = [:]
    @State private var aiByRange: [PredictionTimeRange: AIPredictionResult] = [:]
    @State private var aiTextByRange: [PredictionTimeRange: String] = [:]
    @State private var streamingRange: PredictionTimeRange? = nil  // Range currently being streamed by Gemma
    @State private var loadedFromDiskCache = false                  // True when this view was hydrated from disk
    @State private var showRefreshConfirmation = false              // Drives the "load Gemma 4 again?" alert
    @State private var hasStartedPipeline = false                   // Guards .task from firing twice on view rebuild
    @State private var showJustFinishedBadge = false                // Capsule "Analysis ready" — auto-dismisses
    @State private var gradientPhase: CGFloat = 0                   // Drives moving gradient on Deep Analysis card

    enum ChartMode: String, CaseIterable {
        case trajectory = "Trajectory"
        case monthly = "Monthly"
        case hourly = "Hourly"
    }

    private let aiManager = AIManager.shared

    // MARK: - Card Height Constants
    private let dataCardHeight: CGFloat = 280

    var body: some View {
        ScrollView {
            if phase == .ready, let data = predictionData, let ai = aiPredictions {
                HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
                    // LEFT: main content column
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        // Row 0: Analysis window picker
                        timeRangePickerBar

                        // Row 1: Compact forecast strip
                        compactForecastStrip(data.forecast, ai: ai)

                        // Row 2: THE CHART
                        chartWithModeSwitcher(data: data, ai: ai)

                        // Row 3: Three intelligence cards side by side
                        HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
                            behavioralTriggersCard(ai.triggers)
                                .frame(maxWidth: .infinity, alignment: .top)
                            anomalyDetectionCard(ai.anomalies)
                                .frame(maxWidth: .infinity, alignment: .top)
                            interactiveCombatPlanCard(ai.combatPlan)
                                .frame(maxWidth: .infinity, alignment: .top)
                        }

                        // Row 4: Categories + Merchants
                        HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
                            categoryProjectionsCard(ai.categoryPredictions.isEmpty ? data.categoryProjections : applyCategoryPredictions(base: data.categoryProjections, ai: ai.categoryPredictions))
                            topMerchantsCard(data.topMerchants)
                        }

                        // Row 5: Accounts + Subscriptions
                        HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
                            accountHealthCard(data.accountSnapshots)
                            if let sub = data.subscriptionPressure {
                                subscriptionCard(sub)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // RIGHT: sidebar (stats + Deep Analysis)
                    VStack(spacing: CentmondTheme.Spacing.sm) {
                        sidebarStatsCards(data.forecast)
                        aiAnalysisCard
                    }
                    .frame(width: 340)
                }
                .padding(CentmondTheme.Spacing.sm)
                .environment(\.riskLevel, ai.riskLevel)
            } else {
                loadingPhaseContent
            }
        }
        .background(CentmondTheme.Colors.bgPrimary)
        .animation(CentmondTheme.Motion.layout, value: phase)
        .task {
            guard !hasStartedPipeline else { return }
            hasStartedPipeline = true
            await startPipeline()
        }
        .onChange(of: isAnalyzing) { wasAnalyzing, nowAnalyzing in
            // Transition from analyzing → done: show "Analysis ready" capsule
            // for ~4 s so the user notices the moment Gemma finishes.
            if wasAnalyzing && !nowAnalyzing && !aiAnalysisText.isEmpty {
                showJustFinishedBadge = true
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await MainActor.run {
                        withAnimation(CentmondTheme.Motion.default) {
                            showJustFinishedBadge = false
                        }
                    }
                }
            }
        }
        .alert("Re-analyze with Gemma 4?", isPresented: $showRefreshConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Load model & analyze", role: .destructive) {
                Task { await runRefresh() }
            }
        } message: {
            Text("""
            This will load Gemma 4 back into memory (~5 GB RAM) and re-run the full analysis across all 5 time ranges.

            Expect:
            • ~10–20 s to load the model
            • ~30–60 s of generation per range (5 ranges total)
            • Heavy CPU/GPU use throughout

            The model is unloaded automatically when the analysis finishes, and the new results are saved so the next visit is instant. Continue?
            """)
        }
        .onChange(of: timeRange) { _, newRange in
            // Instant cache swap. The pipeline pre-computed engine data for
            // every range, and AI streams populate in the background, so
            // changing the picker is just a dictionary lookup — no model
            // reload, no re-stream of the current view.
            applyCachedRange(newRange)
        }
    }

    // MARK: - Time Range Picker

    /// Horizontal segmented-style picker that drives the historical window
    /// fed to the engine. Changing this re-runs the whole pipeline.
    private var timeRangePickerBar: some View {
        HStack(spacing: CentmondTheme.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                Text("Analysis window")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(PredictionTimeRange.allCases) { range in
                    timeRangeChip(range)
                }
            }
            // Refresh moved into the Deep Analysis card header — it's the
            // affordance that re-runs the AI, so it lives next to where the
            // AI output is shown rather than the time-range picker.
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, CentmondTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(CentmondTheme.Colors.bgTertiary)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func timeRangeChip(_ range: PredictionTimeRange) -> some View {
        let isSelected = timeRange == range
        Button {
            if timeRange != range {
                timeRange = range
            }
        } label: {
            Text(range.rawValue)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(
                    isSelected
                        ? CentmondTheme.Colors.textPrimary
                        : CentmondTheme.Colors.textSecondary
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isSelected
                                ? CentmondTheme.Colors.accent.opacity(0.18)
                                : Color.clear
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    isSelected
                                        ? CentmondTheme.Colors.accent.opacity(0.55)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .help(range.rawValue)
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

    /// True while the pipeline is doing work that would conflict with a
    /// refresh trigger (loading model, computing data, or streaming AI).
    private var isPipelineActive: Bool {
        switch phase {
        case .loadingModel, .analyzingData: return true
        case .ready:
            return isStreamingAI || streamingRange != nil
        }
    }

    /// Force a full re-analysis: clear caches (memory + disk), re-load Gemma 4,
    /// re-stream every range. Called from the Refresh confirmation dialog.
    private func runRefresh() async {
        log.info("Pipeline: user-triggered refresh, clearing caches")
        PredictionCacheStore.clear()
        aiByRange.removeAll()
        aiTextByRange.removeAll()
        rawDataByRange.removeAll()
        loadedFromDiskCache = false
        aiPredictions = nil
        aiAnalysisText = ""
        phase = .loadingModel
        await startPipeline(forceModelLoad: true)
    }

    private func startPipeline(forceModelLoad: Bool = false) async {
        log.info("Pipeline: starting, aiManager.status = \(String(describing: aiManager.status)), forceLoad=\(forceModelLoad)")

        // Phase 0: Compute base data for every range FIRST. This is just
        // SwiftData fetches — no AI involved — and we need it both to
        // render the chart skeleton instantly and to fingerprint the disk
        // cache for validity.
        var allRaw: [PredictionTimeRange: PredictionData] = [:]
        for r in PredictionTimeRange.allCases {
            allRaw[r] = AIPredictionEngine.compute(context: modelContext, range: r)
        }
        rawDataByRange = allRaw
        guard let rawCurrent = allRaw[timeRange] else {
            log.error("Pipeline: no raw data for current range \(self.timeRange.rawValue)")
            showFallback(message: "Could not compute prediction data.")
            return
        }

        let fingerprint = PredictionCacheStore.fingerprint(from: rawCurrent)

        // Phase 0b: If a valid disk cache exists AND the user didn't force
        // a refresh, hydrate from it and skip the model entirely. This is
        // the "next time I open AI Prediction" fast path the user asked for.
        if !forceModelLoad,
           let cached = PredictionCacheStore.load(),
           cached.fingerprint == fingerprint {
            log.info("Pipeline: hydrated from disk cache (generated \(cached.generatedAt))")
            for (rangeKey, text) in cached.texts {
                guard let range = PredictionTimeRange(rawValue: rangeKey),
                      let raw = allRaw[range] else { continue }
                let cleaned = cleanModelOutput(text)
                let parsed = AIPredictionResult.parse(from: text, fallback: raw)
                    ?? AIPredictionResult.fallback(from: raw)
                aiByRange[range] = parsed
                aiTextByRange[range] = cleaned
            }
            // If every range is in the cache, we never need to touch Gemma.
            let allCached = PredictionTimeRange.allCases.allSatisfy { aiByRange[$0] != nil }
            if allCached {
                predictionData = rawCurrent
                aiPredictions = aiByRange[timeRange] ?? AIPredictionResult.fallback(from: rawCurrent)
                aiAnalysisText = aiTextByRange[timeRange] ?? ""
                loadedFromDiskCache = true
                phase = .ready
                log.info("Pipeline: ALL ranges served from cache, model NOT loaded")
                return
            }
        }

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

        // Phase 2: Raw data was already computed in Phase 0 — go straight
        // to ready with fallback predictions so UI is visible during streaming.
        log.info("Pipeline: Phase 2 — entering ready with fallback while AI streams")
        phase = .analyzingData
        let fallbackAI = AIPredictionResult.fallback(from: rawCurrent)
        predictionData = rawCurrent
        aiPredictions = fallbackAI
        loadedFromDiskCache = false
        phase = .ready
        log.info("Pipeline: phase = .ready, starting AI stream queue")

        // Phase 3: Stream AI for every range sequentially. The currently
        // viewed range is always streamed first; after each completion we
        // re-prioritize so if the user switched to an un-streamed range
        // mid-flight, that one runs next.
        await streamAllRanges(allRaw: allRaw)

        // Phase 4: Persist results to disk and unload Gemma 4 immediately.
        // The model has done its job — keeping it resident burns ~5 GB RAM
        // for nothing. The next visit will hydrate from the disk cache and
        // skip the model entirely until the user hits Refresh.
        persistCacheAndUnload(fingerprint: fingerprint)
    }

    /// Save every streamed range to disk and unload Gemma 4 to free RAM.
    /// The cached text is self-contained: cleaned markdown + a synthetic
    /// ---PREDICTIONS--- JSON block reconstructed from the parsed result,
    /// so on re-hydration we go through the same parser path as live
    /// streaming did.
    private func persistCacheAndUnload(fingerprint: String) {
        var rich: [String: String] = [:]
        for (range, parsed) in aiByRange {
            let cleaned = aiTextByRange[range] ?? ""
            rich[range.rawValue] = synthesizeCachedText(cleaned: cleaned, parsed: parsed)
        }
        let payload = PredictionCachePayload(
            fingerprint: fingerprint,
            generatedAt: Date(),
            texts: rich
        )
        PredictionCacheStore.save(payload)
        log.info("Pipeline: persisted \(rich.count) ranges to disk cache")

        aiManager.unloadModel()
        log.info("Pipeline: Gemma 4 unloaded after generation finished")
    }

    /// Build a self-contained text blob for the disk cache: the cleaned
    /// markdown body PLUS a ---PREDICTIONS--- JSON block reconstructed
    /// from the parsed `AIPredictionResult` so re-hydration goes through
    /// the same `AIPredictionResult.parse` path on next launch.
    private func synthesizeCachedText(cleaned: String, parsed: AIPredictionResult) -> String {
        let cats = parsed.categoryPredictions.map {
            ["name": $0.name, "projected": $0.projected] as [String: Any]
        }
        let trigs = parsed.triggers.map {
            ["pattern": $0.pattern, "description": $0.description, "amount": $0.amount] as [String: Any]
        }
        let anoms = parsed.anomalies.map {
            ["merchant": $0.merchant, "amount": $0.amount, "description": $0.description] as [String: Any]
        }
        let combat = parsed.combatPlan.map {
            ["action": $0.action, "savings": $0.savings, "reason": $0.reason] as [String: Any]
        }
        var json: [String: Any] = [
            "projectedSpending": parsed.projectedMonthlySpending,
            "savingsRate": parsed.savingsRate,
            "riskLevel": parsed.riskLevel,
            "weeklyTrend": parsed.weeklyTrend,
            "categories": cats,
            "triggers": trigs,
            "anomalies": anoms,
            "combatPlan": combat
        ]
        if let breakEven = parsed.breakEvenDay { json["breakEvenDay"] = breakEven }

        let jsonStr: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
                  let s = String(data: data, encoding: .utf8) else { return "{}" }
            return s
        }()

        return "---PREDICTIONS---\n\(jsonStr)\n---PREDICTIONS---\n\n\(cleaned)"
    }

    /// Run a SINGLE Gemma generation for the user's current range, then
    /// broadcast its behavioral insights (triggers / anomalies / combat
    /// plan / weekly trend) to every other range — recombining them with
    /// per-range numerics derived from each range's raw data.
    ///
    /// Why this isn't 5 parallel streams: llama.cpp owns one model + one
    /// context. Two simultaneous generations on the same context would
    /// serialize on the actor and produce no speedup (and we can't afford
    /// 5× the RAM to run 5 model instances). Behavioral patterns are a
    /// property of the user's spending, not the analysis window — so one
    /// generation is enough; only the forecast numerics differ per range,
    /// and those come from the engine's pure-math `fallback(from:)`.
    private func streamAllRanges(allRaw: [PredictionTimeRange: PredictionData]) async {
        // Anchor the generation on whichever range the user is currently
        // viewing — that way the streaming card they're staring at fills
        // in live, not silently in the background.
        let primary = timeRange
        guard let primaryRaw = allRaw[primary] else {
            log.error("Pipeline: no raw data for primary range \(primary.rawValue)")
            return
        }

        if aiByRange[primary] == nil {
            log.info("Pipeline: streaming PRIMARY range=\(primary.rawValue) with multi-window prompt — same text broadcast to all ranges, per-range numerics from fallback")
            await streamAI(for: primary, rawData: primaryRaw, allRaw: allRaw)
        }

        guard let primaryAI = aiByRange[primary] else {
            log.warning("Pipeline: primary stream failed; other ranges will use rule-based fallback")
            for range in PredictionTimeRange.allCases where range != primary {
                if aiByRange[range] == nil, let raw = allRaw[range] {
                    aiByRange[range] = AIPredictionResult.fallback(from: raw)
                    aiTextByRange[range] = ""
                }
            }
            return
        }

        // Broadcast: for every other range, build a result that combines
        // the primary's behavioral insights with the range's own numerics.
        for range in PredictionTimeRange.allCases where range != primary {
            guard aiByRange[range] == nil, let raw = allRaw[range] else { continue }
            let fb = AIPredictionResult.fallback(from: raw)
            let merged = AIPredictionResult(
                projectedMonthlySpending: fb.projectedMonthlySpending,
                savingsRate: fb.savingsRate,
                riskLevel: fb.riskLevel,
                weeklyTrend: primaryAI.weeklyTrend,
                categoryPredictions: fb.categoryPredictions,
                breakEvenDay: fb.breakEvenDay,
                triggers: primaryAI.triggers,
                anomalies: primaryAI.anomalies,
                combatPlan: primaryAI.combatPlan
            )
            aiByRange[range] = merged
            aiTextByRange[range] = aiTextByRange[primary] ?? ""
            log.info("Pipeline: broadcast AI insights to range=\(range.rawValue)")

            // If the user switched to this range mid-broadcast, refresh display.
            if range == timeRange {
                aiPredictions = merged
                aiAnalysisText = aiTextByRange[range] ?? ""
                isStreamingAI = false
            }
        }
        log.info("Pipeline: all ranges populated (1 generation + 4 broadcasts)")
    }

    /// Stream a single range's AI analysis and cache the result. Live token
    /// updates flow to the UI only while the user is still viewing this
    /// range; if they switch mid-stream, the buffer keeps building silently
    /// and the final parse is cached for instant recall later.
    private func streamAI(for range: PredictionTimeRange, rawData: PredictionData, allRaw: [PredictionTimeRange: PredictionData]? = nil) async {
        log.info("Pipeline: streaming AI for range=\(range.rawValue) (multiWindow=\(allRaw != nil))")
        streamingRange = range
        if range == timeRange {
            isStreamingAI = true
        }

        // If we have all 5 windows of raw data, use the multi-window prompt so
        // Gemma writes a single report covering every timeframe — every
        // paragraph tagged with [This Month] / [Last Month] / etc. The view
        // renders those tags as inline capsules. If only single-range data is
        // available, fall back to the legacy single-window prompt.
        let prompt: String
        if let allRaw = allRaw, allRaw.count >= 2 {
            prompt = AIPredictionEngine.buildMultiRangeAnalysisPrompt(allData: allRaw)
        } else {
            prompt = AIPredictionEngine.buildAnalysisPrompt(data: rawData)
        }
        // NOTE: AIContextBuilder.build(...) is intentionally NOT included
        // here. It duplicates ~70% of what the prompt builder already
        // contains (forecast, categories, accounts, merchants).
        let systemPrompt = """
        You are a Financial Strategist and Behavioral Psychologist analyzing spending across multiple time windows.
        Find the WHY, not the WHAT. Be brutally honest. Surface what is HIDDEN.

        CRITICAL: every paragraph in the report MUST start with one of these exact bracketed window tags:
        [This Month] [Last Month] [Last 3 Months] [Last 6 Months] [Last Year]
        Compare windows where it strengthens an insight. Do NOT write a paragraph without a tag.

        Start with a JSON block between ---PREDICTIONS--- markers (numerics describe THIS MONTH).

        ---PREDICTIONS---
        {
          "projectedSpending": <number>,
          "savingsRate": <0-100>,
          "riskLevel": "<low/medium/high>",
          "weeklyTrend": "<accelerating/decelerating/stable>",
          "breakEvenDay": <day or null>,
          "categories": [{"name": "<cat>", "projected": <amount>}],
          "triggers": [{"pattern": "<name>", "description": "<detail>", "amount": <$>}],
          "anomalies": [{"merchant": "<name>", "amount": <$>, "description": "<why>"}],
          "combatPlan": [{"action": "<cut>", "savings": <$>, "reason": "<why>"}]
        }
        ---PREDICTIONS---

        Then write the full report with these ## headers in order:
        ## Monthly Outlook
        ## Trigger Analysis
        ## Anomaly Detection
        ## Spending Psychology
        ## Combat Plan
        ## Category Risks

        Every sentence must contain a dollar amount, percentage, or date. No generic advice.
        """

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
            // CPU note: 0.25s = 4 UI ticks/sec is plenty for a streaming
            // markdown blob. Going faster forces SwiftUI to re-diff the
            // whole report (potentially hundreds of paragraphs + capsules)
            // many times per second while llama.cpp is already saturating
            // the perf cores — main thread became the bottleneck at 0.1s.
            if now.timeIntervalSince(lastUpdate) > 0.25 {
                // Only push live updates if the user is still viewing this
                // range. Background streams build their buffer silently.
                if range == timeRange {
                    updateFromStream(buffer)
                }
                lastUpdate = now
            }
        }

        log.info("Pipeline: stream finished for \(range.rawValue), \(tokenCount) tokens, buffer length=\(buffer.count)")

        // Final parse + cache. AI predictions override the fallback.
        let cleaned = cleanModelOutput(buffer)
        let parsed = AIPredictionResult.parse(from: buffer, fallback: rawData)
            ?? AIPredictionResult.fallback(from: rawData)

        aiByRange[range] = parsed
        aiTextByRange[range] = cleaned

        // Push to UI only if the user is still on this range. Otherwise the
        // result waits in the cache for an instant swap on next selection.
        if range == timeRange {
            aiAnalysisText = cleaned
            aiPredictions = parsed
            isStreamingAI = false
        }
        if streamingRange == range { streamingRange = nil }
        log.info("Pipeline: cached AI for \(range.rawValue)")
    }

    /// Swap the displayed range from the per-range caches. Falls back to a
    /// rule-based prediction if the AI hasn't finished streaming for this
    /// range yet — once it does, the result will be cached and visible the
    /// next time the user picks it.
    private func applyCachedRange(_ range: PredictionTimeRange) {
        aiParsedFromStream = false  // reset so streaming can re-update if we revisit a still-streaming range
        guard let raw = rawDataByRange[range] else {
            log.warning("applyCachedRange: no raw data cached for \(range.rawValue)")
            return
        }
        predictionData = raw
        if let cached = aiByRange[range] {
            aiPredictions = cached
            aiAnalysisText = aiTextByRange[range] ?? ""
            isStreamingAI = false
        } else {
            // Not streamed yet — show fallback while background queue catches up.
            aiPredictions = AIPredictionResult.fallback(from: raw)
            aiAnalysisText = ""
            isStreamingAI = (streamingRange == range)
        }
    }

    /// Show fallback data immediately (no AI)
    private func showFallback(message: String) {
        let raw = AIPredictionEngine.compute(context: modelContext, range: timeRange)
        predictionData = raw
        rawDataByRange[timeRange] = raw
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

    // MARK: - Sidebar Stat Cards (Income / Expenses)

    private func sidebarStatsCards(_ forecast: MonthForecast) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            // INCOME card
            let incomePct = forecast.expectedIncome > 0
                ? (forecast.incomeReceived / forecast.expectedIncome) * 100
                : 0
            sidebarStatCard(
                label: "INCOME",
                percent: incomePct,
                amount: forecast.incomeReceived,
                actionLabel: incomePct >= 95 ? "No actions needed" : "Track inflow",
                tint: CentmondTheme.Colors.positive,
                isPositive: true
            )

            // EXPENSES card
            let budgetPct = forecast.totalBudget > 0
                ? (forecast.spentSoFar / forecast.totalBudget) * 100
                : 0
            sidebarStatCard(
                label: "EXPENSES",
                percent: budgetPct,
                amount: forecast.spentSoFar,
                actionLabel: budgetPct > 80 ? "Explore ideas" : "On track",
                tint: CentmondTheme.Colors.warning,
                isPositive: false
            )
        }
    }

    private func sidebarStatCard(label: String, percent: Double, amount: Double, actionLabel: String, tint: Color, isPositive: Bool) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.8)

            Text(String(format: "%@%.2f%%", isPositive ? "+" : "+", percent))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()

            Text(CurrencyFormat.standard(Decimal(amount)))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(tint.opacity(0.8))
                .monospacedDigit()

            Spacer(minLength: CentmondTheme.Spacing.sm)

            Text(actionLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CentmondTheme.Spacing.md)
        .frame(height: 140)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
    }

    private var aiAnalysisCard: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            HStack(spacing: CentmondTheme.Spacing.xs) {
                Image(systemName: "brain.head.profile.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(CentmondTheme.Colors.accent)

                Text("Deep Analysis")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                Spacer()

                // Status: analyzing pulse → just-finished capsule → checkmark
                if isAnalyzing {
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        ProgressView()
                            .scaleEffect(0.55)
                        Text("Gemma 4 analyzing…")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.accent)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if showJustFinishedBadge {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Analysis ready")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(CentmondTheme.Colors.positive)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(CentmondTheme.Colors.positive.opacity(0.15))
                    )
                    .overlay(
                        Capsule()
                            .stroke(CentmondTheme.Colors.positive.opacity(0.45), lineWidth: 1)
                    )
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else if !aiAnalysisText.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(CentmondTheme.Colors.positive)
                }

                // Refresh — re-loads Gemma 4 and re-streams the analysis.
                // Confirmation alert details the RAM + time cost. Disabled
                // while a pipeline run is already active so the user can't
                // double-trigger a generation.
                Button {
                    showRefreshConfirmation = true
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(
                            isPipelineActive
                                ? CentmondTheme.Colors.textTertiary
                                : CentmondTheme.Colors.accent
                        )
                        .padding(6)
                        .background(
                            Circle()
                                .fill(
                                    isPipelineActive
                                        ? Color.clear
                                        : CentmondTheme.Colors.accent.opacity(0.12)
                                )
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    isPipelineActive
                                        ? CentmondTheme.Colors.strokeSubtle
                                        : CentmondTheme.Colors.accent.opacity(0.35),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(isPipelineActive)
                .help(loadedFromDiskCache
                      ? "Re-analyze with Gemma 4 (heavy — loads model)"
                      : "Re-analyze with Gemma 4 (heavy — re-loads model)")
            }
            .animation(CentmondTheme.Motion.default, value: isAnalyzing)
            .animation(CentmondTheme.Motion.default, value: showJustFinishedBadge)

            if aiAnalysisText.isEmpty && !isAnalyzing {
                    // Model truly not ready state (download missing / load
                    // failure). Queued ranges are reported via isAnalyzing
                    // so they take the loading skeleton branch below.
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
                // Full AI text — card expands with page scroll, sidebar matches left column height
                aiReportContent(aiAnalysisText)
            }
        }
        .padding(CentmondTheme.Spacing.lg)
        .background(deepAnalysisCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .stroke(
                    isAnalyzing
                        ? CentmondTheme.Colors.accent.opacity(0.55)
                        : CentmondTheme.Colors.strokeDefault,
                    lineWidth: isAnalyzing ? 1.5 : 1
                )
                .animation(CentmondTheme.Motion.default, value: isAnalyzing)
        )
        .shadow(
            color: isAnalyzing
                ? CentmondTheme.Colors.accent.opacity(0.35)
                : .black.opacity(0.15),
            radius: isAnalyzing ? 14 : 4,
            y: 2
        )
        .animation(CentmondTheme.Motion.default, value: isAnalyzing)
    }

    /// Background for the Deep Analysis card. While Gemma is generating it
    /// shows an animated accent → purple gradient that drifts diagonally
    /// (driven by `gradientPhase` via TimelineView so it doesn't fight
    /// SwiftUI's view diff cycle). When idle it's the standard card fill.
    @ViewBuilder
    private var deepAnalysisCardBackground: some View {
        if isAnalyzing {
            // CPU note: phase oscillates with period ~7s, so even 4-5 fps
            // looks smooth. Was 0.05s (20 fps) which alone burned ~10-15%
            // CPU on a large gradient + stroke + shadow surface.
            TimelineView(.animation(minimumInterval: 0.2)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = CGFloat((sin(t * 0.9) + 1) / 2)  // 0 → 1 → 0 every ~7 s
                ZStack {
                    CentmondTheme.Colors.bgSecondary
                    LinearGradient(
                        colors: [
                            CentmondTheme.Colors.accent.opacity(0.28),
                            Color(red: 0.55, green: 0.36, blue: 0.96).opacity(0.22),
                            CentmondTheme.Colors.accent.opacity(0.18)
                        ],
                        startPoint: UnitPoint(x: phase, y: 0),
                        endPoint: UnitPoint(x: 1 - phase, y: 1)
                    )
                }
            }
        } else {
            CentmondTheme.Colors.bgSecondary
        }
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
                    // Bullet point — strip leading bullet, then capsule-ify
                    HStack(alignment: .top, spacing: CentmondTheme.Spacing.xs) {
                        Circle()
                            .fill(CentmondTheme.Colors.accent)
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        taggedParagraph(String(trimmed.dropFirst(2)))
                    }
                } else if trimmed.hasPrefix("#") {
                    // Any header
                    Text(trimmed.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces))
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .padding(.top, CentmondTheme.Spacing.xs)
                } else {
                    taggedParagraph(trimmed)
                }
            }
        }
    }

    /// Render a paragraph that may begin with a `[Window Name]` tag
    /// (e.g. `[This Month] You spent $...`). Recognised tags are replaced by
    /// inline coloured capsules; the remaining text flows next to them.
    @ViewBuilder
    private func taggedParagraph(_ paragraph: String) -> some View {
        let parts = extractWindowTags(paragraph)
        if parts.tags.isEmpty {
            Text(paragraph)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: CentmondTheme.Spacing.xs) {
                ForEach(Array(parts.tags.enumerated()), id: \.offset) { _, tag in
                    rangeCapsule(tag)
                }
                Text(parts.body)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Strip leading `[Window]` tag(s) from a paragraph; return the matched
    /// tags plus the remaining text. Only the canonical 5 window names are
    /// recognised — anything else is left untouched in the body.
    private func extractWindowTags(_ s: String) -> (tags: [PredictionTimeRange], body: String) {
        var remaining = s
        var tags: [PredictionTimeRange] = []
        let known = PredictionTimeRange.allCases
        while true {
            let trimmed = remaining.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { break }
            guard let close = trimmed.firstIndex(of: "]") else { break }
            let inside = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard let match = known.first(where: { $0.rawValue.caseInsensitiveCompare(inside) == .orderedSame }) else { break }
            tags.append(match)
            remaining = String(trimmed[trimmed.index(after: close)...])
        }
        return (tags, remaining.trimmingCharacters(in: .whitespaces))
    }

    private func rangeCapsule(_ range: PredictionTimeRange) -> some View {
        let color = capsuleColor(for: range)
        return Text(range.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .overlay(
                Capsule().stroke(color.opacity(0.35), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }

    private func capsuleColor(for range: PredictionTimeRange) -> Color {
        switch range {
        case .thisMonth:    return CentmondTheme.Colors.accent
        case .lastMonth:    return Color(red: 0.55, green: 0.36, blue: 0.96)  // violet
        case .last3Months:  return CentmondTheme.Colors.warning
        case .last6Months:  return CentmondTheme.Colors.positive
        case .lastYear:     return CentmondTheme.Colors.negative
        }
    }

    // MARK: - Behavioral Triggers Card (Icon-Rich)

    private func behavioralTriggersCard(_ triggers: [AITrigger]) -> some View {
        RiskCardContainer(riskLevel: aiPredictions?.riskLevel ?? "medium") {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "brain.head.profile.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.warning)

                    Text("Behavioral Patterns")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    if !triggers.isEmpty {
                        Text("\(triggers.count) found")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(CentmondTheme.Colors.warning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(CentmondTheme.Colors.warning.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                if isStreamingAI && !aiParsedFromStream {
                    SmallSkeletonLoader()
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
                } else if triggers.isEmpty {
                    Text("No behavioral triggers detected")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                } else {
                    VStack(spacing: CentmondTheme.Spacing.xs) {
                        ForEach(triggers) { trigger in
                            behavioralTriggerCard(trigger)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
                }
            }
        }
    }

    private func behavioralTriggerCard(_ trigger: AITrigger) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(CentmondTheme.Colors.warning.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: triggerIcon(for: trigger.pattern))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(CentmondTheme.Colors.warning)
            }

            Text(trigger.pattern)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            Text(CurrencyFormat.compact(Decimal(trigger.amount)))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(CentmondTheme.Colors.warning)
                .monospacedDigit()
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.warning.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredTriggerDays = extractDays(from: trigger.description)
            } else {
                hoveredTriggerDays = []
            }
        }
    }

    /// Extract day-of-month numbers from trigger description text (e.g. "April 13th" → 13)
    private func extractDays(from text: String) -> Set<Int> {
        var days = Set<Int>()
        // Match patterns like "April 13th", "April 4th", "13th", "22nd", "1st"
        let regex = try? NSRegularExpression(pattern: #"(\d{1,2})(?:st|nd|rd|th)"#)
        let matches = regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        for match in matches {
            if let range = Range(match.range(at: 1), in: text), let day = Int(text[range]) {
                days.insert(day)
            }
        }
        return days
    }

    /// Maps trigger pattern text to a contextual SF Symbol
    private func triggerIcon(for pattern: String) -> String {
        let lower = pattern.lowercased()
        if lower.contains("night") || lower.contains("late") || lower.contains("midnight") {
            return "moon.fill"
        } else if lower.contains("weekend") || lower.contains("saturday") || lower.contains("sunday") {
            return "calendar.badge.clock"
        } else if lower.contains("impulse") || lower.contains("quick") || lower.contains("small") {
            return "bolt.fill"
        } else if lower.contains("morning") || lower.contains("breakfast") || lower.contains("coffee") {
            return "sunrise.fill"
        } else if lower.contains("food") || lower.contains("dining") || lower.contains("restaurant") || lower.contains("pizza") || lower.contains("delivery") {
            return "fork.knife"
        } else if lower.contains("subscription") || lower.contains("recurring") || lower.contains("monthly") {
            return "repeat"
        } else if lower.contains("stress") || lower.contains("emotional") || lower.contains("boredom") {
            return "heart.slash.fill"
        } else if lower.contains("payday") || lower.contains("salary") || lower.contains("income") {
            return "banknote.fill"
        } else if lower.contains("shopping") || lower.contains("retail") || lower.contains("store") {
            return "bag.fill"
        } else if lower.contains("transport") || lower.contains("uber") || lower.contains("gas") || lower.contains("fuel") {
            return "car.fill"
        }
        return "exclamationmark.triangle.fill"
    }

    // MARK: - Anomaly Detection Card

    private func anomalyDetectionCard(_ anomalies: [AIAnomaly]) -> some View {
        RiskCardContainer(riskLevel: aiPredictions?.riskLevel ?? "medium") {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
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
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
                } else if anomalies.isEmpty {
                    Text("No anomalies detected")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                } else {
                    VStack(spacing: CentmondTheme.Spacing.xs) {
                        ForEach(anomalies) { anomaly in
                            HStack(spacing: CentmondTheme.Spacing.md) {
                                ZStack {
                                    Circle()
                                        .fill(CentmondTheme.Colors.negative.opacity(0.12))
                                        .frame(width: 38, height: 38)
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(CentmondTheme.Colors.negative)
                                }

                                Text(anomaly.merchant)
                                    .font(CentmondTheme.Typography.bodyMedium)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                    .lineLimit(1)

                                Spacer()

                                Text(CurrencyFormat.compact(Decimal(anomaly.amount)))
                                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                                    .foregroundStyle(CentmondTheme.Colors.negative)
                            }
                            .padding(.horizontal, CentmondTheme.Spacing.md)
                            .padding(.vertical, CentmondTheme.Spacing.md)
                            .background(CentmondTheme.Colors.negative.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
                }
            }
        }
    }

    // MARK: - Combat Plan Card (Warning Tone)

    private func interactiveCombatPlanCard(_ actions: [AICombatAction]) -> some View {
        RiskCardContainer(riskLevel: aiPredictions?.riskLevel ?? "high") {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.warning)

                    Text("Combat Plan")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Spacer()

                    if !actions.isEmpty {
                        let totalSavings = actions.reduce(0.0) { $0 + $1.savings }
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 9))
                            Text("Cut \(CurrencyFormat.compact(Decimal(totalSavings)))")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(CentmondTheme.Colors.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CentmondTheme.Colors.warning.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                if isStreamingAI && !aiParsedFromStream {
                    SmallSkeletonLoader()
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
                } else if actions.isEmpty {
                    Text("No critical actions identified")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                } else {
                    VStack(spacing: CentmondTheme.Spacing.xs) {
                        ForEach(actions) { action in
                            let isCommitted = committedActions.contains(action.id)
                            let tint: Color = isCommitted ? CentmondTheme.Colors.positive : CentmondTheme.Colors.warning
                            Button {
                                withAnimation(CentmondTheme.Motion.default) {
                                    if isCommitted { committedActions.remove(action.id) }
                                    else { committedActions.insert(action.id) }
                                }
                            } label: {
                                HStack(spacing: CentmondTheme.Spacing.md) {
                                    ZStack {
                                        Circle()
                                            .fill(tint.opacity(0.14))
                                            .frame(width: 38, height: 38)
                                        Image(systemName: isCommitted ? "checkmark.circle.fill" : "arrow.down.right.circle.fill")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(tint)
                                    }

                                    Text(action.action)
                                        .font(CentmondTheme.Typography.bodyMedium)
                                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                        .lineLimit(1)
                                        .strikethrough(isCommitted, color: CentmondTheme.Colors.textTertiary)

                                    Spacer()

                                    Text("-\(CurrencyFormat.compact(Decimal(action.savings)))")
                                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                                        .foregroundStyle(tint)
                                        .monospacedDigit()
                                }
                                .padding(.horizontal, CentmondTheme.Spacing.md)
                                .padding(.vertical, CentmondTheme.Spacing.md)
                                .background(tint.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
                }
            }
        }
    }

    // MARK: - Monthly Overview Chart (Stacked Bar)

    private func monthlyOverviewChart(_ months: [MonthlySpendingData], budget: Double) -> some View {
        // Income = vivid blue-purple (actual) vs muted version (projected)
        let incomeActual = Color(red: 0.42, green: 0.39, blue: 0.96)
        let incomeProjected = CentmondTheme.Colors.projected                       // violet
        // Expenses = light lavender (actual) vs stronger violet outline (projected)
        let expenseActual = Color(red: 0.78, green: 0.75, blue: 0.99)
        let expenseProjected = CentmondTheme.Colors.projected.opacity(0.45)

        // Per-month budget palette — rotating distinct colours so each
        // month's budget line is visually separable in multi-month windows.
        // Skip months with budget == 0 (no MonthlyTotalBudget set for that month).
        let budgetMonths = months.filter { $0.budget > 0 }
        let showBudgetLegend = budgetMonths.count > 1

        // Find the forecast zone span for the background wash
        let firstProjectedLabel: String? = months.first(where: { $0.isFuture })?.monthLabel
        let lastLabel: String? = months.last?.monthLabel

        return CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                // Header
                HStack(spacing: CentmondTheme.Spacing.md) {
                    Text("Revenue Report")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    // Legend dots — 4 states
                    HStack(spacing: CentmondTheme.Spacing.md) {
                        HStack(spacing: 5) {
                            Circle().fill(incomeActual).frame(width: 7, height: 7)
                            Text("Income")
                                .font(.system(size: 11))
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        }
                        HStack(spacing: 5) {
                            Circle().fill(expenseActual).frame(width: 7, height: 7)
                            Text("Expenses")
                                .font(.system(size: 11))
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        }
                        HStack(spacing: 5) {
                            Circle()
                                .strokeBorder(CentmondTheme.Colors.projected, lineWidth: 1.5)
                                .frame(width: 7, height: 7)
                            Text("Projected")
                                .font(.system(size: 11))
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        }
                    }

                    Spacer()

                    // Period pill (placeholder — full year)
                    HStack(spacing: 4) {
                        Text("Year")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(CentmondTheme.Colors.bgTertiary.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
                    .padding(.trailing, 110) // reserve space for floating chart-mode switcher
                }

                // Grouped bar chart — Income + Expenses side-by-side per month.
                // Current month's expenses stack actual (solid) + forecast (violet) so you see
                // how much of the month is already spent vs predicted. Future months are
                // fully violet. Past months are fully solid.
                Chart {
                    // Layer 0: forecast-zone violet wash from first future month to end of year
                    if let startLabel = firstProjectedLabel, let endLabel = lastLabel {
                        RectangleMark(
                            xStart: .value("Start", startLabel),
                            xEnd: .value("End", endLabel)
                        )
                        .foregroundStyle(CentmondTheme.Colors.projected.opacity(0.07))
                    }

                    ForEach(months) { m in
                        // ---- Income bar ----
                        // Actual portion (solid blue-purple)
                        if m.income > 0 && !m.isFuture {
                            BarMark(
                                x: .value("Month", m.monthLabel),
                                y: .value("Amount", m.income),
                                width: .ratio(0.42)
                            )
                            .foregroundStyle(incomeActual)
                            .position(by: .value("Series", "Income"))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        // Projected income for future months (violet, lower opacity)
                        if m.isFuture && m.income > 0 {
                            BarMark(
                                x: .value("Month", m.monthLabel),
                                y: .value("Amount", m.income),
                                width: .ratio(0.42)
                            )
                            .foregroundStyle(incomeProjected.opacity(0.55))
                            .position(by: .value("Series", "Income"))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        // ---- Expenses bar ----
                        // Actual portion (solid lavender) — past months + current month spent
                        if m.actual > 0 {
                            BarMark(
                                x: .value("Month", m.monthLabel),
                                yStart: .value("Start", 0),
                                yEnd: .value("End", m.actual),
                                width: .ratio(0.42)
                            )
                            .foregroundStyle(expenseActual)
                            .position(by: .value("Series", "Expenses"))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        // Forecast portion — stacked on top of actual (current month) or full bar (future)
                        if m.forecast > 0 {
                            BarMark(
                                x: .value("Month", m.monthLabel),
                                yStart: .value("Start", m.actual),
                                yEnd: .value("End", m.actual + m.forecast),
                                width: .ratio(0.42)
                            )
                            .foregroundStyle(expenseProjected)
                            .position(by: .value("Series", "Expenses"))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        // Per-month budget rule — short coloured bar at the budget
                        // level for THIS month only. Spans the bar group (~92%
                        // ratio) so it visually caps the actual+forecast bars
                        // for the same month. Each month gets a distinct colour
                        // from `budgetColor(for:)`. Skipped if no budget.
                        if m.budget > 0 {
                            let bColor = budgetColor(for: m)
                            BarMark(
                                x: .value("Month", m.monthLabel),
                                yStart: .value("BudgetLow", m.budget * 0.997),
                                yEnd: .value("BudgetHigh", m.budget * 1.003),
                                width: .ratio(0.92)
                            )
                            .foregroundStyle(bColor)
                            .annotation(position: .top, alignment: .center, spacing: 1) {
                                Text(CurrencyFormat.abbreviated(m.budget))
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(bColor)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisValueLabel {
                            if let label = value.as(String.self) {
                                let isProjected = months.first(where: { $0.monthLabel == label })?.isFuture ?? false
                                Text(label)
                                    .font(.system(size: 10, weight: isProjected ? .semibold : .regular))
                                    .foregroundStyle(isProjected
                                        ? CentmondTheme.Colors.projected
                                        : CentmondTheme.Colors.textTertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                        AxisValueLabel {
                            if let val = value.as(Double.self) {
                                Text(CurrencyFormat.abbreviated(val))
                                    .font(.system(size: 10))
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            }
                        }
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3, dash: [3, 3]))
                            .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.25))
                    }
                }
                .chartXScale(domain: months.map(\.monthLabel))
                .chartLegend(.hidden)
                .chartPlotStyle { plot in
                    plot.frame(minHeight: 300).clipped()
                }

                // Per-month budget legend — only when the window covers more
                // than one month with a budget set, otherwise the single
                // budget rule already speaks for itself via its label.
                if showBudgetLegend {
                    monthlyBudgetLegend(budgetMonths)
                }
            }
        }
    }

    /// Render a small wrapping legend strip mapping each month's budget colour
    /// to its label + dollar amount. Only shown when the chart spans 2+ months
    /// with budgets — clutter for the single-month case.
    @ViewBuilder
    private func monthlyBudgetLegend(_ months: [MonthlySpendingData]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Text("Monthly Budgets")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(months) { m in
                        HStack(spacing: 4) {
                            Capsule()
                                .fill(budgetColor(for: m))
                                .frame(width: 12, height: 3)
                            Text("\(m.monthLabel) · \(CurrencyFormat.abbreviated(m.budget))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(budgetColor(for: m).opacity(0.08))
                        .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.top, CentmondTheme.Spacing.xs)
    }

    /// Pick a distinct colour per month for the budget rule + legend chip.
    /// Uses month number (1...12) modulo the palette so the same calendar
    /// month always gets the same colour across windows (Apr is always teal,
    /// May is always rose, etc.) — keeps the colour mental-model stable.
    private func budgetColor(for m: MonthlySpendingData) -> Color {
        budgetColor(for: m.month)
    }

    private func budgetColor(for monthNumber: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.93, green: 0.34, blue: 0.45),  // rose
            Color(red: 0.96, green: 0.62, blue: 0.20),  // amber
            Color(red: 0.95, green: 0.78, blue: 0.20),  // gold
            Color(red: 0.46, green: 0.78, blue: 0.36),  // grass
            Color(red: 0.18, green: 0.78, blue: 0.61),  // teal
            Color(red: 0.20, green: 0.64, blue: 0.96),  // sky
            Color(red: 0.42, green: 0.39, blue: 0.96),  // indigo
            Color(red: 0.65, green: 0.36, blue: 0.96),  // violet
            Color(red: 0.92, green: 0.41, blue: 0.78),  // pink
            Color(red: 0.78, green: 0.55, blue: 0.34),  // bronze
            Color(red: 0.34, green: 0.56, blue: 0.78),  // slate-blue
            Color(red: 0.55, green: 0.74, blue: 0.20),  // lime
        ]
        return palette[((monthNumber - 1) % palette.count + palette.count) % palette.count]
    }

    // MARK: - Spending Heatmap Card (Hourly)

    private func spendingHeatmapCard(_ profile: EmotionalSpendingProfile) -> some View {
        // Aggregate into time-of-day zones so the user can actually interpret the data.
        // Morning 5-12, Afternoon 12-18, Evening 18-22, Late Night 22-5.
        let zones = buildTimeOfDayZones(profile.hourlySpending)
        let totalAll = zones.reduce(0.0) { $0 + $1.amount }
        let peakZone = zones.max(by: { $0.amount < $1.amount })
        let lateNightPct = totalAll > 0 ? (zones.first(where: { $0.key == "night" })?.amount ?? 0) / totalAll * 100 : 0

        return CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                // Title row — clear name + what it is
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("When You Spend")
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Text("Total dollars spent per hour of the day")
                            .font(.system(size: 10))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }

                    Spacer()

                    // Peak hour badge
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(CentmondTheme.Colors.negative)
                        Text("Peak \(formatHour(profile.peakSpendingHour))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CentmondTheme.Colors.negative)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CentmondTheme.Colors.negative.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.trailing, 110) // reserve space for floating chart-mode switcher
                }

                // Headline insight — the one sentence that tells you what this chart MEANS
                let peakAmount = profile.hourlySpending[profile.peakSpendingHour] ?? 0
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(CentmondTheme.Colors.accent.opacity(0.8))
                    Text(peakAmount > 0
                        ? "You spend most at **\(formatHour(profile.peakSpendingHour))** — \(CurrencyFormat.compact(Decimal(peakAmount))) total during this hour."
                        : "Not enough transactions yet to detect a peak hour.")
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    Spacer()
                }

                // Hourly bar chart — with time-of-day zone bands as background
                let hourlyData = buildHourlyData(profile.hourlySpending, peak: profile.peakSpendingHour)

                Chart {
                    // Background zone bands (subtle) — show when each part of day starts
                    RectangleMark(xStart: .value("s", -0.5), xEnd: .value("e", 4.5))
                        .foregroundStyle(CentmondTheme.Colors.warning.opacity(0.06))
                    RectangleMark(xStart: .value("s", 21.5), xEnd: .value("e", 23.5))
                        .foregroundStyle(CentmondTheme.Colors.warning.opacity(0.06))

                    ForEach(hourlyData) { item in
                        BarMark(
                            x: .value("Hour", item.hour),
                            y: .value("Amount", item.amount)
                        )
                        .foregroundStyle(
                            item.hour == profile.peakSpendingHour
                                ? CentmondTheme.Colors.negative
                                : item.isLateNight
                                    ? CentmondTheme.Colors.warning.opacity(0.75)
                                    : CentmondTheme.Colors.accent.opacity(0.55)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisValueLabel {
                            if let val = value.as(Double.self) {
                                Text(CurrencyFormat.abbreviated(val))
                                    .font(.system(size: 9))
                                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            }
                        }
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3, dash: [3, 3]))
                            .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.25))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            if let h = value.as(Int.self) {
                                Text(formatHour(h))
                                    .font(.system(size: 9))
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            }
                        }
                    }
                }
                .chartXScale(domain: -0.5...23.5)
                .chartLegend(.hidden)
                .chartPlotStyle { plot in
                    plot.frame(minHeight: 220).padding(.horizontal, 4).clipped()
                }

                // Time-of-day zone ribbon — tells you what share of spend happens when
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    ForEach(zones, id: \.key) { zone in
                        timeZoneChip(zone: zone, total: totalAll, isPeak: zone.key == peakZone?.key)
                    }
                }

                // Behavioral interpretation — turns numbers into meaning
                if lateNightPct >= 15 {
                    HStack(spacing: 6) {
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(CentmondTheme.Colors.warning)
                        Text("**\(Int(lateNightPct))%** of your spending happens late at night — often a sign of impulse buying.")
                            .font(.system(size: 10))
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(CentmondTheme.Colors.warning.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Time-of-day zone helpers

    private struct TimeZone: Identifiable {
        let id = UUID()
        let key: String        // "morning", "afternoon", "evening", "night"
        let label: String      // "Morning"
        let hours: String      // "5a–12p"
        let icon: String       // SF Symbol
        let amount: Double
        let color: Color
    }

    private func buildTimeOfDayZones(_ hourly: [Int: Double]) -> [TimeZone] {
        func sumHours(_ range: [Int]) -> Double { range.reduce(0.0) { $0 + (hourly[$1] ?? 0) } }
        return [
            TimeZone(
                key: "morning", label: "Morning", hours: "5a–12p", icon: "sun.and.horizon.fill",
                amount: sumHours(Array(5..<12)),
                color: CentmondTheme.Colors.positive
            ),
            TimeZone(
                key: "afternoon", label: "Afternoon", hours: "12p–6p", icon: "sun.max.fill",
                amount: sumHours(Array(12..<18)),
                color: CentmondTheme.Colors.accent
            ),
            TimeZone(
                key: "evening", label: "Evening", hours: "6p–10p", icon: "moon.fill",
                amount: sumHours(Array(18..<22)),
                color: CentmondTheme.Colors.info
            ),
            TimeZone(
                key: "night", label: "Late Night", hours: "10p–5a", icon: "moon.stars.fill",
                amount: sumHours(Array(22..<24) + Array(0..<5)),
                color: CentmondTheme.Colors.warning
            ),
        ]
    }

    private func timeZoneChip(zone: TimeZone, total: Double, isPeak: Bool) -> some View {
        let pct = total > 0 ? Int(zone.amount / total * 100) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: zone.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(zone.color)
                Text(zone.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                Spacer(minLength: 0)
                if isPeak {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(CentmondTheme.Colors.negative)
                }
            }
            Text(CurrencyFormat.compact(Decimal(zone.amount)))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            HStack(spacing: 3) {
                Text("\(pct)%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(zone.color)
                Text(zone.hours)
                    .font(.system(size: 9))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(zone.color.opacity(isPeak ? 0.12 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(zone.color.opacity(isPeak ? 0.4 : 0.15), lineWidth: 1)
                )
        )
    }

    private struct HourlyDataPoint: Identifiable {
        let id = UUID()
        let hour: Int
        let label: String
        let amount: Double
        let isLateNight: Bool
    }

    private func buildHourlyData(_ hourlySpending: [Int: Double], peak: Int) -> [HourlyDataPoint] {
        (0..<24).map { hour in
            HourlyDataPoint(
                hour: hour,
                label: formatHour(hour),
                amount: hourlySpending[hour, default: 0],
                isLateNight: hour >= 22 || hour < 5
            )
        }
    }

    private func formatHour(_ hour: Int) -> String {
        if hour == 0 { return "12A" }
        if hour < 12 { return "\(hour)A" }
        if hour == 12 { return "12P" }
        return "\(hour - 12)P"
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
        // Treat "this range queued for streaming" as analyzing too, so the
        // Deep Analysis card shows a busy state instead of "model not loaded"
        // while the background queue is still working through other ranges.
        isStreamingAI || isRangeQueued
    }

    /// True when the currently-viewed range has no cached AI yet AND the
    /// model is loaded (so a stream will arrive eventually).
    private var isRangeQueued: Bool {
        guard aiManager.status == .ready else { return false }
        return aiByRange[timeRange] == nil
    }

    // MARK: - Chart Mode Switcher

    private func chartWithModeSwitcher(data: PredictionData, ai: AIPredictionResult) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch chartMode {
                case .trajectory:
                    spendingTrajectoryChart(data, aiProjected: ai.projectedMonthlySpending, combatActions: ai.combatPlan)
                case .monthly:
                    monthlyOverviewChart(data.monthlyOverview, budget: data.forecast.totalBudget)
                case .hourly:
                    spendingHeatmapCard(data.emotionalProfile)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .animation(CentmondTheme.Motion.default, value: chartMode)

            // Compact icon-only segmented control — floats inside the card's top-right corner
            chartModeSwitcher
                .padding(.top, CentmondTheme.Spacing.md)
                .padding(.trailing, CentmondTheme.Spacing.md)
        }
    }

    private var chartModeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(ChartMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(CentmondTheme.Motion.default) {
                        chartMode = mode
                    }
                } label: {
                    Image(systemName: mode == .trajectory ? "chart.line.uptrend.xyaxis"
                                    : mode == .monthly ? "chart.bar.fill" : "clock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(chartMode == mode ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                        .frame(width: 30, height: 22)
                        .background(chartMode == mode ? CentmondTheme.Colors.accent.opacity(0.18) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.rawValue)
            }
        }
        .padding(3)
        .background(CentmondTheme.Colors.bgTertiary.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Spending Trajectory Chart (Advanced)

    private func spendingTrajectoryChart(_ data: PredictionData, aiProjected: Double, combatActions: [AICombatAction] = []) -> some View {
        // Sanity-bound the AI projection: if AI's number is >2x or <0.5x of the realistic
        // data-based projection (spent + dailyAvg × daysLeft), ignore AI and use realistic.
        let realisticProjected = data.forecast.spentSoFar + data.forecast.dailyAverage * Double(data.forecast.daysLeft)
        let safeProjected: Double = {
            guard aiProjected > 0, realisticProjected > 0 else { return realisticProjected }
            let ratio = aiProjected / realisticProjected
            if ratio > 2.0 || ratio < 0.5 { return realisticProjected }
            return aiProjected
        }()

        // Use the engine's per-day projected points (which now carry weekday variance
        // so the line has honest ups and downs). Rescale the projected deltas so the
        // final cumulative matches `safeProjected` — preserves the weekly rhythm while
        // honouring the AI-adjusted end-of-month target.
        let points: [SpendingDataPoint] = {
            let actual = data.spendingTrajectory.filter { !$0.isProjected }
            let projected = data.spendingTrajectory.filter { $0.isProjected }
            guard !projected.isEmpty else { return actual }

            let spentSoFar = actual.last?.amount ?? 0
            // Recover per-day deltas from the engine's cumulative projected points
            var prev = spentSoFar
            var deltas: [Double] = []
            for p in projected {
                deltas.append(max(0, p.amount - prev))
                prev = p.amount
            }
            let deltaSum = deltas.reduce(0, +)
            let targetRemaining = max(0, safeProjected - spentSoFar)
            let scale = deltaSum > 0 ? (targetRemaining / deltaSum) : 1.0

            var cum = spentSoFar
            let rescaled: [SpendingDataPoint] = zip(projected, deltas).map { (pt, d) in
                cum += d * scale
                return SpendingDataPoint(date: pt.date, amount: cum, isProjected: true)
            }
            return actual + rescaled
        }()
        let bars = data.dailyBars
        // Build confidence band FROM the reshaped projected points so band matches the line
        let band: [ConfidenceBandPoint] = {
            let projectedPts = points.filter { $0.isProjected }
            guard !projectedPts.isEmpty else { return [] }
            let dailyAmounts = data.dailyBars.filter({ !$0.isProjected }).map(\.amount)
            let stdDev = dailyAmounts.isEmpty ? 0 : {
                let mean = dailyAmounts.reduce(0, +) / Double(dailyAmounts.count)
                let variance = dailyAmounts.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(dailyAmounts.count)
                return sqrt(variance)
            }()
            return projectedPts.enumerated().map { i, pt in
                let daysOut = Double(i + 1)
                // Very thin band: max ±3% of cumulative, grows slowly
                let bandWidth = min(sqrt(daysOut) * max(stdDev * 0.3, 3), pt.amount * 0.03)
                return ConfidenceBandPoint(
                    date: pt.date,
                    low: max(0, pt.amount - bandWidth),
                    high: pt.amount + bandWidth
                )
            }
        }()
        let forecast = data.forecast
        let daysPassed = forecast.daysPassed

        // Breach computation moved below (needs `budgetSegments` / `isMultiMonth`).

        // Success path: if user committed to combat actions, show green optimistic line
        let totalCommittedSavings = combatActions.filter { committedActions.contains($0.id) }.reduce(0.0) { $0 + $1.savings }
        let successPath: [SpendingDataPoint] = {
            guard totalCommittedSavings > 0 else { return [] }
            let projected = points.filter { $0.isProjected }
            guard !projected.isEmpty else { return [] }
            let optimisticTarget = max(0, aiProjected - totalCommittedSavings)
            let spentSoFar = points.filter({ !$0.isProjected }).last?.amount ?? 0
            let remaining = max(0, optimisticTarget - spentSoFar)
            let projCount = Double(projected.count)
            let dailyAvg = projCount > 0 ? remaining / projCount : 0
            var cum = spentSoFar
            return projected.enumerated().map { i, pt in
                cum += dailyAvg
                let amount = (i == projected.count - 1) ? optimisticTarget : cum
                return SpendingDataPoint(date: pt.date, amount: amount, isProjected: true)
            }
        }()

        let riskLevel = aiPredictions?.riskLevel ?? "low"

        // Key derived stats
        let spentSoFar = points.filter({ !$0.isProjected }).last?.amount ?? 0
        let projectedEnd = points.last?.amount ?? aiProjected
        let overBudget = forecast.totalBudget > 0 ? projectedEnd - forecast.totalBudget : 0
        let dailyBudgetLeft = forecast.daysLeft > 0 && forecast.totalBudget > 0
            ? max(0, (forecast.totalBudget - spentSoFar)) / Double(forecast.daysLeft) : 0
        // Per-month cumulative budget segments. Empty for single-month views;
        // populated for 2M/3M/6M/1Y so the chart can show a coloured stair
        // step of cumulative budgets, one segment per month.
        let budgetSegments = monthlyBudgetSegments(data)
        let isMultiMonth = budgetSegments.count > 1

        // Per-month breach points. For multi-month windows we get ONE breach
        // per calendar month where cumulative spending crossed THAT month's
        // cumulative-budget step. Each breach carries the cumulative amount
        // at the breach day so the dot sits ON the cumulative line (not on
        // the budget rule — no connector riser needed). Single-month windows
        // fall back to a single breach against `totalBudget`.
        let breachPoints: [MonthBreach] = {
            guard !points.isEmpty else { return [] }
            if isMultiMonth {
                var result: [MonthBreach] = []
                for seg in budgetSegments {
                    // Baseline = cumulative spending at the END of the day
                    // before this month starts (i.e. the running total
                    // BROUGHT INTO this month). Within-month spending on
                    // day d is `pt.amount - baseline`. We flag the breach
                    // the first day that within-month spending >= monthBudget.
                    var baseline: Double = 0
                    if seg.dayStart > 1,
                       let prev = points.last(where: { dayForDate($0.date) <= seg.dayStart - 1 }) {
                        baseline = prev.amount
                    }
                    for pt in points {
                        let d = dayForDate(pt.date)
                        guard d >= seg.dayStart && d <= seg.dayEnd else { continue }
                        if pt.amount - baseline >= seg.monthBudget {
                            result.append(MonthBreach(day: d, amount: pt.amount, monthLabel: seg.monthLabel))
                            break
                        }
                    }
                }
                return result
            }
            guard forecast.totalBudget > 0 else { return [] }
            for pt in points {
                if pt.amount >= forecast.totalBudget {
                    return [MonthBreach(day: dayForDate(pt.date), amount: pt.amount, monthLabel: "")]
                }
            }
            return []
        }()
        // First breach drives the projected-line colour split and the header
        // "Breach day N" chip — preserves existing single-breach behaviour.
        let breachDay: Int? = breachPoints.first?.day

        // Adaptive Y domain: max(projected, budget, every cumulative segment) * 1.1
        let maxSegment = budgetSegments.map(\.cumulativeBudget).max() ?? 0
        let yMax = max(aiProjected, forecast.totalBudget, projectedEnd, maxSegment) * 1.1
        let projectedColor = CentmondTheme.Colors.projected  // violet — distinct from accent/warning/negative

        return CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                // Rich stats header
                HStack(alignment: .top) {
                    // Left: title + spent
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spending Trajectory")
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(CurrencyFormat.compact(Decimal(spentSoFar)))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            Text("of \(CurrencyFormat.compact(Decimal(forecast.totalBudget > 0 ? forecast.totalBudget : projectedEnd)))")
                                .font(.system(size: 11))
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }

                    Spacer()

                    // Right: key metrics chips (with trailing space reserved for floating mode switcher)
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        // Days left
                        statChip(
                            icon: "calendar",
                            value: "\(forecast.daysLeft)d left",
                            color: CentmondTheme.Colors.accent
                        )
                        // Daily average
                        statChip(
                            icon: "chart.bar.fill",
                            value: "\(CurrencyFormat.compact(Decimal(forecast.dailyAverage)))/day",
                            color: CentmondTheme.Colors.accent
                        )
                        // Budget status
                        if forecast.totalBudget > 0 {
                            if overBudget > 0 {
                                statChip(
                                    icon: "exclamationmark.triangle.fill",
                                    value: "+\(CurrencyFormat.compact(Decimal(overBudget))) over",
                                    color: CentmondTheme.Colors.negative
                                )
                            } else {
                                statChip(
                                    icon: "checkmark.circle.fill",
                                    value: "\(CurrencyFormat.compact(Decimal(dailyBudgetLeft)))/day safe",
                                    color: CentmondTheme.Colors.positive
                                )
                            }
                        }
                        // Breach day — for multi-month windows show the count
                        // alongside the first breach so the user sees "3
                        // breaches · first Day 7" at a glance.
                        if let bDay = breachDay {
                            statChip(
                                icon: "flame.fill",
                                value: breachPoints.count > 1
                                    ? "\(breachPoints.count) breaches · first \(bDay)"
                                    : "Breach day \(bDay)",
                                color: CentmondTheme.Colors.negative
                            )
                        }
                    }
                    .padding(.trailing, 110) // reserve space for floating chart-mode switcher
                }

                // Legend row
                HStack(spacing: CentmondTheme.Spacing.md) {
                    legendItem(color: CentmondTheme.Colors.accent, label: "Total", dashed: false)
                    legendItem(color: CentmondTheme.Colors.projected, label: "Projected", dashed: true)
                    if forecast.totalBudget > 0 {
                        legendItem(color: CentmondTheme.Colors.negative.opacity(0.6), label: "Budget", dashed: true)
                    }
                    if breachDay != nil {
                        legendItem(color: CentmondTheme.Colors.negative, label: "Breach", dashed: false)
                    }
                    if !successPath.isEmpty {
                        legendItem(color: CentmondTheme.Colors.positive, label: "If you cut", dashed: true)
                    }
                    Spacer()
                }

                // Main chart
                Chart {
                        // Layer 0: Forecast zone background — violet wash from today to end-of-month
                        // gives the projection region a clearly-different backdrop from actual history.
                        if let totalDays = bars.last?.dayOfMonth, daysPassed < totalDays {
                            RectangleMark(
                                xStart: .value("Start", daysPassed),
                                xEnd: .value("End", totalDays + 1),
                                yStart: .value("Min", 0),
                                yEnd: .value("Max", yMax)
                            )
                            .foregroundStyle(CentmondTheme.Colors.projected.opacity(0.07))
                        }

                        // Layer 1: Daily spending bars — actual = blue, projected = violet
                        // so the entire post-today region is clearly the forecast zone.
                        ForEach(bars) { bar in
                            BarMark(
                                x: .value("Day", bar.dayOfMonth),
                                y: .value("Amount", bar.amount)
                            )
                            .foregroundStyle(bar.isProjected
                                ? CentmondTheme.Colors.projected.opacity(0.28)
                                : CentmondTheme.Colors.accent.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        }


                        // Layer 2: Confidence band — thin ribbon, no fill to zero
                        ForEach(band) { pt in
                            AreaMark(
                                x: .value("Day", dayForDate(pt.date)),
                                yStart: .value("Low", pt.low),
                                yEnd: .value("High", pt.high)
                            )
                            .foregroundStyle(projectedColor.opacity(0.06))
                            .interpolationMethod(.monotone)
                        }

                        // Layer 3: Actual cumulative line (solid, prominent)
                        ForEach(points.filter({ !$0.isProjected })) { point in
                            LineMark(
                                x: .value("Day", dayForDate(point.date)),
                                y: .value("Cumulative", point.amount)
                            )
                            .foregroundStyle(CentmondTheme.Colors.accent)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                        }

                        // Layer 4: Projected line — blue before breach, red after breach
                        let projectedBridge: [SpendingDataPoint] = {
                            let actual = points.filter { !$0.isProjected }
                            let projected = points.filter { $0.isProjected }
                            if let last = actual.last {
                                return [last] + projected
                            }
                            return projected
                        }()

                        if let bDay = breachDay {
                            // Before breach: warning orange dashed (distinct from actual blue)
                            let beforeBreach = projectedBridge.filter { dayForDate($0.date) <= bDay }
                            ForEach(beforeBreach) { point in
                                LineMark(
                                    x: .value("Day", dayForDate(point.date)),
                                    y: .value("Cumulative", point.amount)
                                )
                                .foregroundStyle(projectedColor)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
                                .interpolationMethod(.monotone)
                            }
                            // After breach: red dashed — danger zone
                            let afterBreach = projectedBridge.filter { dayForDate($0.date) >= bDay }
                            ForEach(afterBreach) { point in
                                LineMark(
                                    x: .value("Day", dayForDate(point.date)),
                                    y: .value("Projected Over", point.amount)
                                )
                                .foregroundStyle(CentmondTheme.Colors.negative.opacity(0.75))
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
                                .interpolationMethod(.monotone)
                            }
                            // Breach markers — one per calendar month where
                            // the cumulative line crossed that month's
                            // cumulative-budget step. Each dot sits ON the
                            // cumulative line (x: breach day, y: cumulative
                            // amount at that day). The FIRST breach gets the
                            // glowing/pulsing treatment + a "Breach Day N"
                            // annotation; subsequent breaches get a smaller
                            // static red dot with the month label so the
                            // chart doesn't get annotation-noisy.
                            ForEach(Array(breachPoints.enumerated()), id: \.element.id) { idx, bp in
                                if idx == 0 {
                                    PointMark(
                                        x: .value("Day", bp.day),
                                        y: .value("Cumulative", bp.amount)
                                    )
                                    .symbol {
                                        // 8 fps — Charts re-lays out the symbol per tick.
                                        TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { context in
                                            let t = context.date.timeIntervalSinceReferenceDate
                                            let phase = (sin(t * 2.2) + 1) / 2  // 0...1
                                            ZStack {
                                                Circle()
                                                    .fill(CentmondTheme.Colors.negative.opacity(0.15 + 0.15 * phase))
                                                    .frame(width: 22 + 6 * phase, height: 22 + 6 * phase)
                                                    .blur(radius: 3)
                                                Circle()
                                                    .fill(CentmondTheme.Colors.negative.opacity(0.35))
                                                    .frame(width: 14, height: 14)
                                                Circle()
                                                    .fill(CentmondTheme.Colors.negative)
                                                    .frame(width: 7, height: 7)
                                                    .shadow(color: CentmondTheme.Colors.negative.opacity(0.9), radius: 4)
                                            }
                                        }
                                    }
                                    .annotation(position: .top, spacing: 4) {
                                        HStack(spacing: 2) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 8))
                                            Text(bp.monthLabel.isEmpty ? "Breach Day \(bp.day)" : "\(bp.monthLabel) breach")
                                                .font(.system(size: 8, weight: .bold))
                                        }
                                        .foregroundStyle(CentmondTheme.Colors.negative)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(CentmondTheme.Colors.negative.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                } else {
                                    PointMark(
                                        x: .value("Day", bp.day),
                                        y: .value("Cumulative", bp.amount)
                                    )
                                    .symbol {
                                        ZStack {
                                            Circle()
                                                .fill(CentmondTheme.Colors.negative.opacity(0.25))
                                                .frame(width: 12, height: 12)
                                            Circle()
                                                .fill(CentmondTheme.Colors.negative)
                                                .frame(width: 6, height: 6)
                                                .shadow(color: CentmondTheme.Colors.negative.opacity(0.7), radius: 2)
                                        }
                                    }
                                    .annotation(position: .top, spacing: 2) {
                                        Text("\(bp.monthLabel)")
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundStyle(CentmondTheme.Colors.negative)
                                            .padding(.horizontal, 3)
                                            .padding(.vertical, 1)
                                            .background(CentmondTheme.Colors.negative.opacity(0.10))
                                            .clipShape(RoundedRectangle(cornerRadius: 2))
                                    }
                                }
                            }
                        } else {
                            // No breach — warning-colored dashed projected line (distinct from actual)
                            ForEach(projectedBridge) { point in
                                LineMark(
                                    x: .value("Day", dayForDate(point.date)),
                                    y: .value("Cumulative", point.amount)
                                )
                                .foregroundStyle(projectedColor)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
                                .interpolationMethod(.monotone)
                            }
                        }

                        // Layer 4b: Projected endpoint amount
                        if let lastPt = projectedBridge.last {
                            let endColor = breachDay != nil ? CentmondTheme.Colors.negative : projectedColor
                            PointMark(
                                x: .value("Day", dayForDate(lastPt.date)),
                                y: .value("End", lastPt.amount)
                            )
                            .symbol {
                                Circle()
                                    .fill(endColor)
                                    .frame(width: 5, height: 5)
                            }
                            .annotation(position: .trailing, spacing: 2) {
                                Text(CurrencyFormat.compact(Decimal(lastPt.amount)))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(endColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(endColor.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }

                        // Layer 5: Today marker — prominent divider between actual & projected
                        RuleMark(x: .value("Today", daysPassed))
                            .foregroundStyle(CentmondTheme.Colors.accent.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .annotation(position: .top, alignment: .center) {
                                HStack(spacing: 3) {
                                    Image(systemName: "location.fill")
                                        .font(.system(size: 7))
                                    Text("Today")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundStyle(CentmondTheme.Colors.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(CentmondTheme.Colors.accent.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }

                        // Layer 7: Budget lines.
                        // Single-month view: keep the original full-width
                        // dashed budget rule (familiar reference line).
                        // Multi-month view: draw one coloured cumulative
                        // budget segment per month — each segment spans only
                        // that month's day-range and sits at the cumulative
                        // budget level, producing a stair-step that the
                        // cumulative spending line can be compared against.
                        if isMultiMonth {
                            monthlyBudgetMarks(budgetSegments)
                        } else if forecast.totalBudget > 0 {
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

                        // (Break-even marker removed — breachDay PointMark handles this)

                        // Layer 9: Success path (green) — shown when user commits to combat actions
                        if !successPath.isEmpty {
                            let bridged: [SpendingDataPoint] = {
                                if let lastActual = points.filter({ !$0.isProjected }).last {
                                    return [lastActual] + successPath
                                }
                                return successPath
                            }()
                            ForEach(bridged) { point in
                                LineMark(
                                    x: .value("Day", dayForDate(point.date)),
                                    y: .value("Success", point.amount)
                                )
                                .foregroundStyle(CentmondTheme.Colors.positive.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                                .interpolationMethod(.monotone)
                            }

                            // Endpoint marker showing target amount
                            if let lastPt = successPath.last {
                                PointMark(
                                    x: .value("Day", dayForDate(lastPt.date)),
                                    y: .value("Success", lastPt.amount)
                                )
                                .symbol {
                                    Circle()
                                        .fill(CentmondTheme.Colors.positive)
                                        .frame(width: 6, height: 6)
                                }
                                .annotation(position: .trailing, spacing: 4) {
                                    Text(CurrencyFormat.compact(Decimal(lastPt.amount)))
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(CentmondTheme.Colors.positive)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(CentmondTheme.Colors.positive.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                            }
                        }

                        // Layer 10: Highlighted bars for hovered trigger
                        if !hoveredTriggerDays.isEmpty {
                            ForEach(bars.filter({ hoveredTriggerDays.contains($0.dayOfMonth) })) { bar in
                                BarMark(
                                    x: .value("Day", bar.dayOfMonth),
                                    y: .value("Amount", bar.amount)
                                )
                                .foregroundStyle(CentmondTheme.Colors.warning.opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                            }
                        }

                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                            AxisValueLabel {
                                if let val = value.as(Double.self) {
                                    Text(CurrencyFormat.compact(Decimal(val)))
                                        .font(CentmondTheme.Typography.caption)
                                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                }
                            }
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.3))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: trajectoryXAxisTicks) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                                .foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.15))
                            AxisValueLabel {
                                if let day = value.as(Int.self) {
                                    Text(trajectoryXAxisLabel(forDayOffset: day))
                                        .font(.system(size: 9))
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                }
                            }
                        }
                    }
                    .chartYScale(domain: 0...yMax)
                    .chartLegend(.hidden)
                    .chartPlotStyle { plot in
                        plot.frame(minHeight: 340).padding(.horizontal, 4).clipped()
                    }
                    // Hover state lives INSIDE this overlay struct so 60Hz
                    // hover updates don't invalidate the entire AIPredictionView
                    // body (which was pegging CPU at 100% on hover). The
                    // overlay also draws its own hover rule + tooltip inside
                    // the chartOverlay's GeometryReader, so no parent state
                    // reads are needed by sibling .overlay() modifiers.
                    .chartOverlay { proxy in
                        TrajectoryHoverOverlay(
                            proxy: proxy,
                            bars: bars,
                            points: points,
                            forecast: forecast,
                            anchorDate: predictionData?.spendingTrajectory.first?.date
                        )
                    }

                // Bottom: budget progress bar + spending velocity
                if forecast.totalBudget > 0 {
                    VStack(spacing: CentmondTheme.Spacing.xs) {
                        // Progress bar
                        let budgetPct = min(spentSoFar / forecast.totalBudget, 1.5)
                        let timePct = Double(daysPassed) / Double(daysPassed + forecast.daysLeft)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                // Background
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(CentmondTheme.Colors.strokeSubtle.opacity(0.2))
                                // Spending fill
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(budgetPct > 1 ? CentmondTheme.Colors.negative :
                                          budgetPct > timePct ? CentmondTheme.Colors.warning :
                                          CentmondTheme.Colors.positive)
                                    .frame(width: geo.size.width * min(budgetPct, 1.0))
                                // Time marker
                                Rectangle()
                                    .fill(CentmondTheme.Colors.textQuaternary)
                                    .frame(width: 1.5)
                                    .offset(x: geo.size.width * timePct)
                            }
                        }
                        .frame(height: 6)

                        HStack {
                            Text("\(Int(budgetPct * 100))% of budget used")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(budgetPct > 1 ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textTertiary)
                            Spacer()
                            // Spending velocity indicator
                            let velocityRatio = forecast.dailyAverage / (forecast.totalBudget / Double(daysPassed + forecast.daysLeft))
                            HStack(spacing: 2) {
                                Image(systemName: velocityRatio > 1.1 ? "hare.fill" : velocityRatio < 0.9 ? "tortoise.fill" : "figure.walk")
                                    .font(.system(size: 8))
                                Text(velocityRatio > 1.1 ? "Spending too fast" : velocityRatio < 0.9 ? "Under control" : "On pace")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundStyle(velocityRatio > 1.1 ? CentmondTheme.Colors.negative : velocityRatio < 0.9 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textTertiary)
                        }
                    }
                }
            }
        }
        .background(
            // Risk-level radial glow behind the chart
            Group {
                if riskLevel.lowercased() == "high" {
                    RadialGradient(
                        colors: [CentmondTheme.Colors.negative.opacity(0.06), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 300
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous))
                } else if riskLevel.lowercased() == "medium" {
                    RadialGradient(
                        colors: [CentmondTheme.Colors.warning.opacity(0.04), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 300
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous))
                }
            }
        )
    }

    // Chart helpers

    /// Calculate a tight Y-axis max: just above the highest data point
    private func chartYMax(points: [SpendingDataPoint], budget: Double) -> Double {
        let maxCumulative = points.map(\.amount).max() ?? 0
        // Cap at 2× budget so bars don't get squashed when projection goes wild
        let hardCap = budget > 0 ? budget * 2 : maxCumulative * 1.1
        let relevantMax = min(max(maxCumulative, budget) * 1.1, hardCap)
        // Round up to nearest clean step
        let step: Double
        if relevantMax <= 100 { step = 10 }
        else if relevantMax <= 300 { step = 25 }
        else if relevantMax <= 600 { step = 50 }
        else if relevantMax <= 1500 { step = 100 }
        else if relevantMax <= 3000 { step = 200 }
        else { step = 500 }
        return ceil(relevantMax / step) * step
    }

    // MARK: - Trajectory X-axis ticks (range-aware)

    /// Tick positions for the trajectory chart's X-axis. The chart's X
    /// values are 1-indexed day offsets from `windowStart`. The cadence
    /// adapts to the selected analysis window:
    /// - This / Last Month  → every 5 days  (5, 10, 15, …)
    /// - Last 3 Months      → every 10 days
    /// - Last 6 Months      → every 15 days
    /// - Last Year          → first-of-month offsets, so labels read as
    ///                        clean month names with no double-month repeats.
    private var trajectoryXAxisTicks: [Int] {
        let total = predictionData?.spendingTrajectory.count ?? 30
        guard total > 0 else { return [] }
        switch timeRange {
        case .thisMonth, .lastMonth:
            return Array(stride(from: 5, through: total, by: 5))
        case .last3Months, .last6Months, .lastYear:
            // Multi-month windows: ALWAYS include the 1st of every calendar
            // month in the window (these tick labels show the month name) +
            // a couple of mid-month ticks per month for spatial reference.
            // Previous stride-by-N approach hid month boundaries because
            // only ticks landing on day ≤ 7 got a month label — for 3M
            // that meant only ONE tick out of 12 showed a month name.
            let monthStarts = monthStartDayOffsets(within: total)
            // Mid-month ticks: offset+15 (only if it doesn't collide with the
            // next month-start within ±4 days, so labels don't overlap).
            var ticks = Set(monthStarts)
            for ms in monthStarts {
                let mid = ms + 14
                let nextStart = monthStarts.first { $0 > ms } ?? (total + 1)
                if mid <= total && nextStart - mid >= 5 {
                    ticks.insert(mid)
                }
            }
            return ticks.sorted()
        }
    }

    /// Format an X-axis tick. For short windows the label is just the day
    /// of the month. For multi-month windows, the 1st-of-month ticks get
    /// the month name (and year suffix when crossing year boundaries) so
    /// the user can read "Jan / Feb / Mar / Apr" directly off the axis;
    /// mid-month ticks show the bare day.
    private func trajectoryXAxisLabel(forDayOffset offset: Int) -> String {
        let monthNames = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        guard let anchor = predictionData?.spendingTrajectory.first?.date else {
            return "\(offset)"
        }
        let cal = Calendar.current
        guard let date = cal.date(byAdding: .day, value: offset - 1, to: anchor) else {
            return "\(offset)"
        }
        let day = cal.component(.day, from: date)
        let month = monthNames[cal.component(.month, from: date) - 1]
        let year = cal.component(.year, from: date)
        let currentYear = cal.component(.year, from: Date())
        switch timeRange {
        case .thisMonth, .lastMonth:
            return "\(day)"
        case .last3Months, .last6Months:
            // First-of-month → month label (with year suffix if not current year).
            if day == 1 {
                return year == currentYear ? month : "\(month) '\(String(format: "%02d", year % 100))"
            }
            return "\(day)"
        case .lastYear:
            // Year view: only month names. Year suffix on the first month of
            // each calendar year so the timeline reads cleanly across years.
            if day == 1 {
                return (cal.component(.month, from: date) == 1)
                    ? "\(month) '\(String(format: "%02d", year % 100))"
                    : month
            }
            return ""
        }
    }

    /// Render per-month cumulative budget step segments as ChartContent.
    /// Extracted into its own builder so the trajectory chart's body stays
    /// within the Swift type-checker's complexity budget.
    @ChartContentBuilder
    private func monthlyBudgetMarks(_ segments: [MonthlyBudgetSegment]) -> some ChartContent {
        ForEach(segments) { seg in
            singleBudgetMark(seg)
        }
    }

    @ChartContentBuilder
    private func singleBudgetMark(_ seg: MonthlyBudgetSegment) -> some ChartContent {
        let color = budgetColor(for: seg.month)
        RuleMark(
            xStart: .value("Start", seg.dayStart),
            xEnd: .value("End", seg.dayEnd + 1),
            y: .value("Budget", seg.cumulativeBudget)
        )
        // Lower opacity per user feedback — segments were too saturated and
        // competed visually with the cumulative spending line.
        .foregroundStyle(color.opacity(0.55))
        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [4, 3]))
        .annotation(position: .top, alignment: .trailing, spacing: 1) {
            budgetSegmentLabel(seg)
        }
    }

    private func budgetSegmentLabel(_ seg: MonthlyBudgetSegment) -> some View {
        let color = budgetColor(for: seg.month)
        let amount = CurrencyFormat.compact(Decimal(seg.cumulativeBudget))
        return Text("\(seg.monthLabel) \(amount)")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color.opacity(0.75))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    /// Per-month budget step segment for the trajectory chart. Each segment
    /// covers the day-offsets of one calendar month and carries a *cumulative*
    /// budget value (sum of every month's MonthlyTotalBudget up to and
    /// including this month). Rendering them as horizontal segments at
    /// progressively-rising Y values produces a stair-step budget line that
    /// is directly comparable to the cumulative spending line.
    /// A single budget-crossing event: the day inside the window where
    /// cumulative spending first rose above THAT month's cumulative-budget
    /// step. Used to draw red breach dots ON the cumulative line.
    fileprivate struct MonthBreach: Identifiable {
        let id = UUID()
        let day: Int       // window-offset, 1-indexed
        let amount: Double // cumulative spending at the breach day (Y on the line)
        let monthLabel: String
    }

    private struct MonthlyBudgetSegment: Identifiable {
        let id = UUID()
        let monthLabel: String
        let month: Int
        let year: Int
        let dayStart: Int        // 1-indexed offset from window start
        let dayEnd: Int          // inclusive offset of the last day of this month within the window
        let monthBudget: Double
        let cumulativeBudget: Double
    }

    /// Build per-month cumulative budget segments from `monthlyOverview`.
    /// Skips months where no MonthlyTotalBudget is set (budget == 0).
    private func monthlyBudgetSegments(_ data: PredictionData) -> [MonthlyBudgetSegment] {
        guard let anchor = data.spendingTrajectory.first?.date else { return [] }
        let cal = Calendar.current
        let total = data.spendingTrajectory.count

        var segments: [MonthlyBudgetSegment] = []
        var cumulative: Double = 0

        for m in data.monthlyOverview {
            // Find the first and last day-offset inside this calendar month
            // by walking the trajectory points. Cheap because total is bounded
            // (≤ ~365 even on Last Year).
            var firstOffset: Int? = nil
            var lastOffset: Int? = nil
            for offset in 1...max(1, total) {
                guard let d = cal.date(byAdding: .day, value: offset - 1, to: anchor) else { continue }
                let mm = cal.component(.month, from: d)
                let yy = cal.component(.year, from: d)
                if mm == m.month && yy == m.year {
                    if firstOffset == nil { firstOffset = offset }
                    lastOffset = offset
                }
            }
            guard let s = firstOffset, let e = lastOffset else { continue }

            cumulative += m.budget
            // Skip rendering for zero-budget months but keep the cumulative
            // counter accurate (in case future months DO have a budget).
            guard m.budget > 0 else { continue }

            segments.append(MonthlyBudgetSegment(
                monthLabel: m.monthLabel,
                month: m.month,
                year: m.year,
                dayStart: s,
                dayEnd: e,
                monthBudget: m.budget,
                cumulativeBudget: cumulative
            ))
        }
        return segments
    }

    /// All day-offsets (1-indexed) inside the trajectory window that
    /// correspond to the 1st of a calendar month. Used as Year-view ticks.
    private func monthStartDayOffsets(within total: Int) -> [Int] {
        guard let anchor = predictionData?.spendingTrajectory.first?.date else { return [] }
        let cal = Calendar.current
        var offsets: [Int] = []
        for offset in 1...total {
            if let d = cal.date(byAdding: .day, value: offset - 1, to: anchor),
               cal.component(.day, from: d) == 1 {
                offsets.append(offset)
            }
        }
        return offsets
    }

    /// Day index along the chart's X-axis. For multi-month windows the
    /// trajectory spans many months, so we cannot use `Calendar.component(.day,…)`
    /// which resets to 1 on the 1st of each month and would fold the chart
    /// back on itself. Instead, use the offset (in days) from the engine's
    /// window start — i.e. the date of the first point in `predictionData.spendingTrajectory`.
    private func dayForDate(_ date: Date) -> Int {
        let cal = Calendar.current
        guard let anchor = predictionData?.spendingTrajectory.first?.date else {
            return cal.component(.day, from: date)
        }
        let dayStart = cal.startOfDay(for: anchor)
        let target = cal.startOfDay(for: date)
        return (cal.dateComponents([.day], from: dayStart, to: target).day ?? 0) + 1
    }

    private func cumulativeAt(day: Int, in points: [SpendingDataPoint]) -> Double {
        // `day` here is already a window-offset (1-indexed) produced by
        // `dayForDate`. Match using the same offset rule.
        if let match = points.last(where: { dayForDate($0.date) <= day }) {
            return match.amount
        }
        return 0
    }

    // `tooltipX` removed — TrajectoryHoverOverlay positions its tooltip
    // directly using its internal hoverLocation state.

    // `trajectoryTooltip` body extracted into the fileprivate
    // `TrajectoryTooltipView` struct (defined at end of file) so the new
    // `TrajectoryHoverOverlay` can render it without an AIPredictionView.

    private func statChip(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
            Text(value)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
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

// MARK: - Risk Level Environment Key

private struct RiskLevelKey: EnvironmentKey {
    static let defaultValue: String = "medium"
}

extension EnvironmentValues {
    var riskLevel: String {
        get { self[RiskLevelKey.self] }
        set { self[RiskLevelKey.self] = newValue }
    }
}

// MARK: - Risk-Themed Card Container

/// CardContainer variant that applies risk-based visual theming.
/// - High risk: red shadow glow + red stroke
/// - Medium risk: orange/warning tint
/// - Low risk: green phosphor glow + encouraging border
private struct RiskCardContainer<Content: View>: View {
    let riskLevel: String
    let content: Content
    @State private var isHovered = false

    init(riskLevel: String, @ViewBuilder content: () -> Content) {
        self.riskLevel = riskLevel
        self.content = content()
    }

    private var riskColor: Color {
        switch riskLevel.lowercased() {
        case "high": CentmondTheme.Colors.negative
        case "medium": CentmondTheme.Colors.warning
        default: CentmondTheme.Colors.positive
        }
    }

    private var shadowOpacity: Double {
        switch riskLevel.lowercased() {
        case "high": 0.25
        case "medium": 0.15
        default: 0.1
        }
    }

    var body: some View {
        content
            .padding(CentmondTheme.Spacing.lg)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                    .stroke(
                        isHovered ? riskColor.opacity(0.4) : riskColor.opacity(0.15),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            )
            .shadow(
                color: riskColor.opacity(isHovered ? shadowOpacity + 0.1 : shadowOpacity),
                radius: isHovered ? 16 : 6,
                y: isHovered ? 4 : 2
            )
            .onHover { hovering in
                withAnimation(CentmondTheme.Motion.default) {
                    isHovered = hovering
                }
            }
    }
}

// MARK: - Trajectory Hover Overlay
//
// Owns the hover state for the spending-trajectory chart so that 60Hz
// `onContinuousHover` callbacks invalidate ONLY this overlay — not the
// entire AIPredictionView body. Hoisting the state to the parent used
// to peg CPU at 100% on hover because every hover transition forced the
// parent to re-render every chart, the analyzing gradient TimelineView,
// every behavioral card, and the streamed report.
//
// The hover rule + tooltip are drawn inside the same GeometryReader as
// the hover detector so they share a coordinate space with the chart's
// plot frame and don't need any state on the parent.
fileprivate struct TrajectoryHoverOverlay: View {
    let proxy: ChartProxy
    let bars: [DailySpendingBar]
    let points: [SpendingDataPoint]
    let forecast: MonthForecast
    let anchorDate: Date?

    @State private var hoveredDay: Int?
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Hit target — captures hover, mutates LOCAL state only.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrameKey = proxy.plotFrame else {
                                if hoveredDay != nil { hoveredDay = nil }
                                return
                            }
                            let plotFrame = geometry[plotFrameKey]
                            let xInPlot = location.x - plotFrame.origin.x
                            guard xInPlot >= 0, xInPlot <= plotFrame.width else {
                                if hoveredDay != nil { hoveredDay = nil }
                                return
                            }
                            if let rawDay: Int = proxy.value(atX: xInPlot) {
                                let snapped = max(1, min(rawDay, bars.count))
                                if snapped != hoveredDay {
                                    hoveredDay = snapped
                                    if let snappedX: CGFloat = proxy.position(forX: snapped) {
                                        hoverLocation = CGPoint(x: snappedX + plotFrame.origin.x, y: 0)
                                    }
                                }
                            }
                        case .ended:
                            if hoveredDay != nil { hoveredDay = nil }
                        }
                    }

                // Vertical hover rule
                if hoveredDay != nil {
                    Rectangle()
                        .fill(CentmondTheme.Colors.textQuaternary.opacity(0.5))
                        .frame(width: 1, height: geometry.size.height)
                        .offset(x: hoverLocation.x)
                        .allowsHitTesting(false)
                }

                // Tooltip
                if let day = hoveredDay,
                   let bar = bars.first(where: { $0.dayOfMonth == day }) {
                    let cumulative = cumulativeAmount(forDay: day)
                    TrajectoryTooltipView(bar: bar, cumulative: cumulative, forecast: forecast)
                        .offset(x: max(10, hoverLocation.x - 80), y: 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.12), value: hoveredDay)
                }
            }
        }
    }

    /// Cumulative spending up to (and including) `day`. Day is a 1-indexed
    /// offset from `anchorDate` (the first point in the trajectory).
    /// Replicates `AIPredictionView.cumulativeAt` without needing the parent.
    private func cumulativeAmount(forDay day: Int) -> Double {
        guard let anchor = anchorDate else { return 0 }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: anchor)
        let match = points.last { pt in
            let target = cal.startOfDay(for: pt.date)
            let off = (cal.dateComponents([.day], from: dayStart, to: target).day ?? 0) + 1
            return off <= day
        }
        return match?.amount ?? 0
    }
}

// MARK: - Trajectory tooltip (extracted from AIPredictionView)
//
// Standalone struct so `TrajectoryHoverOverlay` can render it without
// holding an AIPredictionView reference.
fileprivate struct TrajectoryTooltipView: View {
    let bar: DailySpendingBar
    let cumulative: Double
    let forecast: MonthForecast

    var body: some View {
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
}
