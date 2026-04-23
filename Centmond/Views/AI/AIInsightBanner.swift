import SwiftUI
import SwiftData

// ============================================================
// MARK: - AI Insight Banner (P4 / P5.2 polish)
// ============================================================
//
// Human-first card for a single AIInsight. Structure:
//   ┌─────────────────────────────────────────────────┐
//   │ ▌ [icon] Title                    [domain] ⋯    │
//   │ ▌ Warning as a calm lead sentence.              │
//   │ ▌                                               │
//   │ ▌ What to do                                    │
//   │ ▌ Advice line in a subtle tinted block          │
//   │ ▌                                               │
//   │ ▌ Why this showed up · timestamp                │
//   │ ▌                                               │
//   │ ▌ [ Primary action ]   Details →                │
//   └─────────────────────────────────────────────────┘
// Left bar is the severity-tinted rail. Domain is a quiet text
// chip. Action plumbing still routes through AIInsightEngine.
// ============================================================

struct AIInsightBanner: View {
    let insight: AIInsight
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil
    var onMuteDetector: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedExplainer = false
    @State private var isHovered = false

    private let engine = AIInsightEngine.shared

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Severity rail
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous)
                .fill(severityColor)
                .frame(width: 3)
                .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 10) {
                header
                leadSentence
                adviceBlock(insight.effectiveAdvice)
                metaRow
                if expandedExplainer {
                    explainerBlock
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                // Push actionRow to the bottom of whatever height this card
                // is given by its parent grid. Without the Spacer, cards
                // with shorter lead copy collapse upward and siblings in
                // the same row show misaligned action buttons.
                Spacer(minLength: 0)
                actionRow
            }
            .padding(.vertical, 14)
            .padding(.trailing, 14)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                .strokeBorder(
                    isPinned ? severityColor.opacity(0.4) : DS.Colors.subtext.opacity(0.12),
                    lineWidth: isPinned ? 1.5 : 0.5
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.10 : 0), radius: isHovered ? 12 : 0, y: isHovered ? 4 : 0)
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: iconName)
                .font(CentmondTheme.Typography.heading3.weight(.semibold))
                .foregroundStyle(severityColor)
                .frame(width: 22, height: 22)
                .background(severityColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(insight.title)
                    .font(CentmondTheme.Typography.bodyLarge.weight(.semibold))
                    .foregroundStyle(DS.Colors.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(severityLabel)
                        .font(CentmondTheme.Typography.overlineSemibold)
                        .foregroundStyle(severityColor)
                    Text("·").foregroundStyle(DS.Colors.subtext.opacity(0.5))
                    Text(insight.domain.displayName)
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(DS.Colors.subtext)
                }
            }

            Spacer(minLength: 4)

            if isPinned {
                Image(systemName: "pin.fill")
                    .font(CentmondTheme.Typography.micro.weight(.semibold))
                    .foregroundStyle(severityColor)
            }

            moreMenu
        }
    }

    // MARK: - Body sections

    private var leadSentence: some View {
        Text(insight.warning)
            .font(CentmondTheme.Typography.caption)
            .foregroundStyle(DS.Colors.text.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
    }

    private func adviceBlock(_ advice: String) -> some View {
        let hasRealAdvice = insight.advice?.isEmpty == false
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: hasRealAdvice ? "sparkles" : "lightbulb")
                .font(CentmondTheme.Typography.overlineSemibold)
                .foregroundStyle(severityColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasRealAdvice ? "What to do" : "Good to know")
                    .font(CentmondTheme.Typography.micro.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(severityColor.opacity(0.85))
                Text(advice)
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(DS.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                .fill(severityColor.opacity(0.07))
        )
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let cause = insight.cause, !cause.isEmpty {
                Image(systemName: "info.circle")
                    .font(CentmondTheme.Typography.micro)
                    .foregroundStyle(DS.Colors.subtext.opacity(0.7))
                Text(cause)
                    .font(CentmondTheme.Typography.captionSmall)
                    .foregroundStyle(DS.Colors.subtext)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("·").foregroundStyle(DS.Colors.subtext.opacity(0.5))
            }
            Image(systemName: "clock")
                .font(CentmondTheme.Typography.micro)
                .foregroundStyle(DS.Colors.subtext.opacity(0.7))
            Text("Spotted \(relativeTime)")
                .font(CentmondTheme.Typography.captionSmall)
                .foregroundStyle(DS.Colors.subtext)

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expandedExplainer.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: expandedExplainer ? "chevron.up" : "questionmark.circle")
                        .font(CentmondTheme.Typography.micro.weight(.semibold))
                    Text(expandedExplainer ? "Hide" : "Why this?")
                        .font(CentmondTheme.Typography.overline)
                }
                .foregroundStyle(DS.Colors.subtext)
            }
            .buttonStyle(.plain)
            .help(detectorExplainer)
        }
    }

    private var explainerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How Centmond spotted this")
                .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(DS.Colors.subtext)
            Text(detectorExplainer)
                .font(CentmondTheme.Typography.captionSmall)
                .foregroundStyle(DS.Colors.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .fill(DS.Colors.subtext.opacity(0.06))
        )
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if !insight.primaryActionLabel.isEmpty {
                Button {
                    engine.apply(insight, router: router, context: modelContext)
                } label: {
                    HStack(spacing: 5) {
                        Text(insight.primaryActionLabel)
                        Image(systemName: "arrow.right")
                            .font(CentmondTheme.Typography.micro.weight(.bold))
                    }
                    .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [severityColor, severityColor.opacity(0.82)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                    .shadow(color: severityColor.opacity(0.25), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
            }

            if insight.deeplink != nil, !insight.primaryActionLabel.isEmpty {
                Button {
                    if let dl = insight.deeplink { router.follow(dl) }
                } label: {
                    HStack(spacing: 3) {
                        Text("View details")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(CentmondTheme.Typography.captionSmall.weight(.medium))
                    .foregroundStyle(DS.Colors.subtext)
                }
                .buttonStyle(.plain)
                .help("Jump to the data that triggered this insight")
            }

            Spacer()
        }
    }

    // MARK: - More menu

    private var moreMenu: some View {
        Menu {
            if let onTogglePin {
                Button(isPinned ? "Unpin" : "Pin to top", systemImage: isPinned ? "pin.slash" : "pin") {
                    onTogglePin()
                }
                Divider()
            }
            Menu("Remind me later") {
                Button("Tomorrow") {
                    engine.dismiss(insight, context: modelContext, snoozeDays: 1)
                }
                Button("In a week") {
                    engine.dismiss(insight, context: modelContext, snoozeDays: 7)
                }
                Button("In a month") {
                    engine.dismiss(insight, context: modelContext, snoozeDays: 30)
                }
            }
            Divider()
            if let onMuteDetector {
                Button("Stop showing this type", systemImage: "bell.slash") {
                    onMuteDetector()
                }
            }
            Button("Dismiss", role: .destructive) {
                engine.dismiss(insight, context: modelContext, snoozeDays: nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(CentmondTheme.Typography.captionSmallSemibold)
                .foregroundStyle(DS.Colors.subtext)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Derived display

    private var iconName: String {
        switch insight.kind {
        case .budgetWarning:        return "exclamationmark.triangle"
        case .spendingAnomaly:      return "exclamationmark.circle"
        case .savingsOpportunity:   return "lightbulb"
        case .recurringDetected:    return "repeat.circle"
        case .weeklyReport:         return "calendar"
        case .goalProgress:         return "target"
        case .patternDetected:      return "chart.bar"
        case .morningBriefing:      return "sun.max"
        case .subscriptionRenewal:  return "arrow.clockwise.circle"
        case .subscriptionUnused:   return "zzz"
        case .cashflowRisk:         return "drop.triangle"
        case .duplicateTransaction: return "doc.on.doc"
        case .netWorthDrop:         return "arrow.down.right.circle"
        case .netWorthMilestone:    return "flag.checkered"
        case .netWorthStagnant:     return "pause.circle"
        case .householdImbalance:   return "arrow.left.arrow.right.circle"
        case .householdUnpaidShare: return "clock.arrow.circlepath"
        case .householdUnattributedRecurring: return "person.crop.circle.badge.questionmark"
        case .householdSpenderSpike: return "person.crop.circle.fill.badge.exclamationmark"
        }
    }

    private var severityColor: Color {
        switch insight.severity {
        case .critical: return DS.Colors.danger
        case .warning:  return DS.Colors.warning
        case .watch:    return DS.Colors.accent
        case .positive: return DS.Colors.positive
        }
    }

    /// Friendly severity phrasing — warmer than raw enum labels.
    private var severityLabel: String {
        switch insight.severity {
        case .critical: return "Needs your attention"
        case .warning:  return "Worth a look"
        case .watch:    return "Heads up"
        case .positive: return "Good news"
        }
    }

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(insight.timestamp)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86_400)
        if days < 7 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: insight.timestamp)
    }

    private var detectorExplainer: String { insight.detectorExplainer }
}

// MARK: - Effective advice

extension AIInsight {
    /// The advice string to render on the card. Falls back to a kind-specific
    /// friendly default when the detector didn't provide one, so every card
    /// has a "What to do" / "Good to know" block and cards line up visually.
    /// Callers can still distinguish real vs. fallback via `advice != nil`.
    var effectiveAdvice: String {
        if let a = advice, !a.isEmpty { return a }
        switch kind {
        case .budgetWarning:        return "Open your budget and decide what to cut, move, or accept."
        case .spendingAnomaly:      return "Tap through to today's transactions and make sure nothing looks wrong."
        case .savingsOpportunity:   return "Open the suggestion to see the numbers and decide if it's worth acting on."
        case .recurringDetected:    return "Confirm it happened, reschedule it, or cancel it — whichever fits."
        case .weeklyReport:         return "Skim your week — one or two choices now save you a fire-drill later."
        case .goalProgress:         return "Keep the momentum — even a small top-up moves the needle."
        case .patternDetected:      return "Open the transaction and categorize it so Centmond learns your pattern."
        case .morningBriefing:      return "Glance at today's expected bills before you start spending."
        case .subscriptionRenewal:  return "If you still use it, nothing to do. If not, cancel before the charge."
        case .subscriptionUnused:   return "Cancel it if you've moved on — or mark it kept to silence this nudge."
        case .cashflowRisk:         return "Review upcoming bills and hold off on discretionary spend until income lands."
        case .duplicateTransaction: return "Open the transactions and delete the duplicate if they're the same charge."
        case .netWorthDrop:         return "Check which accounts moved and whether it's a real loss or a balance that hasn't updated."
        case .netWorthMilestone:    return "Nice work. Keep the habit — automate the next contribution if you can."
        case .netWorthStagnant:     return "Your balances have barely moved in weeks. Update them or rethink your savings rate."
        case .householdImbalance:           return "Log a settlement in the household hub — it'll clear the open shares and zero the ledger."
        case .householdUnpaidShare:         return "Open Settle Up and work through the oldest pending shares — or waive the ones you'll never collect."
        case .householdUnattributedRecurring: return "Open each recurring template and assign a payer so future auto-created transactions inherit it."
        case .householdSpenderSpike:        return "Scan the member's recent transactions for a big one-off purchase or a new subscription before treating this as a real shift."
        }
    }
}

// MARK: - Detector explainers

extension AIInsight {
    /// Plain-English description of what triggered this insight,
    /// surfaced as hover tooltip + "Why this?" disclosure on each card.
    /// Written in second person, warm tone, ends with an example when it helps.
    var detectorExplainer: String {
        switch kind {
        case .budgetWarning:
            return "Your spending in a category, or for the whole month, has crossed the budget you set — or is pacing to cross it before the month ends."
        case .spendingAnomaly:
            return "Today's total spending is meaningfully higher than your recent 30-day average. Usually it means one big charge, a busy day, or a subscription you forgot about."
        case .savingsOpportunity:
            return "Centmond noticed a recurring cost or pattern that looks reducible — like a subscription you never use or a category creeping up month over month."
        case .recurringDetected:
            return "A scheduled recurring entry you set up is now 3+ days past when it was supposed to hit. Either confirm it happened, reschedule it, or cancel it."
        case .weeklyReport:
            return "A seven-day recap of your cashflow, top categories, and anything worth acting on this coming week."
        case .goalProgress:
            return "A savings goal needs a nudge — it might be close to finishing, running late, stalled for weeks, or you have unallocated income that could go toward it."
        case .patternDetected:
            return "A new merchant you've never paid before just charged a sizable amount, or an unusual pattern appeared in your transactions."
        case .morningBriefing:
            return "Your morning overview — expected bills today, current runway, and the one or two things that deserve attention before the day starts."
        case .subscriptionRenewal:
            return "A subscription you have on file is renewing in the next few days. Pause or cancel it now if you don't want the charge."
        case .subscriptionUnused:
            return "A subscription you're still paying for hasn't shown a matching transaction in 60+ days. Might be a silent cost that's safe to cancel."
        case .cashflowRisk:
            return "Your current balance divided by your recent average daily spending shows a short runway. Below 14 days is critical, below 30 is tight."
        case .duplicateTransaction:
            return "Two transactions share the same payee, amount, and near-identical date — typically a double-charge, a duplicate import, or a manual re-entry you forgot about."
        case .netWorthDrop:
            return "Your net worth fell by more than 5% over the last 30 days. Usually it's a market dip, a large purchase, or new debt — worth a glance to confirm nothing's broken."
        case .netWorthMilestone:
            return "Centmond noticed something worth celebrating in your net-worth history — crossing a round number, hitting an all-time high, or pulling debt down."
        case .netWorthStagnant:
            return "Your net worth has barely moved (±2%) for the last 60+ days. If you expected growth, check whether income is being absorbed by spending or sitting idle."
        case .householdImbalance:
            return "One member is owed more than the threshold in open split shares. Recording a settlement will clear the oldest owed shares automatically."
        case .householdUnpaidShare:
            return "Split shares have been marked owed for more than 30 days. Either money really did change hands (settle it) or the household never planned to collect (waive)."
        case .householdUnattributedRecurring:
            return "Your household has multiple members, but several active recurring templates have no payer. Future materialized transactions inherit the payer — leaving it blank drifts per-member totals."
        case .householdSpenderSpike:
            return "One household member's share of this month's spending is both over 50% of the total AND at least 2x their 3-month average. Usually a big one-off purchase, worth a glance."
        }
    }
}

// MARK: - Dashboard Insight Row

struct AIInsightRow: View {
    let insights: [AIInsight]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(insights.prefix(5)) { insight in
                    AIInsightBanner(insight: insight)
                        .frame(width: 320)
                }
            }
            .padding(.horizontal)
        }
    }
}
