import Foundation

// ============================================================
// MARK: - Insight Enricher (P7)
// ============================================================
//
// Optional LLM pass that rewrites the top few insights' advice
// lines in a punchier, more conversational tone. Gated on:
//
//   1. `AIInsightEngine.isInsightEnrichmentEnabled` (off by default)
//   2. Model currently `.ready` (never force a cold load just to
//      rewrite advice — heuristic text is good enough)
//
// Runs out-of-band from `refresh`: detectors publish synchronous
// heuristic advice immediately, then this pass swaps in AI-written
// advice when it finishes. Cheap fallback if the model is busy
// or unloaded — the user still sees warnings + heuristic advice,
// they just don't get the polish.
// ============================================================

@MainActor
enum InsightEnricher {

    /// How many insights to enrich per pass. LLM round-trips aren't free
    /// — one token/s per insight adds up — so we cap to the top urgent items.
    private static let enrichBudget = 3

    /// Minimum severity worth enriching. Positives / watches get the default
    /// heuristic advice — they're informational and don't need polish.
    private static let minSeverity: AIInsight.Severity = .warning

    /// System prompt aligned with Centmond's persona conventions: no emoji,
    /// no hedging, no fluff, short concrete directives. Mirrors the
    /// "Quant-Psychologist" guidance for the prediction page but softer —
    /// insights aren't forensics, they're immediate nudges.
    private static let systemPrompt = """
    You are Centmond, a direct financial co-pilot. Rewrite the user's \
    advice line in one punchy sentence, under 80 characters. No emoji. \
    No hedging. No "consider", "maybe", "try to". Use concrete verbs. \
    Keep the specific numbers or names if present. Output only the \
    rewritten line — no preamble, no quotes.
    """

    /// Entry point from `AIInsightEngine.refresh`. Returns a new array with
    /// up to `enrichBudget` insights' `advice` strings replaced. Order and
    /// identity (`id`, `dedupeKey`) are preserved so downstream dedupe /
    /// dismissal behavior isn't affected.
    static func enrich(_ insights: [AIInsight]) async -> [AIInsight] {
        guard shouldRun() else { return insights }

        let candidates = insights
            .enumerated()
            .filter { _, insight in
                insight.severity <= minSeverity && (insight.advice?.isEmpty == false)
            }
            .prefix(enrichBudget)

        guard !candidates.isEmpty else { return insights }

        var result = insights
        for (index, insight) in candidates {
            guard let advice = insight.advice else { continue }
            let prompt = "Warning: \(insight.warning)\nCurrent advice: \(advice)"
            let rewritten = await AIManager.shared.generate(prompt, systemPrompt: systemPrompt)

            let cleaned = rewritten
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !cleaned.isEmpty, cleaned.count <= 140 else { continue }

            result[index] = insight.withAdvice(cleaned)
        }
        return result
    }

    // MARK: - Gating

    private static func shouldRun() -> Bool {
        guard AIInsightEngine.shared.isInsightEnrichmentEnabled else { return false }
        guard case .ready = AIManager.shared.status else { return false }
        guard !AIManager.shared.isGenerating else { return false }
        return true
    }
}

// MARK: - AIInsight: withAdvice

extension AIInsight {
    /// Returns a copy of this insight with `advice` swapped. Used by the
    /// enrichment pass to upgrade the heuristic line without rebuilding
    /// the whole struct at every detector call site.
    func withAdvice(_ newAdvice: String) -> AIInsight {
        AIInsight(
            kind: kind,
            title: title,
            warning: warning,
            severity: severity,
            advice: newAdvice,
            cause: cause,
            expiresAt: expiresAt,
            dedupeKey: dedupeKey,
            suggestedAction: suggestedAction,
            deeplink: deeplink
        )
    }
}
