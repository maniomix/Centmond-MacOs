import SwiftUI
import SwiftData

// ============================================================
// MARK: - AI Proactive View (Phase 6)
// ============================================================
//
// Displays proactive AI items as dismissable cards.
// Shows morning briefings, budget risks, upcoming bills,
// unusual spending alerts, and more -- sorted by severity.
//
// macOS Centmond: ModelContext instead of Store, @Observable,
// no presentation detents, macOS toolbar placements.
//
// ============================================================

struct AIProactiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private let engine = AIProactiveEngine.shared

    @State private var expandedItemId: UUID? = nil
    @State private var showChat: Bool = false
    @State private var showIngestion: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if engine.items.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(engine.items) { item in
                            proactiveCard(item)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .opacity.combined(with: .scale(scale: 0.9))
                                ))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(DS.Colors.bg)
            .navigationTitle("Proactive Feed")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Text("\(engine.activeCount) item(s)")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.subtext)
                }
            }
            .onAppear {
                engine.clearStaleDismissals()
                engine.refresh(context: context)
            }
            .sheet(isPresented: $showChat) {
                AIChatView()
            }
            .sheet(isPresented: $showIngestion) {
                AIIngestionView()
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // ======================================================
    // MARK: - Proactive Card
    // ======================================================

    @ViewBuilder
    private func proactiveCard(_ item: ProactiveItem) -> some View {
        let isExpanded = expandedItemId == item.id
        let hasSections = !item.sections.isEmpty

        VStack(alignment: .leading, spacing: 10) {
            // -- Header row --
            HStack(spacing: 10) {
                Image(systemName: item.type.icon)
                    .font(CentmondTheme.Typography.subheading)
                    .foregroundStyle(severityColor(item.severity))
                    .frame(width: 28, height: 28)
                    .background(severityColor(item.severity).opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(DS.Typography.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(DS.Colors.text)
                    Text(item.summary)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                severityBadge(item.severity)
            }

            // -- Detail text --
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.subtext.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // -- Expandable sections (briefing/review) --
            if hasSections {
                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(item.sections) { section in
                            sectionView(section)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        expandedItemId = isExpanded ? nil : item.id
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show Less" : "Show Details")
                            .font(DS.Typography.caption)
                            .fontWeight(.medium)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(CentmondTheme.Typography.overlineSemibold)
                    }
                    .foregroundStyle(DS.Colors.accent)
                }
                .buttonStyle(.plain)
            }

            // -- Action + Dismiss row --
            HStack(spacing: 10) {
                if let action = item.action, !action.isDismissOnly {
                    Button {
                        handleAction(item: item, action: action)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: action.icon)
                                .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
                            Text(action.label)
                                .font(DS.Typography.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(DS.Colors.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        engine.dismiss(item.id)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(CentmondTheme.Typography.captionSmallSemibold.weight(.bold))
                        .foregroundStyle(DS.Colors.subtext)
                        .padding(6)
                        .background(DS.Colors.subtext.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .strokeBorder(severityColor(item.severity).opacity(0.25), lineWidth: 1)
        )
    }

    // ======================================================
    // MARK: - Section View (Briefing / Review)
    // ======================================================

    private func sectionView(_ section: BriefingSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: section.icon)
                    .font(CentmondTheme.Typography.captionSmallSemibold)
                    .foregroundStyle(severityColor(section.severity))
                Text(section.title)
                    .font(DS.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DS.Colors.text)
            }

            ForEach(section.lines, id: \.self) { line in
                Text(line)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.subtext)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                .fill(severityColor(section.severity).opacity(0.06))
        )
    }

    // ======================================================
    // MARK: - Empty State
    // ======================================================

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(DS.Colors.positive)
            Text("All Clear")
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.text)
            Text("No proactive items right now.\nEverything looks good!")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.subtext)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // ======================================================
    // MARK: - Helpers
    // ======================================================

    private func severityColor(_ severity: ProactiveSeverity) -> Color {
        switch severity {
        case .critical: return DS.Colors.danger
        case .warning:  return DS.Colors.warning
        case .info:     return DS.Colors.accent
        case .positive: return DS.Colors.positive
        }
    }

    private func severityBadge(_ severity: ProactiveSeverity) -> some View {
        Text(severity.rawValue.capitalized)
            .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
            .foregroundStyle(severityColor(severity))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(severityColor(severity).opacity(0.12), in: Capsule())
    }

    private func handleAction(item: ProactiveItem, action: ProactiveAction) {
        engine.markActedOn(item.id)

        switch action.kind {
        case .startWorkflow:
            // TODO: open AIWorkflowView when ported
            break
        case .openChat:
            showChat = true
        case .openIngestion:
            showIngestion = true
        case .dismissOnly:
            withAnimation { engine.dismiss(item.id) }
        }
    }
}

// ======================================================
// MARK: - Dashboard Proactive Banner
// ======================================================

/// Compact banner for dashboard -- shows top proactive items horizontally.
struct AIProactiveBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    private let engine = AIProactiveEngine.shared

    var onOpenFeed: (() -> Void)? = nil
    var onOpenChat: (() -> Void)? = nil

    var body: some View {
        let top = engine.topItems
        if !top.isEmpty || engine.morningBriefing != nil {
            VStack(alignment: .leading, spacing: 8) {
                // Morning briefing as priority banner
                if let briefing = engine.morningBriefing {
                    briefingBanner(briefing)
                }

                // Top alerts as horizontal scroll
                if !top.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(top) { item in
                                compactCard(item)
                                    .frame(width: 260)
                            }

                            // "See all" pill
                            if engine.activeCount > top.count {
                                Button {
                                    onOpenFeed?()
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("+\(engine.activeCount - top.count) more")
                                            .font(DS.Typography.caption)
                                            .fontWeight(.semibold)
                                        Image(systemName: "chevron.right")
                                            .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
                                    }
                                    .foregroundStyle(DS.Colors.accent)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(DS.Colors.accent.opacity(0.1), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // -- Briefing Banner --

    private func briefingBanner(_ item: ProactiveItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .font(CentmondTheme.Typography.bodyLarge.weight(.semibold))
                    .foregroundStyle(DS.Colors.warning)
                Text(item.title)
                    .font(DS.Typography.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(DS.Colors.text)
                Spacer()
                Button {
                    withAnimation { engine.dismiss(item.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
                        .foregroundStyle(DS.Colors.subtext)
                }
                .buttonStyle(.plain)
            }

            Text(item.summary)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.subtext)

            if !item.sections.isEmpty {
                HStack(spacing: 8) {
                    ForEach(item.sections.prefix(3)) { section in
                        HStack(spacing: 3) {
                            Image(systemName: section.icon)
                                .font(CentmondTheme.Typography.micro)
                            Text(section.title)
                                .font(CentmondTheme.Typography.overline)
                        }
                        .foregroundStyle(severityColor(section.severity))
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                .strokeBorder(DS.Colors.warning.opacity(0.2), lineWidth: 1)
        )
    }

    // -- Compact Card --

    private func compactCard(_ item: ProactiveItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: item.type.icon)
                    .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
                    .foregroundStyle(severityColor(item.severity))
                Text(item.title)
                    .font(DS.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DS.Colors.text)
                    .lineLimit(1)
                Spacer()
                Button {
                    withAnimation { engine.dismiss(item.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(CentmondTheme.Typography.micro.weight(.bold))
                        .foregroundStyle(DS.Colors.subtext)
                }
                .buttonStyle(.plain)
            }

            Text(item.summary)
                .font(CentmondTheme.Typography.captionSmall)
                .foregroundStyle(DS.Colors.subtext)
                .lineLimit(2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .strokeBorder(severityColor(item.severity).opacity(0.2), lineWidth: 1)
        )
    }

    private func severityColor(_ severity: ProactiveSeverity) -> Color {
        switch severity {
        case .critical: return DS.Colors.danger
        case .warning:  return DS.Colors.warning
        case .info:     return DS.Colors.accent
        case .positive: return DS.Colors.positive
        }
    }
}
