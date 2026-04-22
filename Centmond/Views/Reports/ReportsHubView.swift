import SwiftUI
import SwiftData

struct ReportsHubView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedReport.updatedAt, order: .reverse) private var saved: [SavedReport]

    let onOpen: (ReportDefinition) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 320), spacing: CentmondTheme.Spacing.lg)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxxl) {
                hero
                if !saved.isEmpty { savedRow }
                if !recent.isEmpty { recentRow }
                templatesSection
            }
            .padding(CentmondTheme.Spacing.xxl)
            .frame(maxWidth: 1100, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(CentmondTheme.Colors.bgPrimary)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text("Reports")
                .font(CentmondTheme.Typography.heading1)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Text("Pick a template to explore your money. Save what you build, export what you share.")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
        }
    }

    // MARK: - Saved presets

    private var savedRow: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            sectionHeader("Saved")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CentmondTheme.Spacing.md) {
                    ForEach(saved) { item in
                        SavedReportCard(
                            saved: item,
                            onRun: {
                                if let def = item.definition {
                                    item.markRun()
                                    try? context.save()
                                    onOpen(def)
                                }
                            },
                            onDelete: {
                                context.delete(item)
                                try? context.save()
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Recently run

    private var recent: [SavedReport] {
        saved
            .filter { $0.lastRunAt != nil }
            .sorted { ($0.lastRunAt ?? .distantPast) > ($1.lastRunAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            sectionHeader("Recently run")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CentmondTheme.Spacing.md) {
                    ForEach(recent) { item in
                        SavedReportCard(
                            saved: item,
                            onRun: {
                                if let def = item.definition {
                                    item.markRun()
                                    try? context.save()
                                    onOpen(def)
                                }
                            },
                            onDelete: {
                                context.delete(item)
                                try? context.save()
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Templates

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            sectionHeader("All templates")

            LazyVGrid(columns: columns, spacing: CentmondTheme.Spacing.lg) {
                ForEach(ReportKind.allCases, id: \.self) { kind in
                    ReportTemplateCard(kind: kind) {
                        var def = ReportDefinition.default
                        def.kind = kind
                        def.range = defaultRange(for: kind)
                        def.groupBy = defaultGroupBy(for: kind)
                        onOpen(def)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(CentmondTheme.Typography.captionMedium)
            .foregroundStyle(CentmondTheme.Colors.textTertiary)
            .tracking(0.5)
    }

    private func defaultRange(for kind: ReportKind) -> ReportDateRange {
        switch kind {
        case .annualSummary, .netWorth: return .preset(.last12Months)
        case .subscriptions, .recurringActivity, .goalsProgress: return .preset(.last3Months)
        default: return .preset(.last6Months)
        }
    }

    private func defaultGroupBy(for kind: ReportKind) -> ReportGroupBy {
        switch kind {
        case .annualSummary: return .quarter
        case .netWorth:      return .month
        default:             return .month
        }
    }
}
