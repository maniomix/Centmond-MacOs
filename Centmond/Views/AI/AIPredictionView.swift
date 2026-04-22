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
    // Hover state for the "highlight days on chart" affordance lives in an
    // @Observable class instead of @State. Why: every hover enter/leave
    // used to mutate a parent @State Set, which invalidated the WHOLE
    // AIPredictionView.body — rebuilding the Chart (60+ marks), every
    // card, every InlineEntityText, etc. CPU pegged.
    //
    // With @Observable, the class instance is stored in @State but the
    // parent body doesn't READ `triggerHover.days` — it only passes the
    // reference down. SwiftUI's observation system tracks property reads
    // per-view-identity; only views that read `triggerHover.days` in
    // THEIR OWN body (see `TriggerHoverHighlight`) invalidate when the
    // set changes. The parent stays inert on hover.
    @State private var triggerHover = TriggerHoverCoordinator()
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
        VStack(spacing: 0) {
            BetaBanner(title: "AI Predictions")

            ScrollView {
                if phase == .ready, let data = predictionData, let ai = aiPredictions {
                    readyContent(data: data, ai: ai)
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
        .onDisappear {
            // Same rationale as AIChatView.onDisappear — cancel any
            // in-flight prediction stream before the user lands on
            // another AI screen. Prevents concurrent generations
            // from colliding at LlamaBackend. `.task` above cancels
            // on view-removal for its own body, but the AIManager's
            // `Task.detached` generation task is NOT cancelled by
            // SwiftUI's task lifecycle — needs an explicit cancel.
            if aiManager.isGenerating {
                aiManager.cancelGeneration()
            }
        }
        } // VStack wrapping BetaBanner + ScrollView
    }

    // MARK: - Ready Content Layout
    //
    // Extracted out of `body` to narrow the type-checker's expression
    // scope. body was a single ~80-line HStack + many modifier chains,
    // which is slow-to-typecheck and slow-to-diff under incremental
    // builds. Sub-views also give SwiftUI a narrower invalidation
    // boundary — state that only affects the left column doesn't
    // invalidate the sidebar column and vice versa.

    @ViewBuilder
    private func readyContent(data: PredictionData, ai: AIPredictionResult) -> some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
            readyLeftColumn(data: data, ai: ai)
                .frame(maxWidth: .infinity)

            readyRightColumn(data: data)
                .frame(width: 340)
        }
        .padding(CentmondTheme.Spacing.sm)
        .environment(\.riskLevel, ai.riskLevel)
    }

    @ViewBuilder
    private func readyLeftColumn(data: PredictionData, ai: AIPredictionResult) -> some View {
        VStack(spacing: CentmondTheme.Spacing.sm) {
            // Row 0: Analysis window picker
            timeRangePickerBar

            // Row 1: Compact forecast strip
            compactForecastStrip(data.forecast, ai: ai)

            // Row 2: THE CHART
            chartWithModeSwitcher(data: data, ai: ai)

            // Row 3: Three intelligence cards side by side.
            // `maxHeight: .infinity` + a floor on the HStack
            // makes every card match the tallest one. Without
            // this, a 2-item Behavioral card ran ~210pt while
            // a 1-item Anomaly card stopped around ~130pt,
            // producing the visibly uneven row the user reported.
            // The inner `minHeight: 160` on each card's content
            // VStack was doing nothing useful here — it's the
            // HStack that has to coordinate heights, not the
            // cards themselves.
            HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
                behavioralTriggersCard(ai.triggers)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                anomalyDetectionCard(ai.anomalies)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                interactiveCombatPlanCard(ai.combatPlan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)

            // Row 3b: Help captions explaining what each card does.
            // Aligned column-for-column with the three cards above
            // so each tip sits directly under its card.
            HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
                intelligenceCardHelp(
                    icon: "hand.point.up.left.fill",
                    title: "Hover to highlight",
                    body: "Hover any pattern to highlight the days it happened on the chart above.",
                    accent: CentmondTheme.Colors.warning
                )
                intelligenceCardHelp(
                    icon: "magnifyingglass",
                    title: "Spending spikes",
                    body: "Unusual jumps the AI flagged. Review what triggered them — these are usually the easiest wins.",
                    accent: CentmondTheme.Colors.negative
                )
                intelligenceCardHelp(
                    icon: "cursorarrow.click.2",
                    title: "Click to simulate",
                    body: "Click any action to commit. A green “If you cut” line appears on the chart with your projected savings.",
                    accent: CentmondTheme.Colors.positive
                )
            }
            .padding(.top, CentmondTheme.Spacing.xs)

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
    }

    @ViewBuilder
    private func readyRightColumn(data: PredictionData) -> some View {
        VStack(spacing: CentmondTheme.Spacing.sm) {
            sidebarStatsCards(data.forecast)
            aiAnalysisCard
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
                        // `.controlSize(.small)` instead of `.scaleEffect(0.55)`
                        // — scaleEffect only visually scales the view while
                        // AppKit keeps the spinner's original intrinsic width
                        // (~59.43pt). Multiplying through produces 32.687858pt,
                        // and float precision makes AppKit's own min/max
                        // comparison fail with "maximum length (32.687858)
                        // doesn't satisfy min (32.687858) <= max (32.687858)"
                        // on every analyze tick. `.controlSize` resizes the
                        // control natively with clean integer intrinsics.
                        ProgressView()
                            .controlSize(.small)
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
                // Full AI text — card expands with page scroll, sidebar matches left column height.
                // Wrapped in `EqualityGate` so hover events on trigger rows
                // (which mutate `hoveredTriggerDays` on this view and force
                // a body re-eval) DON'T re-run `parseAnalysisByTimeframe`
                // or rebuild the WrapLayout tree. The gate is equal when
                // `text` and `timeRange` haven't changed — which is every
                // hover tick — and SwiftUI skips this subtree entirely.
                // Without this, ~15 paragraphs of regex-tokenization +
                // WrapLayout size-passes were burning CPU on every hover.
                EqualityGate(keys: [AnyHashable(aiAnalysisText), AnyHashable(timeRange.rawValue)]) {
                    aiReportContent(aiAnalysisText)
                }
                .equatable()
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
                        : CentmondTheme.Colors.accent.opacity(0.18),
                    lineWidth: isAnalyzing ? 1.5 : 1
                )
                .animation(CentmondTheme.Motion.default, value: isAnalyzing)
        )
        .shadow(
            color: isAnalyzing
                ? CentmondTheme.Colors.accent.opacity(0.35)
                : CentmondTheme.Colors.accent.opacity(0.10),
            radius: isAnalyzing ? 14 : 6,
            y: 2
        )
        .animation(CentmondTheme.Motion.default, value: isAnalyzing)
    }

    /// Background for the Deep Analysis card. Always shows the animated
    /// accent → purple gradient drifting diagonally (driven by TimelineView
    /// so it doesn't fight SwiftUI's view diff cycle). When generating the
    /// gradient is vivid; when idle it stays as a subtle "AI-touched" sheen
    /// at roughly 1/3 opacity. Idle sheen is what the user liked — "keep it
    /// even after ending the generating but less glowy".
    @ViewBuilder
    private var deepAnalysisCardBackground: some View {
        // CPU note: phase oscillates with period ~7s, so even 4-5 fps
        // looks smooth. Was 0.05s (20 fps) which alone burned ~10-15%
        // CPU on a large gradient + stroke + shadow surface. Idle uses a
        // slower tick (0.4s = ~2.5fps) since the dim gradient drift is
        // decorative, not attention-grabbing.
        TimelineView(.animation(minimumInterval: isAnalyzing ? 0.2 : 0.4)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((sin(t * 0.9) + 1) / 2)  // 0 → 1 → 0 every ~7 s
            // Opacity scale — 1.0 while generating, 0.35 when idle.
            // Tuned so the idle gradient reads as a soft ambient wash, not a
            // glow that competes with actual content.
            let k: Double = isAnalyzing ? 1.0 : 0.35
            ZStack {
                CentmondTheme.Colors.bgSecondary
                LinearGradient(
                    colors: [
                        CentmondTheme.Colors.accent.opacity(0.28 * k),
                        Color(red: 0.55, green: 0.36, blue: 0.96).opacity(0.22 * k),
                        CentmondTheme.Colors.accent.opacity(0.18 * k)
                    ],
                    startPoint: UnitPoint(x: phase, y: 0),
                    endPoint: UnitPoint(x: 1 - phase, y: 1)
                )
            }
            .animation(CentmondTheme.Motion.default, value: isAnalyzing)
        }
    }

    @ViewBuilder
    /// Groups the streamed AI report by timeframe rather than by topic.
    /// The AI produces `## Monthly Outlook` / `## Trigger Analysis` / ...
    /// sections with paragraphs each prefixed by `[This Month]`, `[Last Month]`,
    /// etc. Earlier renderer showed topic headers with mixed timeframes
    /// inside — the user's request was the inverse: "5 analyses for the 5
    /// timeframes." So we parse into `[Timeframe: [TopicEntry]]` and render
    /// timeframe-first. Within each timeframe we still keep the topic as a
    /// small sub-header so the reader knows which narrative thread they're
    /// reading (Outlook vs Triggers vs Psychology).
    ///
    /// If parsing yields nothing (stream hasn't produced any tagged content
    /// yet, or the AI forgot the tags), fall back to line-by-line rendering
    /// so an in-progress stream still shows something.
    private func aiReportContent(_ text: String) -> some View {
        let grouped = parseAnalysisByTimeframe(text)
        // STRICT filter to the selected tab. Earlier version fell back to
        // "show all timeframes" when the filter returned empty — but the
        // visual result (This Month paragraph at the top, which is the
        // first in enum order) was indistinguishable from the This Month
        // tab itself, so users reported "the text doesn't change" even
        // though I was filtering. Better: show an explicit empty state
        // for the selected timeframe so the user can see the filter IS
        // hooked up, and whatever's missing is an AI-output gap.
        let selected = grouped.filter { $0.timeframe == timeRange }

        if selected.isEmpty && grouped.isEmpty {
            // No structured content at all — streaming warmup or
            // un-tagged output. Line-by-line renderer with inline
            // entity capsules keeps something on screen.
            legacyLineRenderer(text)
        } else if selected.isEmpty {
            // Parser found structured content but none for the selected
            // window. Show the empty state, NOT the other timeframes —
            // silently substituting another window's content is what
            // made "the text doesn't change" look true to the user.
            timeframeMissingState()
        } else {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                ForEach(selected, id: \.timeframe) { section in
                    timeframeSection(section)
                }
            }
            // Re-render when the user flips tabs so the filtered slice
            // updates in place. Cheap — the parser is pure and the
            // grouped data is already in memory.
            .animation(CentmondTheme.Motion.default, value: timeRange)
            .animation(CentmondTheme.Motion.default, value: text)
        }
    }

    /// Empty state when the parsed analysis has content for other
    /// windows but not the one currently selected by the tab. Tells the
    /// user the filter IS working — the gap is in the AI output, not
    /// the UI.
    private func timeframeMissingState() -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                rangeCapsule(timeRange)
                Rectangle()
                    .fill(capsuleColor(for: timeRange).opacity(0.15))
                    .frame(height: 1)
            }

            HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: "hourglass")
                    .font(.system(size: 14))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 20)
                Text("The AI hasn't written an analysis for \(timeRange.rawValue) yet. Try refreshing the analysis to include this window.")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, CentmondTheme.Spacing.xs)
        }
        .padding(.top, CentmondTheme.Spacing.xs)
    }

    private func timeframeSection(_ section: TimeframeGroupedAnalysis) -> some View {
        let accent = capsuleColor(for: section.timeframe)
        return VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            // Timeframe header — coloured capsule + divider. Uses the same
            // palette as the inline window tags so the user's eye links
            // "This Month" in a tag to "This Month" as a section heading.
            HStack(spacing: CentmondTheme.Spacing.sm) {
                rangeCapsule(section.timeframe)
                Rectangle()
                    .fill(accent.opacity(0.15))
                    .frame(height: 1)
            }

            ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 4) {
                    if !entry.topic.isEmpty {
                        Text(entry.topic)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent.opacity(0.85))
                            .textCase(.uppercase)
                            .tracking(0.5)
                    }
                    InlineEntityText(text: entry.body)
                        .equatable()
                }
            }
        }
        .padding(.top, CentmondTheme.Spacing.xs)
    }

    /// Fallback renderer for text that hasn't yet parsed into timeframes
    /// (typically during the initial streaming chunks). Walks lines and
    /// renders headers + paragraphs with inline entity capsules. Does NOT
    /// show any `[Window]` tags that haven't finished streaming — an
    /// unclosed `[` is suppressed so the user doesn't see half-tags flash.
    @ViewBuilder
    private func legacyLineRenderer(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Spacer().frame(height: CentmondTheme.Spacing.sm)
                } else if trimmed.hasPrefix("## ") {
                    Text(trimmed.replacingOccurrences(of: "## ", with: ""))
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .padding(.top, CentmondTheme.Spacing.sm)
                } else if trimmed.hasPrefix("#") {
                    Text(trimmed.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces))
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .padding(.top, CentmondTheme.Spacing.xs)
                } else {
                    let parts = extractWindowTags(trimmed)
                    InlineEntityText(text: parts.body)
                        .equatable()
                }
            }
        }
    }

    /// Walks the AI report and produces timeframe-first groups. Within
    /// each timeframe, entries retain the topic (## heading) the paragraph
    /// came from so the UI can label it. Returns `[]` if the text is too
    /// fresh or too malformed to group.
    ///
    /// The AI sometimes emits paragraphs line-separated ("[This Month]\n…
    /// [Last Month]\n…") and sometimes concatenates multiple tags on ONE
    /// line ("[This Month] You are… April 30th. [Last Month] This past
    /// month saw…"). Earlier versions only picked up LEADING tags per
    /// line, so when the AI concatenated, everything after the leading
    /// [This Month] stayed bucketed under This Month — which made every
    /// tab look identical because the first tag in the stream is always
    /// This Month.
    ///
    /// Fix: scan the full text for `[Window]` markers wherever they
    /// appear, use each marker as a paragraph boundary, assign the
    /// preceding chunk to the PREVIOUS window tag, and start a new chunk
    /// under the current window tag. The `## Topic` heading tracking is
    /// folded into the same scan so a topic assignment stays valid across
    /// whatever window boundaries appear next.
    private func parseAnalysisByTimeframe(_ text: String) -> [TimeframeGroupedAnalysis] {
        var currentTopic: String = ""
        var byTimeframe: [PredictionTimeRange: [TopicEntry]] = [:]

        // Walk line-by-line to capture `## Topic` headings first, then
        // feed the remaining prose (a line at a time) into a window-tag
        // splitter. Collapsing to a single string would lose the topic
        // context that spans multiple lines.
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("## ") {
                currentTopic = trimmed.replacingOccurrences(of: "## ", with: "")
                continue
            }
            if trimmed.hasPrefix("#") { continue }  // other heading levels — skip

            // Split this line wherever a `[Window]` marker appears.
            // Each split produces (optional preceding-tag, chunk) pairs.
            for (tag, body) in splitByWindowMarkers(trimmed) {
                guard let tag, !body.isEmpty else { continue }
                byTimeframe[tag, default: []].append(TopicEntry(topic: currentTopic, body: body))
            }
        }

        if byTimeframe.isEmpty { return [] }

        return PredictionTimeRange.allCases.compactMap { range in
            guard let entries = byTimeframe[range], !entries.isEmpty else { return nil }
            return TimeframeGroupedAnalysis(timeframe: range, entries: entries)
        }
    }

    /// Split a line into `(tag, body)` chunks using any `[Window]`
    /// markers as boundaries. A chunk appearing BEFORE the first tag in
    /// the line has `tag = nil` (orphan prose, typically the AI forgot a
    /// leading tag — dropped by the parser). Case-insensitive tag match
    /// against the canonical window names.
    private func splitByWindowMarkers(_ line: String) -> [(tag: PredictionTimeRange?, body: String)] {
        // Regex: `[Window Name]` — letters, numbers, spaces inside brackets.
        guard let re = try? NSRegularExpression(pattern: #"\[([^\]]+)\]"#) else {
            return [(nil, line)]
        }
        let ns = line as NSString
        let matches = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty {
            return [(nil, line.trimmingCharacters(in: .whitespaces))]
        }

        var result: [(PredictionTimeRange?, String)] = []
        var cursor = 0
        var currentTag: PredictionTimeRange? = nil

        for m in matches {
            // Chunk of prose between the previous marker and this one
            // belongs to the CURRENT tag (the tag that started before it).
            if m.range.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                    .trimmingCharacters(in: .whitespaces)
                if !chunk.isEmpty {
                    result.append((currentTag, chunk))
                }
            }
            // Update the active tag from this marker's content.
            let inside = ns.substring(with: m.range(at: 1))
            if let range = PredictionTimeRange.allCases.first(where: {
                $0.rawValue.caseInsensitiveCompare(inside) == .orderedSame
            }) {
                currentTag = range
            }
            // else: unknown bracket content — leave the active tag alone
            // and skip the marker. This handles e.g. "[Window]" strings
            // the model might invent that don't match our enum.
            cursor = m.range.location + m.range.length
        }
        // Tail after the last marker belongs to the last tag
        if cursor < ns.length {
            let chunk = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
                .trimmingCharacters(in: .whitespaces)
            if !chunk.isEmpty {
                result.append((currentTag, chunk))
            }
        }
        return result
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
            // Outer VStack spacing MUST match the anomaly + combat cards
            // (both use `xs`). Earlier this card used `sm` (8pt) while the
            // other two used `xs` (4pt), producing a 4pt bottom-edge
            // misalignment that survived the HStack height equaliser.
            //
            // `.frame(maxHeight: .infinity, alignment: .top)` on the inner
            // VStack is load-bearing: the outer card already accepts up to
            // infinity height via its own `.frame(maxHeight: .infinity)`,
            // but without this modifier the inner VStack takes only its
            // natural (content) size, so a 2-row Behavioral card sitting
            // next to a 3-row Combat Plan card rendered shorter despite
            // the HStack having equalised. The modifier tells this
            // VStack to ABSORB any extra vertical space offered by the
            // HStack, keeping content top-aligned so the empty space
            // lands at the bottom.
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func behavioralTriggerCard(_ trigger: AITrigger) -> some View {
        // Precompute once per body re-eval. Closure captures `days`, so
        // hover enter/leave events reuse the cached value instead of
        // walking `currentMonthTransactions` with filters + date math
        // on every hover tick. `daysMatching` is ~1–5ms per call and
        // rapid mouse motion compounds that fast.
        let days = daysMatching(trigger: trigger)
        return BehavioralTriggerRow(
            trigger: trigger,
            icon: triggerIcon(for: trigger.pattern),
            onHoverChanged: { [triggerHover, days] hovering in
                // Mutates @Observable — only `TriggerHoverHighlight`
                // (which reads `triggerHover.days`) will invalidate.
                // Parent body stays inert so the Chart + cards don't
                // rebuild on hover.
                triggerHover.days = hovering ? days : []
            }
        )
    }

    /// Extract day-of-month numbers from trigger description text (e.g. "April 13th" → 13).
    /// Used as a fallback / supplement to the pattern-based matching in `daysMatching(trigger:)`.
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

    /// Returns the set of current-month days-of-month where a transaction matches the
    /// behavioral pattern (late-night, weekend, etc.). Used by the hover-to-highlight
    /// affordance under the Behavioral Patterns card — the chart's Layer 10 then highlights
    /// matching bars on those days.
    ///
    /// Why this exists: the AI's `trigger.description` text rarely contains explicit day
    /// numbers ("3 food delivery orders after 10 PM totaling $47" → no days). The earlier
    /// `extractDays(from:)` regex returned an empty set for time-based triggers like
    /// "Late-night activity", so hovering produced zero highlighted bars and the help text
    /// "Hover to highlight" was a lie. This function classifies the pattern from keywords
    /// in `trigger.pattern` and filters `predictionData.recentTransactions` accordingly,
    /// then unions whatever the regex extractor finds in the description.
    private func daysMatching(trigger: AITrigger) -> Set<Int> {
        var days = extractDays(from: trigger.description)

        // Prefer the UNCAPPED `currentMonthTransactions` list. The capped
        // `recentTransactions` sample (50 for .thisMonth) silently drops
        // early-month transactions when the ledger is dense near month-end
        // — so a user's 4AM charge on April 1 never enters the hover set
        // if April 20–30 already fill the 50-slot sample.
        let txns: [RecentTransaction] = {
            if let current = predictionData?.currentMonthTransactions, !current.isEmpty {
                return current
            }
            return predictionData?.recentTransactions ?? []
        }()

        guard !txns.isEmpty else { return days }

        let calendar = Calendar.current
        let now = Date()
        let currentMonth = calendar.component(.month, from: now)
        let currentYear = calendar.component(.year, from: now)

        // `currentMonthTransactions` is already month-scoped on the engine
        // side, but the fallback `recentTransactions` branch might hand us
        // cross-month data — the defensive filter is cheap so keep it.
        let currentMonthTxns = txns.filter {
            let m = calendar.component(.month, from: $0.date)
            let y = calendar.component(.year, from: $0.date)
            return m == currentMonth && y == currentYear
        }

        let pattern = trigger.pattern.lowercased()
        let description = trigger.description.lowercased()
        let combined = "\(pattern) \(description)"

        let matched: [RecentTransaction]
        if combined.contains("night") || combined.contains("midnight") || combined.contains("late") {
            // Late-night = engine's own definition: 22:00–04:59 (matches EmotionalSpendingProfile.lateNightCount)
            matched = currentMonthTxns.filter { $0.hourOfDay >= 22 || $0.hourOfDay <= 4 }
        } else if combined.contains("weekend") || combined.contains("saturday") || combined.contains("sunday") {
            matched = currentMonthTxns.filter { $0.isWeekend }
        } else if combined.contains("morning") || combined.contains("breakfast") || combined.contains("coffee") {
            matched = currentMonthTxns.filter { $0.hourOfDay >= 6 && $0.hourOfDay <= 10 }
        } else if combined.contains("lunch") || combined.contains("midday") {
            matched = currentMonthTxns.filter { $0.hourOfDay >= 11 && $0.hourOfDay <= 14 }
        } else if combined.contains("evening") || combined.contains("dinner") {
            matched = currentMonthTxns.filter { $0.hourOfDay >= 17 && $0.hourOfDay <= 21 }
        } else if combined.contains("food") || combined.contains("dining") || combined.contains("restaurant")
               || combined.contains("pizza") || combined.contains("delivery") || combined.contains("takeout") {
            matched = currentMonthTxns.filter {
                let c = $0.categoryName.lowercased()
                return c.contains("food") || c.contains("dining") || c.contains("restaurant")
                    || c.contains("delivery") || c.contains("takeout")
            }
        } else if combined.contains("subscription") || combined.contains("recurring") {
            matched = currentMonthTxns.filter {
                let c = $0.categoryName.lowercased()
                return c.contains("subscription") || c.contains("streaming") || c.contains("software")
            }
        } else if combined.contains("impulse") || combined.contains("small") || combined.contains("quick") {
            // Engine's impulse definition: small charges < $15
            matched = currentMonthTxns.filter { $0.amount < 15 }
        } else {
            matched = []
        }

        // Convert each matched transaction's date into a chart-X
        // coordinate: day-index FROM `windowStart` (+1 to match the
        // engine's `DailySpendingBar.dayOfMonth = day + 1` convention).
        //
        // Single-month view: windowStart = start-of-current-month, so
        // dayIdx for April 5 = 5 — same as calendar day-of-month. Old
        // behaviour preserved.
        //
        // Multi-month view (Last 3 Months, Last Year, etc.): windowStart
        // is months or a year before current month. April 5 with
        // windowStart = May 1 prior year → dayIdx = 340. Old code
        // returned `calendar.component(.day, ...) = 5`, which made the
        // chart plot the highlight at May 5 of the FIRST month —
        // hundreds of days away from the actual transaction.
        let windowStart = predictionData?.windowStart ?? calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        for txn in matched {
            let offset = calendar.dateComponents([.day], from: windowStart, to: txn.date).day ?? 0
            days.insert(offset + 1)
        }

        // The `extractDays` regex still returns calendar day-of-month
        // numbers (1-31) from AI text like "the 22nd" — those were
        // already only correct for single-month windows anyway. For
        // multi-month windows the AI's in-text day references are
        // ambiguous (which month's 22nd?) so we drop those days when
        // the window spans multiple months.
        let isMultiMonth = predictionData?.forecast.daysPassed ?? 0 > 35 ||
                           (calendar.dateComponents([.day], from: windowStart, to: now).day ?? 0) > 35
        if isMultiMonth {
            days = days.filter { $0 >= 1 && $0 <= 31 ? false : true }
            // Re-add only the offset-based days (txn-derived) for multi-
            // month windows. Extract-days results are discarded above.
            var offsetOnly = Set<Int>()
            for txn in matched {
                let offset = calendar.dateComponents([.day], from: windowStart, to: txn.date).day ?? 0
                offsetOnly.insert(offset + 1)
            }
            return offsetOnly
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                                // No `withAnimation` wrap — that propagated
                                // the toggle into the trajectory chart and
                                // Swift Charts tried to interpolate the
                                // success-path AreaMark from "no points" to
                                // "all points", producing torn triangular
                                // slices and a doubled-purple wash mid-frame.
                                // The button's own visual changes (icon
                                // swap, strikethrough, tint) animate via the
                                // implicit `.animation(value:)` on the row.
                                if isCommitted { committedActions.remove(action.id) }
                                else { committedActions.insert(action.id) }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                            ForEach(Array(merchants.prefix(6).enumerated()), id: \.element.id) { idx, merchant in
                                merchantRow(merchant, rank: idx + 1, maxAmount: maxAmount)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: dataCardHeight)
    }

    /// Single merchant row. Two-line layout mirroring the category card:
    ///   Line 1: [rank] name · Nx                           AMOUNT
    ///   Line 2: [bar proportional to top merchant amount]
    /// Rank number adds a clear ordering cue so the user doesn't have to
    /// re-read amounts to figure out the sort. The "Nx" transaction count
    /// moves next to the name (rather than a dim afterthought) and the
    /// bar tints by rank — top merchant full accent, others tinted down —
    /// so the eye can tell "this is the biggest" without staring.
    private func merchantRow(_ merchant: TopMerchant, rank: Int, maxAmount: Double) -> some View {
        let ratio = max(merchant.amount / maxAmount, 0.04)
        let isTop = rank == 1
        let barColor: Color = isTop ? CentmondTheme.Colors.accent : CentmondTheme.Colors.accent.opacity(0.5)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                // Rank chip — monospaced digit + circle so 1/2/3... line up
                Text("\(rank)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isTop ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill((isTop ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary).opacity(0.12))
                    )

                Text(merchant.name)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)

                Text("\(merchant.txCount)×")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                Spacer(minLength: CentmondTheme.Spacing.sm)

                Text(CurrencyFormat.compact(Decimal(merchant.amount)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
            }

            // Bar — indent to align with merchant name (chip 18pt + spacing 8pt)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CentmondTheme.Colors.bgTertiary)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: max(3, geo.size.width * ratio), height: 4)
                }
            }
            .frame(height: 4)
            .padding(.leading, 26)
        }
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

        // Success path: if user committed to combat actions, show green optimistic line.
        // Inherits the same per-day DELTAS (and thus weekday rhythm) as the violet
        // projected line, then rescales them so the new cumulative ends at the lower
        // `optimisticTarget`. Earlier version added a flat `dailyAvg` every day, which
        // produced a perfectly straight diagonal — visually inert and obviously fake
        // next to the projected line's organic ups and downs.
        let totalCommittedSavings = combatActions.filter { committedActions.contains($0.id) }.reduce(0.0) { $0 + $1.savings }
        let successPath: [SpendingDataPoint] = {
            guard totalCommittedSavings > 0 else { return [] }
            let projected = points.filter { $0.isProjected }
            guard !projected.isEmpty else { return [] }
            let optimisticTarget = max(0, aiProjected - totalCommittedSavings)
            let spentSoFar = points.filter({ !$0.isProjected }).last?.amount ?? 0
            let remaining = max(0, optimisticTarget - spentSoFar)

            // Recover per-day deltas from the violet projected line so the
            // success path moves with the same Monday-quiet / Friday-spike
            // shape. Without this the green line is a perfectly straight
            // diagonal that screams "fake".
            var prev = spentSoFar
            var deltas: [Double] = []
            for p in projected {
                deltas.append(max(0, p.amount - prev))
                prev = p.amount
            }
            let deltaSum = deltas.reduce(0, +)
            let scale = deltaSum > 0 ? (remaining / deltaSum) : 0

            var cum = spentSoFar
            return zip(projected, deltas).enumerated().map { (i, pair) in
                let (pt, d) = pair
                cum += d * scale
                // Pin the very last point to `optimisticTarget` exactly so
                // the endpoint label is a clean number, not off by a few $.
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

                        // Layer 3: Actual cumulative line (solid, prominent).
                        // CRITICAL: every LineMark layer in this Chart MUST
                        // pass an explicit `series:` value. Without it, Swift
                        // Charts groups all LineMarks by their y-axis VALUE
                        // name and the first style "wins" — that's why the
                        // projected/red and success/green lines were rendering
                        // as the same blue as this actual line. With `series:`
                        // each layer gets its own connected line and styling
                        // is honoured per series.
                        ForEach(points.filter({ !$0.isProjected })) { point in
                            LineMark(
                                x: .value("Day", dayForDate(point.date)),
                                y: .value("Amount", point.amount),
                                series: .value("Path", "Actual")
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
                            // Before breach: violet dashed (distinct from actual blue).
                            // Explicit `series:` so this isn't merged with Layer 3.
                            let beforeBreach = projectedBridge.filter { dayForDate($0.date) <= bDay }
                            ForEach(beforeBreach) { point in
                                LineMark(
                                    x: .value("Day", dayForDate(point.date)),
                                    y: .value("Amount", point.amount),
                                    series: .value("Path", "ProjectedSafe")
                                )
                                .foregroundStyle(projectedColor)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
                                .interpolationMethod(.monotone)
                            }
                            // After breach: red dashed — danger zone.
                            // Distinct `series:` so red stays red regardless
                            // of layer ordering or other LineMarks present.
                            let afterBreach = projectedBridge.filter { dayForDate($0.date) >= bDay }
                            ForEach(afterBreach) { point in
                                LineMark(
                                    x: .value("Day", dayForDate(point.date)),
                                    y: .value("Amount", point.amount),
                                    series: .value("Path", "ProjectedDanger")
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
                                        // IMPORTANT: the outer ZStack must have a
                                        // FIXED frame size. If the animated outer
                                        // circle changes the ZStack's intrinsic
                                        // size, Swift Charts re-anchors the whole
                                        // symbol on every tick and the dot
                                        // visibly jitters. We pin to 28×28 (the
                                        // max pulse size) and let the inner
                                        // circles breathe inside that frame via
                                        // scaleEffect instead of frame.
                                        TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { context in
                                            let t = context.date.timeIntervalSinceReferenceDate
                                            let phase = (sin(t * 2.2) + 1) / 2  // 0...1
                                            ZStack {
                                                Circle()
                                                    .fill(CentmondTheme.Colors.negative.opacity(0.15 + 0.15 * phase))
                                                    .frame(width: 22, height: 22)
                                                    .scaleEffect(1.0 + 0.27 * phase)
                                                    .blur(radius: 3)
                                                Circle()
                                                    .fill(CentmondTheme.Colors.negative.opacity(0.35))
                                                    .frame(width: 14, height: 14)
                                                Circle()
                                                    .fill(CentmondTheme.Colors.negative)
                                                    .frame(width: 7, height: 7)
                                                    .shadow(color: CentmondTheme.Colors.negative.opacity(0.9), radius: 4)
                                            }
                                            .frame(width: 28, height: 28)
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
                            // No breach — violet dashed projected line.
                            // Distinct `series:` so it never gets merged into
                            // the actual-blue series.
                            ForEach(projectedBridge) { point in
                                LineMark(
                                    x: .value("Day", dayForDate(point.date)),
                                    y: .value("Amount", point.amount),
                                    series: .value("Path", "ProjectedSafe")
                                )
                                .foregroundStyle(projectedColor)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
                                .interpolationMethod(.monotone)
                            }
                        }

                        // Layer 4b: Projected endpoint amount.
                        // When a success path is committed we offset the
                        // projected label UP and the success label DOWN so
                        // their boxes don't collide on the right edge — they
                        // typically only differ by a few % of yMax which puts
                        // them within label-height of each other.
                        if let lastPt = projectedBridge.last {
                            let endColor = breachDay != nil ? CentmondTheme.Colors.negative : projectedColor
                            // Pinned to `.topTrailing` regardless of whether the
                            // success path is showing. Earlier we flipped this
                            // between `.trailing` (no success) and `.topTrailing`
                            // (success exists) for visual balance, but that
                            // position flip depends on `committedActions` —
                            // which means the chart-level
                            // `.animation(_:value: committedActions)` modifier
                            // ANIMATES the label sliding between positions,
                            // and the whole projected PointMark re-animates
                            // alongside it. The user reads that as "the red
                            // line is glitching" because the dot + label
                            // visibly shift every time you click a Combat
                            // Plan action. Pinning the position eliminates
                            // the dependency, so the projected mark stays
                            // perfectly still while only the success-path
                            // layer animates in/out.
                            PointMark(
                                x: .value("Day", dayForDate(lastPt.date)),
                                y: .value("End", lastPt.amount)
                            )
                            .symbol {
                                Circle()
                                    .fill(endColor)
                                    .frame(width: 5, height: 5)
                            }
                            .annotation(position: .topTrailing, spacing: 2) {
                                Text(CurrencyFormat.compact(Decimal(lastPt.amount)))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(endColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(endColor.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }

                        // Layer 5: Today marker — prominent divider between actual & projected.
                        // Hidden when data covers the full window (daysPassed >= totalDays)
                        // because there's no projected region to divide; showing it would
                        // plant a misleading "Today" label at the far right of a complete
                        // month of data.
                        if let totalDays = bars.last?.dayOfMonth, daysPassed < totalDays {
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

                        // Layer 9: Success path (green) — shown when user commits to
                        // combat actions. Drawn AFTER (on top of) the violet/red
                        // projected line so the green stays visible even when the
                        // two paths nearly overlap. Uses a distinct y-axis name
                        // ("If You Cut") to keep Swift Charts from merging it
                        // with the "Cumulative"/"Projected Over" series — that
                        // merge was making the green stroke render as the same
                        // bluish hue as the rest. Also uses a wider dash pattern
                        // (10/5) so the segments read as clearly DIFFERENT from
                        // the projected line's tighter (6/4) dashes.
                        if !successPath.isEmpty {
                            let bridged: [SpendingDataPoint] = {
                                if let lastActual = points.filter({ !$0.isProjected }).last {
                                    return [lastActual] + successPath
                                }
                                return successPath
                            }()

                            // Success line — IDENTICAL stroke (2.5pt, dash [6,4],
                            // round cap) to the projected line. Earlier tried a
                            // longer dash [8,4] for differentiation but with
                            // round caps each dash gained ~2.5pt rounding on
                            // both ends → green dashes rendered as visibly
                            // chunkier "pills" vs red's tighter "ticks", which
                            // the user read as still being thicker. Colour
                            // alone (green vs red) carries the differentiation.
                            ForEach(bridged) { point in
                                LineMark(
                                    x: .value("Day", dayForDate(point.date)),
                                    y: .value("Amount", point.amount),
                                    series: .value("Path", "IfYouCut")
                                )
                                .foregroundStyle(CentmondTheme.Colors.positive)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
                                .interpolationMethod(.monotone)
                            }

                            // Endpoint marker showing target amount.
                            // Anchored bottom-trailing so its label sits BELOW
                            // the data point — paired with the projected
                            // endpoint's top-trailing label, the two never
                            // overlap even when amounts are within a few % of
                            // each other on the y-axis.
                            if let lastPt = successPath.last {
                                PointMark(
                                    x: .value("Day", dayForDate(lastPt.date)),
                                    y: .value("If You Cut", lastPt.amount)
                                )
                                .symbol {
                                    ZStack {
                                        Circle()
                                            .fill(CentmondTheme.Colors.positive.opacity(0.20))
                                            .frame(width: 10, height: 10)
                                        Circle()
                                            .fill(CentmondTheme.Colors.positive)
                                            .frame(width: 5, height: 5)
                                            .shadow(color: CentmondTheme.Colors.positive.opacity(0.6), radius: 2)
                                    }
                                }
                                .annotation(position: .bottomTrailing, spacing: 4) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.down.right")
                                            .font(.system(size: 8, weight: .bold))
                                        Text(CurrencyFormat.compact(Decimal(lastPt.amount)))
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    }
                                    .foregroundStyle(CentmondTheme.Colors.positive)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(CentmondTheme.Colors.positive.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                            }
                        }

                        // Layer 10 MOVED to a chartOverlay Canvas — see
                        // `TriggerHoverHighlight` below. Drawing the highlight
                        // inside the Chart block meant every hover on a
                        // Behavioral Pattern row triggered a full Chart
                        // rebuild (60+ marks). Moving it to a chartOverlay
                        // backed by @Observable means only that overlay
                        // invalidates on hover.

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
                    // Behavioral-Pattern hover highlight lives here (was
                    // Chart Layer 10). Passes the @Observable coordinator;
                    // only THIS overlay's body reads `coordinator.days`,
                    // so only this Canvas invalidates when the user hovers
                    // a trigger row. The main Chart stays fully rebuilt-
                    // free. Drawn BEHIND TrajectoryHoverOverlay so the
                    // hover dot glow stays on top.
                    .chartOverlay(alignment: .topLeading) { proxy in
                        TriggerHoverHighlight(coordinator: triggerHover, proxy: proxy)
                    }
                    // Native Swift Charts animation for the success-path layer.
                    // When `committedActions` toggles, the LineMark/PointMark
                    // for the green "If you cut" path either appear or
                    // disappear; this `.animation(_:value:)` modifier on the
                    // Chart view tells Charts to interpolate that transition
                    // over 0.5s rather than snapping. With AreaMark already
                    // removed earlier, only LineMark and PointMark remain,
                    // both of which interpolate cleanly.
                    .animation(.easeInOut(duration: 0.5), value: committedActions)

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

    /// Caption row sitting beneath each of the three intelligence cards
    /// (Behavioral / Anomalies / Combat Plan). Tells the user what they can
    /// DO with the card — hover to highlight, read the spike, click to
    /// simulate the savings line. Aligned column-for-column with the cards
    /// above via `.frame(maxWidth: .infinity)`.
    private func intelligenceCardHelp(icon: String, title: String, body: String, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 22, height: 22)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                Text(body)
                    .font(.system(size: 10))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CentmondTheme.Spacing.sm)
        .padding(.vertical, CentmondTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
                        // Pass the top category's projected spend so every
                        // row renders a magnitude bar proportional to it.
                        // Previously only rows with a budget showed a bar,
                        // so the card looked empty and scale-less — the
                        // user couldn't tell at a glance that Travel was
                        // ~2× Home without reading numbers. The merchant
                        // card already does this; the two now match.
                        let maxAmount = max(1, categories.map(\.projected).max() ?? 1)
                        VStack(spacing: CentmondTheme.Spacing.xs) {
                            ForEach(categories.prefix(10)) { cat in
                                categoryRow(cat, maxAmount: maxAmount)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: dataCardHeight)
    }

    private func categoryRow(_ cat: CategoryProjection, maxAmount: Double) -> some View {
        // Two-line layout, parity with the merchants card:
        //   Line 1: [icon] name [trend pill]              AMOUNT
        //   Line 2: [magnitude bar]           [over-by caption if flagged]
        //
        // The bar is ALWAYS rendered, proportional to the top category's
        // amount, tinted in the category's own colorHex. That gives every
        // row a visual weight cue — users can tell "Travel is roughly 2×
        // Home" without reading any numbers. Earlier iteration only drew
        // bars for rows with a budget set, which is 1–2 rows out of 10 in
        // typical data, leaving the rest of the card feeling empty.
        //
        // Over-budget handling:
        //   - Amount text turns red.
        //   - Bar tint switches to red (overrides the category colour) so
        //     it visually "stains" the row.
        //   - Line 2 gets the "over by $N" caption aligned to the right.
        //
        // Trend arrow only appears when rising or falling — stable is the
        // majority case and the arrow was cluttering every single row.
        let hasBudget = cat.budget > 0
        let overBudget = hasBudget && cat.projected > cat.budget
        let magnitudeRatio = cat.projected / maxAmount
        let amountColor: Color = overBudget ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textPrimary
        let barTint: Color = overBudget ? CentmondTheme.Colors.negative : Color(hex: cat.colorHex)

        return VStack(alignment: .leading, spacing: 6) {
            // Line 1
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: cat.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: cat.colorHex))
                    .frame(width: 20)

                Text(cat.name)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)

                if cat.trend == .rising {
                    trendPill(symbol: "arrow.up.right", color: CentmondTheme.Colors.negative)
                } else if cat.trend == .falling {
                    trendPill(symbol: "arrow.down.right", color: CentmondTheme.Colors.positive)
                }

                Spacer(minLength: CentmondTheme.Spacing.sm)

                Text(CurrencyFormat.compact(Decimal(cat.projected)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(amountColor)
                    .monospacedDigit()
            }

            // Line 2 — magnitude bar + optional over-by caption, both
            // indented 28pt (icon 20pt + spacing 8pt) so they align under
            // the NAME, not the icon column.
            HStack(spacing: CentmondTheme.Spacing.sm) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(CentmondTheme.Colors.bgTertiary)
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barTint)
                            .frame(width: max(3, geo.size.width * min(magnitudeRatio, 1.0)), height: 4)
                    }
                }
                .frame(height: 4)

                if overBudget {
                    Text("over by \(CurrencyFormat.compact(Decimal(cat.projected - cat.budget)))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.negative)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.leading, 28)
        }
        .padding(.vertical, 5)
    }

    /// Tiny coloured pill for the trend arrow. Replaces the earlier bare
    /// SF Symbol next to the name, which blended into the row and looked
    /// like every category was trending up. A filled rounded chip is
    /// scannable as an explicit "this metric is moving" badge.
    private func trendPill(symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
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

// MARK: - Behavioral Trigger Row
//
// Owns its own `isHovered` @State so the hover transition animates the card
// background locally without invalidating AIPredictionView's body on every
// enter/leave. The parent is notified via `onHoverChanged` so it can update
// `hoveredTriggerDays` (the chart highlight source of truth). This matches
// the rule from the "Hover State Scope" memory — any hover handler on a busy
// parent view gets extracted into its own sub-view.
fileprivate struct BehavioralTriggerRow: View {
    let trigger: AITrigger
    let icon: String
    let onHoverChanged: (Bool) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(CentmondTheme.Colors.warning.opacity(isHovered ? 0.22 : 0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
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
        .background(CentmondTheme.Colors.warning.opacity(isHovered ? 0.16 : 0.05))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                .stroke(CentmondTheme.Colors.warning.opacity(isHovered ? 0.5 : 0), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
        .contentShape(Rectangle())
        // Implicit `.animation(_:value:)` is narrower than `withAnimation`
        // — it only animates properties whose values derive from
        // `isHovered` (icon circle fill opacity, background opacity, stroke
        // opacity). withAnimation(...) created a broader transaction that
        // propagated to sibling state changes, which added cost on rapid
        // mouse movement across rows.
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering)
        }
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
            // Card hover fires every time the mouse moves over any
            // descendant (including the behavioral rows inside).
            // Narrower implicit animation instead of withAnimation so
            // the row's own hover transaction and the card's hover
            // transaction don't stack when the user is moving inside
            // the card.
            .animation(CentmondTheme.Motion.default, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
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

                // Soft blue dot pinned to the line at the hovered day — same
                // accent blue as the actual cumulative line, so it reads as
                // "the line glowing a little" rather than a spotlight.
                // plusLighter over accent-blue stays subtle because we keep
                // the core opacity low.
                if let day = hoveredDay,
                   let plotFrameKey = proxy.plotFrame {
                    let plotFrame = geometry[plotFrameKey]
                    let cumulative = cumulativeAmount(forDay: day)
                    if let yInPlot = proxy.position(forY: cumulative) {
                        let hx = hoverLocation.x
                        let hy = yInPlot + plotFrame.origin.y
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        CentmondTheme.Colors.accent.opacity(0.45),
                                        CentmondTheme.Colors.accent.opacity(0.18),
                                        CentmondTheme.Colors.accent.opacity(0.0)
                                    ],
                                    center: .center,
                                    startRadius: 0.5,
                                    endRadius: 11
                                )
                            )
                            .frame(width: 26, height: 26)
                            .blendMode(.plusLighter)
                            .position(x: hx, y: hy)
                            .allowsHitTesting(false)
                            .animation(.easeOut(duration: 0.08), value: hoveredDay)
                    }
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

    /// Points of the actual (non-projected) cumulative line within ±`window`
    /// days of `centerDay`, converted to overlay-space CGPoints so the
    /// `Canvas` can stroke them directly. Empty / single-element if the
    /// window falls outside the data range.
    fileprivate struct HighlightPoint { let day: Double; let point: CGPoint }
    private func highlightSegment(centerDay: Int, window: Int, proxy: ChartProxy, plotFrame: CGRect) -> [HighlightPoint] {
        guard let anchor = anchorDate else { return [] }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: anchor)
        let lo = centerDay - window
        let hi = centerDay + window
        var result: [HighlightPoint] = []
        for pt in points where !pt.isProjected {
            let target = cal.startOfDay(for: pt.date)
            let off = (cal.dateComponents([.day], from: dayStart, to: target).day ?? 0) + 1
            guard off >= lo && off <= hi else { continue }
            guard let xInPlot = proxy.position(forX: off),
                  let yInPlot = proxy.position(forY: pt.amount) else { continue }
            result.append(HighlightPoint(
                day: Double(off),
                point: CGPoint(x: xInPlot + plotFrame.origin.x, y: yInPlot + plotFrame.origin.y)
            ))
        }
        return result
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

// MARK: - Deep Analysis: Timeframe-Grouped Parse Result

/// One time window + the topic paragraphs the AI generated for it.
fileprivate struct TimeframeGroupedAnalysis: Hashable {
    let timeframe: PredictionTimeRange
    let entries: [TopicEntry]
}

/// One paragraph inside a timeframe group — topic is the `## heading`
/// the paragraph came from (Monthly Outlook / Triggers / etc.).
fileprivate struct TopicEntry: Hashable {
    let topic: String
    let body: String
}

// MARK: - Deep Analysis: Inline Entity Capsules
//
// Replaces the plain `Text(paragraph)` renderer with a per-token view
// so dollar amounts, percentages, and month names can render as inline
// coloured capsules without breaking natural text-wrap. User request:
// "you are over budget by (200€) by the category of (travel)" — parens
// = capsule. We match:
//   - currency:  $1,234.56 / €200 / 200€ / 12k etc.
//   - percent:   -36% / 12.5%
//   - month:     April / Apr / March 2026
// Plain text between entities is split word-by-word so the wrapping
// layout can break lines naturally. Categories are detected from a
// static keyword list — good enough for the common cases (travel,
// food, shopping, etc.); extend as needed.

/// One token in a parsed paragraph. Plain text tokens are rendered as
/// `Text`; entity tokens render as coloured capsules.
fileprivate enum InlineToken {
    case text(String)
    case amount(String)
    case percent(String)
    case month(String)
    case category(String)
}

/// Renders a paragraph with inline coloured capsules for entities.
fileprivate struct InlineEntityText: View, Equatable {
    let text: String

    // `Equatable` + `.equatable()` at call sites is load-bearing.
    // Hovering a Behavioral Pattern row updates `hoveredTriggerDays` on
    // `AIPredictionView`, which invalidates the whole body — normally
    // SwiftUI would then call THIS view's `body` on every hover, which
    // in turn runs `InlineTokenizer.tokenize(text)` through
    // NSRegularExpression + a nested loop in `WrapLayout.sizeThatFits`
    // over ~100 subviews per paragraph × ~15 paragraphs. CPU spiked to
    // 100% on hover. Making the view `Equatable` on `text` alone lets
    // SwiftUI skip body + layout entirely when the text (the only
    // input) hasn't changed, which is every hover tick.
    static func == (lhs: InlineEntityText, rhs: InlineEntityText) -> Bool {
        lhs.text == rhs.text
    }

    var body: some View {
        let tokens = InlineTokenizer.tokenize(text)
        WrapLayout(hSpacing: 3, vSpacing: 5) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                tokenView(token)
            }
        }
    }

    @ViewBuilder
    private func tokenView(_ token: InlineToken) -> some View {
        switch token {
        case .text(let s):
            Text(s)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
        case .amount(let s):
            inlineCapsule(s, color: CentmondTheme.Colors.accent, monospaced: true)
        case .percent(let s):
            let isNegative = s.hasPrefix("-")
            inlineCapsule(s, color: isNegative ? CentmondTheme.Colors.negative : CentmondTheme.Colors.positive, monospaced: true)
        case .month(let s):
            inlineCapsule(s, color: Color(red: 0.55, green: 0.36, blue: 0.96), monospaced: false) // violet
        case .category(let s):
            inlineCapsule(s, color: CentmondTheme.Colors.warning, monospaced: false)
        }
    }

    private func inlineCapsule(_ s: String, color: Color, monospaced: Bool) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold, design: monospaced ? .monospaced : .default))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14))
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.30), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}

/// Tokenises a paragraph into plain text + entity spans. Strategy:
///   1. Build a list of (range, token) matches for every recognised
///      pattern. Prefer the FIRST match when ranges overlap (rare).
///   2. Walk the paragraph; between matches emit plain-text tokens
///      broken up by whitespace so the WrapLayout can break lines at
///      word boundaries.
fileprivate enum InlineTokenizer {
    // Keep in sync with the category keywords the AI tends to surface.
    // Matches are case-insensitive, whole-word. Extend if users pick
    // category names outside this list and want them capsuled.
    static let categoryKeywords: [String] = [
        "travel", "food", "dining", "restaurants", "groceries",
        "shopping", "clothing",
        "home", "housing", "rent", "mortgage",
        "health", "medical", "pharmacy",
        "education", "tuition",
        "transportation", "transport", "gas", "fuel",
        "entertainment", "streaming", "subscriptions",
        "bills", "utilities",
        "gifts", "donations",
    ]

    // Month names (standalone only). Matching is case-sensitive because
    // the AI writes them capitalised; lowercase "march" as a verb
    // shouldn't get capsule'd.
    static let monthNames: [String] = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
        "Jan", "Feb", "Mar", "Apr", "Jun", "Jul", "Aug", "Sep", "Sept", "Oct", "Nov", "Dec",
    ]

    static func tokenize(_ paragraph: String) -> [InlineToken] {
        guard !paragraph.isEmpty else { return [] }

        // Collect every match across every pattern as NSRange + token kind.
        struct Match {
            let range: NSRange
            let kind: InlineToken
        }
        let ns = paragraph as NSString
        var matches: [Match] = []

        func add(pattern: String, options: NSRegularExpression.Options = [], make: (String) -> InlineToken) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            re.enumerateMatches(in: paragraph, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let r = m?.range else { return }
                let sub = ns.substring(with: r)
                matches.append(Match(range: r, kind: make(sub)))
            }
        }

        // Currency: $1,234 / $1,234.56 / $12k / €200 / 200€ (euro before OR after)
        add(pattern: #"(?:\$|€)\s?-?\d[\d,]*(?:\.\d+)?[kKmMbB]?|\d[\d,]*(?:\.\d+)?\s?€"#) { .amount($0) }
        // Percent: 12% / -36% / 1.5%
        add(pattern: #"-?\d+(?:\.\d+)?%"#) { .percent($0) }
        // Months: April, April 2026, Apr 30th (month component only)
        let monthPattern = "\\b(?:" + monthNames.joined(separator: "|") + ")(?:\\s+\\d{1,2}(?:st|nd|rd|th)?)?(?:,?\\s+\\d{4})?\\b"
        add(pattern: monthPattern) { .month($0) }
        // Categories: word-boundary list
        let catPattern = "\\b(?:" + categoryKeywords.joined(separator: "|") + ")\\b"
        add(pattern: catPattern, options: [.caseInsensitive]) { .category($0) }

        // Resolve overlaps — prefer earlier start, longer span on tie.
        matches.sort {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length > $1.range.length
        }
        var filtered: [Match] = []
        var cursor = 0
        for m in matches {
            if m.range.location >= cursor {
                filtered.append(m)
                cursor = m.range.location + m.range.length
            }
        }

        // Walk the paragraph, emitting plain-text gaps split by whitespace
        // so the WrapLayout can break lines. Entity tokens stay whole.
        var tokens: [InlineToken] = []
        var idx = 0
        for m in filtered {
            if m.range.location > idx {
                let gap = ns.substring(with: NSRange(location: idx, length: m.range.location - idx))
                appendWordTokens(gap, into: &tokens)
            }
            tokens.append(m.kind)
            idx = m.range.location + m.range.length
        }
        if idx < ns.length {
            let tail = ns.substring(with: NSRange(location: idx, length: ns.length - idx))
            appendWordTokens(tail, into: &tokens)
        }

        return tokens
    }

    /// Split a plain-text span into word tokens. Preserves trailing
    /// punctuation on each word so "amount," stays one token (keeps the
    /// comma tight against the preceding word, avoids orphan commas).
    private static func appendWordTokens(_ span: String, into tokens: inout [InlineToken]) {
        // Split on whitespace only; word+punctuation stays together.
        var current = ""
        for ch in span {
            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(.text(current))
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(.text(current)) }
    }
}

// MARK: - Deep Analysis: Wrap Layout
//
// SwiftUI's built-in HStack can't wrap to a new line when content
// exceeds the container's width — it clips or scrolls. For inline
// entity capsules mixed with text we need HTML-style flowing layout:
// pack tokens left-to-right, break to the next line when the next
// token won't fit, repeat. This is ~50 lines of Layout protocol.

// MARK: - Trigger Hover Coordinator (@Observable)
//
// Holds the "days currently highlighted on the chart" set. Lives as an
// @Observable class (not @State Set<Int>) so that writes only invalidate
// views that actually READ `days` in their body. The parent
// AIPredictionView holds an instance but doesn't read `.days`, so its
// body stays inert on hover — only `TriggerHoverHighlight` re-renders.
// Before this, every hover enter/leave pegged CPU because parent body
// re-ran and rebuilt the Chart (60+ marks) + every card.
@MainActor
@Observable
fileprivate final class TriggerHoverCoordinator {
    var days: Set<Int> = []
}

// MARK: - Trigger Hover Highlight (chart overlay Canvas)
//
// Replaces the in-Chart Layer 10 BarMarks/RuleMarks. Drawn via Canvas
// in a `.chartOverlay` so it can use the `ChartProxy` to find the X
// pixel of each highlighted day on the axis. Only this view observes
// `coordinator.days`; hover changes invalidate this view alone,
// leaving the main Chart and the rest of AIPredictionView untouched.
//
// Canvas redraws are extremely cheap (pure CoreGraphics fills) compared
// to rebuilding 60+ Chart marks on every hover event.
fileprivate struct TriggerHoverHighlight: View {
    let coordinator: TriggerHoverCoordinator
    let proxy: ChartProxy

    var body: some View {
        // Reading coordinator.days here registers observation. When the
        // set changes, SwiftUI invalidates ONLY this view.
        let days = coordinator.days
        GeometryReader { geo in
            if !days.isEmpty, let plotFrame = proxy.plotFrame {
                let frame = geo[plotFrame]
                Canvas { ctx, _ in
                    // Full-height vertical bar per matched day. 10pt wide,
                    // matches the old RuleMark(lineWidth: 10) look.
                    for day in days {
                        guard let xPos = proxy.position(forX: day) else { continue }
                        let x = frame.minX + xPos - 5
                        let rect = CGRect(x: x, y: frame.minY, width: 10, height: frame.height)
                        ctx.fill(
                            Path(roundedRect: rect, cornerRadius: 2),
                            with: .color(CentmondTheme.Colors.warning.opacity(0.30))
                        )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Deep Analysis: Equality Gate
//
// Generic wrapper that uses Equatable + `.equatable()` to skip rebuilding
// an entire sub-tree unless one of the supplied keys changed. The content
// closure is `@ViewBuilder` and only runs when body runs — so when the
// gate's == returns true (keys unchanged), SwiftUI skips body entirely
// and the closure never executes. That means `parseAnalysisByTimeframe`,
// `WrapLayout.sizeThatFits`, and the whole `InlineEntityText` tree all
// skip re-evaluation on parent-body invalidations that don't change the
// gate keys (e.g. hover state flips).
//
// Usage:
//
//   EqualityGate(keys: [AnyHashable(text), AnyHashable(timeRange.rawValue)]) {
//       aiReportContent(text)
//   }
//   .equatable()
//
// `.equatable()` is load-bearing — without it SwiftUI ignores the
// Equatable conformance and always calls body. The modifier opts the
// view into SwiftUI's equatable diff path.
fileprivate struct EqualityGate<Content: View>: View, Equatable {
    let keys: [AnyHashable]
    @ViewBuilder let contentBuilder: () -> Content

    static func == (lhs: EqualityGate<Content>, rhs: EqualityGate<Content>) -> Bool {
        lhs.keys == rhs.keys
    }

    var body: some View {
        contentBuilder()
    }
}

fileprivate struct WrapLayout: Layout {
    var hSpacing: CGFloat = 4
    var vSpacing: CGFloat = 4
    /// Vertical alignment of tokens within each line. `.firstTextBaseline`
    /// looks weird because some subviews (capsules) don't report
    /// baselines; `.center` gives consistent visual alignment.
    var rowAlignment: VerticalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentLineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if currentX > 0, currentX + sz.width > maxWidth {
                // line break
                totalHeight += currentLineHeight + vSpacing
                maxLineWidth = max(maxLineWidth, currentX - hSpacing)
                currentX = 0
                currentLineHeight = 0
            }
            currentX += sz.width + hSpacing
            currentLineHeight = max(currentLineHeight, sz.height)
        }
        totalHeight += currentLineHeight
        maxLineWidth = max(maxLineWidth, currentX - hSpacing)
        return CGSize(width: maxWidth == .infinity ? maxLineWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxX = bounds.maxX
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        // First pass: group subviews into lines so we can center each
        // subview vertically within its line's height.
        var lines: [[(Subviews.Element, CGSize)]] = [[]]
        var curX: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if curX > 0, bounds.minX + curX + sz.width > maxX {
                lines.append([])
                curX = 0
            }
            lines[lines.count - 1].append((sv, sz))
            curX += sz.width + hSpacing
        }

        // Second pass: place tokens, vertically centered per-line.
        for line in lines {
            lineHeight = line.map { $0.1.height }.max() ?? 0
            x = bounds.minX
            for (sv, sz) in line {
                let yOffset: CGFloat
                switch rowAlignment {
                case .top:     yOffset = 0
                case .bottom:  yOffset = lineHeight - sz.height
                default:       yOffset = (lineHeight - sz.height) / 2
                }
                sv.place(at: CGPoint(x: x, y: y + yOffset),
                         proposal: ProposedViewSize(width: sz.width, height: sz.height))
                x += sz.width + hSpacing
            }
            y += lineHeight + vSpacing
        }
    }
}
