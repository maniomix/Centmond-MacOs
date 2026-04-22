import SwiftUI
import SwiftData

// ============================================================
// MARK: - Insights Hub (P5)
// ============================================================
//
// Single surface for every insight the engine emits. Grouped
// by severity, filterable by domain, searchable, with a calm
// empty state when the queue is clear. Supports per-card pin
// and per-detector mute on top of the engine's dismiss/snooze.
//
// Data source: `AIInsightEngine.shared.insights` (in-memory,
// refreshed on launch / scene-active / midnight). The engine
// owns dedupe + dismissals + caps; this view adds pinning
// (persisted via @AppStorage on dedupeKey) and detector mute
// (via InsightTelemetry.setMuted).
// ============================================================

struct InsightsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext

    private let engine = AIInsightEngine.shared

    enum GroupMode: String, CaseIterable, Identifiable {
        case severity, domain, flat
        var id: String { rawValue }
        var label: String {
            switch self {
            case .severity: return "By severity"
            case .domain:   return "By area"
            case .flat:     return "Flat"
            }
        }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case severity, newest, oldest
        var id: String { rawValue }
        var label: String {
            switch self {
            case .severity: return "Severity"
            case .newest:   return "Newest"
            case .oldest:   return "Oldest"
            }
        }
    }

    @State private var filterDomain: AIInsight.Domain?
    @State private var groupMode: GroupMode = .severity
    @State private var sortMode: SortMode = .severity
    @State private var searchQuery: String = ""
    @State private var showGlossary = false
    @State private var refreshToken = 0

    @AppStorage("insights.pinnedKeys") private var pinnedKeysRaw: String = ""

    // MARK: - Derived

    private var pinnedKeys: Set<String> {
        get { Set(pinnedKeysRaw.split(separator: "|").map(String.init)) }
    }

    private func setPinned(_ keys: Set<String>) {
        pinnedKeysRaw = keys.joined(separator: "|")
    }

    private var allInsights: [AIInsight] {
        _ = refreshToken
        return engine.insights
    }

    private var filteredInsights: [AIInsight] {
        var list = allInsights
        if let filterDomain { list = list.filter { $0.domain == filterDomain } }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { ins in
                ins.title.lowercased().contains(q) ||
                ins.warning.lowercased().contains(q) ||
                (ins.advice ?? "").lowercased().contains(q) ||
                (ins.cause ?? "").lowercased().contains(q) ||
                ins.domain.displayName.lowercased().contains(q)
            }
        }
        switch sortMode {
        case .severity:
            list.sort { a, b in
                if a.severity != b.severity { return a.severity < b.severity }
                return a.timestamp > b.timestamp
            }
        case .newest:
            list.sort { $0.timestamp > $1.timestamp }
        case .oldest:
            list.sort { $0.timestamp < $1.timestamp }
        }
        return list
    }

    private var pinnedInsights: [AIInsight] {
        let keys = pinnedKeys
        return filteredInsights.filter { keys.contains($0.dedupeKey) }
    }

    private var unpinnedInsights: [AIInsight] {
        let keys = pinnedKeys
        return filteredInsights.filter { !keys.contains($0.dedupeKey) }
    }

    private var criticalCount: Int { allInsights.filter { $0.severity == .critical }.count }
    private var warningCount:  Int { allInsights.filter { $0.severity == .warning  }.count }
    private var watchCount:    Int { allInsights.filter { $0.severity == .watch    }.count }
    private var positiveCount: Int { allInsights.filter { $0.severity == .positive }.count }

    private var activeDomains: [AIInsight.Domain] {
        AIInsight.Domain.allCases.filter { d in allInsights.contains(where: { $0.domain == d }) }
    }

    // MARK: - Body

    var body: some View {
        content
            .background(CentmondTheme.Colors.bgPrimary)
            .onAppear { engine.refresh(context: modelContext) }
            .sheet(isPresented: $showGlossary) {
                InsightGlossarySheet()
            }
    }

    @ViewBuilder
    private var content: some View {
        if allInsights.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider().background(CentmondTheme.Colors.strokeSubtle)
                summaryStrip
                Divider().background(CentmondTheme.Colors.strokeSubtle)

                ScrollView {
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                        if !pinnedInsights.isEmpty {
                            pinnedSection
                        }
                        groupedBody
                        if filteredInsights.isEmpty {
                            noMatchesState
                        }
                    }
                    .padding(.horizontal, CentmondTheme.Spacing.lg)
                    .padding(.vertical, CentmondTheme.Spacing.lg)
                }
            }
        }
    }

    // MARK: - Toolbar (search + sort + group + glossary + refresh)

    private var toolbar: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                TextField("Search insights", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.caption)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(CentmondTheme.Colors.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
            .frame(maxWidth: 240)

            Spacer()

            Menu {
                Picker("Group", selection: $groupMode) {
                    ForEach(GroupMode.allCases) { m in Text(m.label).tag(m) }
                }
                Picker("Sort", selection: $sortMode) {
                    ForEach(SortMode.allCases) { m in Text(m.label).tag(m) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(groupMode.label)
                        .font(CentmondTheme.Typography.caption)
                }
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                showGlossary = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("What are these?")
                        .font(CentmondTheme.Typography.caption)
                }
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
            .buttonStyle(.plainHover)

            Button {
                engine.refresh(context: modelContext)
                refreshToken &+= 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .buttonStyle(.plainHover)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
    }

    // MARK: - Summary strip

    private var summaryStrip: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            summaryChip(count: criticalCount, label: "Needs action", tint: CentmondTheme.Colors.negative, icon: "exclamationmark.octagon.fill")
            summaryChip(count: warningCount,  label: "Worth a look", tint: CentmondTheme.Colors.warning,  icon: "exclamationmark.triangle.fill")
            summaryChip(count: watchCount,    label: "Keep an eye",  tint: CentmondTheme.Colors.accent,   icon: "eye.fill")
            summaryChip(count: positiveCount, label: "Going well",   tint: CentmondTheme.Colors.positive, icon: "checkmark.seal.fill")

            Spacer()

            if activeDomains.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        filterChip(label: "All areas", domain: nil)
                        ForEach(activeDomains, id: \.self) { d in
                            filterChip(label: d.displayName, domain: d)
                        }
                    }
                }
                .frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgSecondary.opacity(0.5))
    }

    private func summaryChip(count: Int, label: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(count)")
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(count > 0 ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textTertiary)
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(count > 0 ? 0.08 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
    }

    private func filterChip(label: String, domain: AIInsight.Domain?) -> some View {
        let isActive = filterDomain == domain
        return Button {
            withAnimation(CentmondTheme.Motion.micro) { filterDomain = domain }
        } label: {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(isActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isActive ? CentmondTheme.Colors.accent.opacity(0.12) : CentmondTheme.Colors.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
        }
        .buttonStyle(.plainHover)
    }

    // MARK: - Grouped body

    @ViewBuilder
    private var groupedBody: some View {
        switch groupMode {
        case .severity:
            section("Needs your attention", insights: unpinnedInsights.filter { $0.severity == .critical }, tint: CentmondTheme.Colors.negative)
            section("Worth a look",         insights: unpinnedInsights.filter { $0.severity == .warning  }, tint: CentmondTheme.Colors.warning)
            section("Heads up",             insights: unpinnedInsights.filter { $0.severity == .watch    }, tint: CentmondTheme.Colors.accent)
            section("Good news",            insights: unpinnedInsights.filter { $0.severity == .positive }, tint: CentmondTheme.Colors.positive)
        case .domain:
            ForEach(activeDomains, id: \.self) { d in
                let items = unpinnedInsights.filter { $0.domain == d }
                if !items.isEmpty {
                    section(d.displayName, insights: items, tint: CentmondTheme.Colors.accent)
                }
            }
        case .flat:
            if !unpinnedInsights.isEmpty {
                grid(unpinnedInsights)
            }
        }
    }

    // MARK: - Pinned section

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.accent)
                Text("Pinned")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text("\(pinnedInsights.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(CentmondTheme.Colors.accent.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
            }
            grid(pinnedInsights)
        }
    }

    // MARK: - Section

    @ViewBuilder
    private func section(_ title: String, insights: [AIInsight], tint: Color) -> some View {
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("\(insights.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.12))
                        .clipShape(Capsule())
                    Spacer()
                }
                grid(insights)
            }
        }
    }

    private func grid(_ insights: [AIInsight]) -> some View {
        let keys = pinnedKeys
        return LazyVGrid(columns: [
            GridItem(.flexible(minimum: 280), spacing: CentmondTheme.Spacing.md, alignment: .top),
            GridItem(.flexible(minimum: 280), spacing: CentmondTheme.Spacing.md, alignment: .top)
        ], alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            ForEach(insights) { insight in
                AIInsightBanner(
                    insight: insight,
                    isPinned: keys.contains(insight.dedupeKey),
                    onTogglePin: { togglePin(insight) },
                    onMuteDetector: { muteDetector(insight) }
                )
            }
        }
    }

    // MARK: - Actions

    private func togglePin(_ insight: AIInsight) {
        var keys = pinnedKeys
        if keys.contains(insight.dedupeKey) {
            keys.remove(insight.dedupeKey)
        } else {
            keys.insert(insight.dedupeKey)
        }
        setPinned(keys)
    }

    private func muteDetector(_ insight: AIInsight) {
        InsightTelemetry.shared.setMuted(insight.detectorID, muted: true)
        engine.refresh(context: modelContext)
        refreshToken &+= 1
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(CentmondTheme.Colors.positive.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(CentmondTheme.Colors.positive)
            }

            VStack(spacing: 6) {
                Text("You're all caught up")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                Text("Nothing needs attention right now. Keep logging transactions and Centmond will surface anything worth acting on — budget slips, unused subscriptions, cashflow risks, and more.")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: CentmondTheme.Spacing.md) {
                Button {
                    engine.refresh(context: modelContext)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                        Text("Check again")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    showGlossary = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text("What does Centmond watch for?")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            Text("No insights match your search.")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Domain display names

extension AIInsight.Domain {
    var displayName: String {
        switch self {
        case .budget:       return "Budget"
        case .subscription: return "Subscriptions"
        case .goal:         return "Goals"
        case .recurring:    return "Recurring"
        case .anomaly:      return "Anomalies"
        case .cashflow:     return "Cashflow"
        case .duplicate:    return "Duplicates"
        case .netWorth:     return "Net Worth"
        case .household:    return "Household"
        }
    }
}

// ============================================================
// MARK: - Insight Glossary Sheet
// ============================================================

struct InsightGlossarySheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let domain: String
        let body: String
        let tint: Color
    }

    private var entries: [Entry] {
        [
            Entry(icon: "drop.triangle",         title: "Low runway",             domain: "Cashflow",      body: "How many days your current balance covers spending at your 30-day average. We warn below 30 days and flag critical below 14.", tint: CentmondTheme.Colors.negative),
            Entry(icon: "arrow.down.right",      title: "Income drop",            domain: "Cashflow",      body: "This month's income is down 30% or more compared to your 3-month average.", tint: CentmondTheme.Colors.warning),
            Entry(icon: "exclamationmark.triangle", title: "Budget warning",      domain: "Budget",        body: "You've crossed a category or overall monthly budget, or you're pacing ahead of it.", tint: CentmondTheme.Colors.warning),
            Entry(icon: "exclamationmark.circle", title: "Day spike",             domain: "Anomalies",     body: "Today's spending is 3× or more your 30-day average and at least $25.", tint: CentmondTheme.Colors.warning),
            Entry(icon: "chart.bar",             title: "New large merchant",    domain: "Anomalies",     body: "A payee you've never seen before charged $100 or more in the last 3 days.", tint: CentmondTheme.Colors.accent),
            Entry(icon: "doc.on.doc",            title: "Duplicate transaction",  domain: "Duplicates",    body: "Two transactions share the same payee, amount, and date — likely a double-charge.", tint: CentmondTheme.Colors.warning),
            Entry(icon: "zzz",                   title: "Unused subscription",    domain: "Subscriptions", body: "An active subscription hasn't had a matching transaction in 60+ days.", tint: CentmondTheme.Colors.warning),
            Entry(icon: "arrow.up.right",        title: "Price hike",             domain: "Subscriptions", body: "A subscription raised its price by 5% or more in the last 60 days.", tint: CentmondTheme.Colors.warning),
            Entry(icon: "square.on.square",      title: "Duplicate subscriptions", domain: "Subscriptions", body: "Two or more active subscriptions share the same merchant.", tint: CentmondTheme.Colors.warning),
            Entry(icon: "arrow.clockwise.circle", title: "Renewal coming",        domain: "Subscriptions", body: "A subscription renews in the next few days.", tint: CentmondTheme.Colors.accent),
            Entry(icon: "repeat.circle",         title: "Overdue recurring",      domain: "Recurring",     body: "A scheduled recurring entry is 3+ days past its expected date.", tint: CentmondTheme.Colors.warning),
            Entry(icon: "target",                title: "Goal progress",          domain: "Goals",         body: "A savings goal is almost there, overdue, stalled, or you have unallocated income.", tint: CentmondTheme.Colors.accent),
            Entry(icon: "sun.max",               title: "Morning briefing",       domain: "Cashflow",      body: "Your daily overview of expected bills, runway, and today's plan.", tint: CentmondTheme.Colors.accent),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What Centmond watches for")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("Every card in your Insights hub is a signal Centmond spotted in your own data — not a generic tip. Here's exactly what each one looks at and when it fires.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(width: 22, height: 22)
                        .background(CentmondTheme.Colors.bgTertiary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(CentmondTheme.Spacing.xl)

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    ForEach(entries) { entry in
                        glossaryRow(entry)
                    }
                }
                .padding(CentmondTheme.Spacing.xl)
            }
        }
        .frame(width: 560, height: 640)
        .background(CentmondTheme.Colors.bgPrimary)
    }

    private func glossaryRow(_ entry: InsightGlossarySheet.Entry) -> some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
            Image(systemName: entry.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(entry.tint)
                .frame(width: 28, height: 28)
                .background(entry.tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text(entry.domain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(CentmondTheme.Colors.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(entry.body)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
    }
}
