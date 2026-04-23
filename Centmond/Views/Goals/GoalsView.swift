import SwiftUI
import SwiftData

struct GoalsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Goal.createdAt, order: .reverse) private var allGoals: [Goal]

    @State private var showCompleted = false
    @State private var showDeleteConfirmation = false
    @State private var goalToDelete: Goal?

    private var activeGoals: [Goal] { allGoals.filter { $0.status == .active || $0.status == .paused } }
    private var completedGoals: [Goal] { allGoals.filter { $0.status == .completed } }
    private var archivedGoals: [Goal] { allGoals.filter { $0.status == .archived } }
    private var doneGoals: [Goal] { completedGoals + archivedGoals }

    private var totalSaved: Decimal {
        activeGoals.reduce(Decimal.zero) { $0 + $1.currentAmount }
    }

    private var totalTarget: Decimal {
        activeGoals.reduce(Decimal.zero) { $0 + $1.targetAmount }
    }

    private var overallProgress: Double {
        guard totalTarget > 0 else { return 0 }
        return min(Double(truncating: (totalSaved / totalTarget) as NSDecimalNumber), 1.0)
    }

    private var selectedGoalID: UUID? {
        if case .goal(let id) = router.inspectorContext { return id }
        return nil
    }

    var body: some View {
        Group {
            if allGoals.isEmpty {
                EmptyStateView(
                    icon: "target",
                    heading: "No goals yet",
                    description: "Set a financial goal and watch your progress over time.",
                    primaryAction: "Create Goal",
                    onPrimaryAction: { router.showSheet(.newGoal) }
                )
            } else {
                ScrollView {
                    VStack(spacing: CentmondTheme.Spacing.xxl) {
                        SectionTutorialStrip(screen: .goals)
                        goalsSummaryBar

                        unallocatedIncomeBanner

                        if activeGoals.isEmpty && !doneGoals.isEmpty {
                            VStack(spacing: CentmondTheme.Spacing.md) {
                                Image(systemName: "checkmark.circle")
                                    .font(CentmondTheme.Typography.display.weight(.regular))
                                    .foregroundStyle(CentmondTheme.Colors.positive)
                                Text("All goals completed!")
                                    .font(CentmondTheme.Typography.heading3)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                Button("Create New Goal") {
                                    router.showSheet(.newGoal)
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CentmondTheme.Spacing.xxl)
                        } else {
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: CentmondTheme.Spacing.xl),
                                GridItem(.flexible(), spacing: CentmondTheme.Spacing.xl)
                            ], spacing: CentmondTheme.Spacing.xl) {
                                ForEach(activeGoals) { goal in
                                    GoalCard(goal: goal, isSelected: selectedGoalID == goal.id)
                                        .onTapGesture {
                                            router.inspectGoal(goal.id)
                                        }
                                        .contextMenu {
                                            goalContextMenu(for: goal)
                                        }
                                }
                            }
                        }

                        if !doneGoals.isEmpty {
                            completedSection
                        }
                    }
                    .padding(CentmondTheme.Spacing.xxl)
                }
            }
        }
        .alert("Delete Goal", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { goalToDelete = nil }
            Button("Delete", role: .destructive) {
                if let goal = goalToDelete {
                    if case .goal(let id) = router.inspectorContext, id == goal.id {
                        router.inspectorContext = .none
                    }
                    modelContext.delete(goal)
                }
                goalToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete \"\(goalToDelete?.name ?? "")\"? This cannot be undone.")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func goalContextMenu(for goal: Goal) -> some View {
        Button {
            router.inspectGoal(goal.id)
        } label: {
            Label("View Details", systemImage: "eye")
        }

        Button {
            router.showSheet(.editGoal(goal))
        } label: {
            Label("Edit Goal", systemImage: "pencil")
        }

        Divider()

        if goal.status == .active {
            Button {
                goal.status = .paused
            } label: {
                Label("Pause Goal", systemImage: "pause.circle")
            }
            Button {
                let delta = goal.targetAmount - goal.currentAmount
                if delta > 0 {
                    GoalContributionService.addContribution(
                        to: goal,
                        amount: delta,
                        kind: .manual,
                        note: "Marked complete",
                        context: modelContext
                    )
                } else {
                    goal.status = .completed
                }
            } label: {
                Label("Mark as Completed", systemImage: "checkmark.circle")
            }
        }
        if goal.status == .paused {
            Button {
                goal.status = .active
            } label: {
                Label("Resume Goal", systemImage: "play.circle")
            }
        }

        Divider()

        if goal.status != .archived {
            Button {
                withAnimation(CentmondTheme.Motion.layout) {
                    goal.status = .archived
                    if case .goal(let id) = router.inspectorContext, id == goal.id {
                        router.inspectorContext = .none
                    }
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }

        Button(role: .destructive) {
            goalToDelete = goal
            showDeleteConfirmation = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Unallocated income banner

    /// Visible only when there's idle income this month (no GoalContributions
    /// linked to any current-month income tx). Nudges the user to allocate it
    /// by opening the new-transaction sheet. Non-blocking — can be dismissed
    /// implicitly by clearing the queue.
    @ViewBuilder
    private var unallocatedIncomeBanner: some View {
        let unallocated = GoalAnalytics.unallocatedIncomeThisMonth(context: modelContext)
        if unallocated.count > 0, !activeGoals.isEmpty {
            HStack(spacing: CentmondTheme.Spacing.md) {
                Image(systemName: "sparkles")
                    .font(CentmondTheme.Typography.bodyLarge.weight(.semibold))
                    .foregroundStyle(CentmondTheme.Colors.positive)
                    .frame(width: 32, height: 32)
                    .background(CentmondTheme.Colors.positive.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(CurrencyFormat.compact(unallocated.total)) unallocated income this month")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("\(unallocated.count) income transaction\(unallocated.count == 1 ? "" : "s") without goal allocation. Route some of it in with your next entry.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    router.showSheet(.newTransaction)
                } label: {
                    Text("Allocate")
                }
                .buttonStyle(AccentChipButtonStyle())
            }
            .padding(CentmondTheme.Spacing.md)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                    .stroke(CentmondTheme.Colors.positive.opacity(0.3), lineWidth: 1)
            )
        }
    }

    // MARK: - Summary Bar

    private var goalsSummaryBar: some View {
        HStack(spacing: CentmondTheme.Spacing.xxl) {
            summaryItem(
                label: "Active Goals",
                value: "\(activeGoals.count)",
                icon: "target",
                color: CentmondTheme.Colors.accent
            )
            summaryItem(
                label: "Total Saved",
                value: CurrencyFormat.compact(totalSaved),
                icon: "banknote.fill",
                color: CentmondTheme.Colors.positive
            )
            summaryItem(
                label: "Total Target",
                value: CurrencyFormat.compact(totalTarget),
                icon: "flag.fill",
                color: CentmondTheme.Colors.warning
            )
            summaryItem(
                label: "Overall",
                value: "\(Int(overallProgress * 100))%",
                icon: "chart.bar.fill",
                color: overallProgress >= 0.7 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.accent
            )

            Spacer()

            Button {
                router.showSheet(.newGoal)
            } label: {
                Label("New Goal", systemImage: "plus")
            }
            .buttonStyle(AccentChipButtonStyle())
        }
        .padding(CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    private func summaryItem(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            Image(systemName: icon)
                .font(CentmondTheme.Typography.subheading.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Text(value)
                    .font(CentmondTheme.Typography.monoLarge)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Completed/Archived Section

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Button {
                withAnimation(CentmondTheme.Motion.layout) {
                    showCompleted.toggle()
                }
            } label: {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                        .font(CentmondTheme.Typography.overlineSemibold)
                    Text("Completed & Archived (\(doneGoals.count))")
                        .font(CentmondTheme.Typography.captionMedium)
                }
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .textCase(.uppercase)
            }
            .buttonStyle(.plainHover)

            if showCompleted {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: CentmondTheme.Spacing.xl),
                    GridItem(.flexible(), spacing: CentmondTheme.Spacing.xl)
                ], spacing: CentmondTheme.Spacing.xl) {
                    ForEach(doneGoals) { goal in
                        GoalCard(goal: goal, isSelected: selectedGoalID == goal.id)
                            .opacity(0.7)
                            .onTapGesture {
                                router.inspectGoal(goal.id)
                            }
                            .contextMenu {
                                if goal.status == .completed || goal.status == .archived {
                                    Button {
                                        goal.status = .active
                                    } label: {
                                        Label("Reactivate", systemImage: "arrow.uturn.backward")
                                    }
                                }
                                Divider()
                                Button(role: .destructive) {
                                    goalToDelete = goal
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
    }
}

// MARK: - Goal Card

struct GoalCard: View {
    let goal: Goal
    var isSelected: Bool = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            // Header: icon + name + status
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: goal.icon)
                    .font(CentmondTheme.Typography.bodyLarge.weight(.medium))
                    .foregroundStyle(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
                    .frame(width: 18)

                Text(goal.name)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                statusBadge
            }

            // Amount progress — amount is the headline; "of $X" is supporting;
            // percentage is a small pill on the right (not another headline).
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CurrencyFormat.compact(goal.currentAmount))
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()

                Text("of \(CurrencyFormat.compact(goal.targetAmount))")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)

                Spacer()

                Text("\(Int(goal.progressPercentage * 100))%")
                    .font(CentmondTheme.Typography.captionSmallSemibold.monospacedDigit())
                    .foregroundStyle(progressColor)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(progressColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous)
                        .fill(CentmondTheme.Colors.strokeSubtle)

                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [CentmondTheme.Colors.accent, progressColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * min(goal.progressPercentage, 1.0))
                }
            }
            .frame(height: 8)

            // This-month progress row — compares this-month contributions
            // against the stored monthly target (if any). Funding-source
            // chips ride at the trailing edge of the same row so cards
            // never gain an extra row when chips are present (was causing
            // unequal card heights in the grid).
            thisMonthRow

            // Footer: target date + projected completion
            HStack {
                if let targetDate = goal.targetDate {
                    Label {
                        Text(targetDate.formatted(.dateTime.month().year()))
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(targetDateColor(targetDate))
                }

                Spacer()

                if let projected = GoalAnalytics.projectedCompletion(goal), goal.status == .active {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(CentmondTheme.Typography.micro.weight(.medium))
                        Text("~ \(projected.formatted(.dateTime.month().year()))")
                            .monospacedDigit()
                    }
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .help("Projected completion based on the last 3 months' average contribution")
                }
            }
        }
        .padding(CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(
                    isSelected ? CentmondTheme.Colors.accent :
                    isHovered ? CentmondTheme.Colors.strokeDefault : CentmondTheme.Colors.strokeSubtle,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .shadow(color: isHovered ? .black.opacity(0.3) : .clear, radius: 8, y: 2)
        .onHover { hovering in
            if hovering { Haptics.tick() }
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
    }

    private var thisMonthRow: some View {
        let thisMonth = GoalAnalytics.thisMonthContribution(goal)
        let target = goal.monthlyContribution ?? 0
        let hasTarget = target > 0
        let pct: Double = hasTarget
            ? min(Double(truncating: (thisMonth / target) as NSDecimalNumber), 1.0)
            : 0
        let breakdown = GoalAnalytics.breakdownByKind(goal)
        let chipOrder: [GoalContributionKind] = [.fromIncome, .autoRule, .fromTransfer, .manual]
        let visibleChips = chipOrder.filter { (breakdown[$0] ?? 0) > 0 }

        return HStack(spacing: 6) {
            Image(systemName: "calendar.badge.clock")
                .font(CentmondTheme.Typography.overlineRegular)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .frame(width: 12)
            Text("This month")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(CurrencyFormat.compact(thisMonth))
                .font(CentmondTheme.Typography.captionSmallSemibold.monospacedDigit())
                .foregroundStyle(thisMonth > 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textQuaternary)
            if hasTarget {
                Text("of \(CurrencyFormat.compact(target))")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }

            Spacer(minLength: CentmondTheme.Spacing.xs)

            // Funding-source chips ride at the trailing edge so they never
            // create an extra row — keeps cards in the grid equal height
            // regardless of whether a goal has any contribution history yet.
            HStack(spacing: 3) {
                ForEach(visibleChips, id: \.self) { kind in
                    sourceChip(kind: kind, amount: breakdown[kind] ?? 0)
                }
            }

            if hasTarget {
                Text("\(Int(pct * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(pct >= 1 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary)
            }
        }
    }

    private func sourceChip(kind: GoalContributionKind, amount: Decimal) -> some View {
        let color: Color = {
            switch kind {
            case .fromIncome: return CentmondTheme.Colors.positive
            case .autoRule: return CentmondTheme.Colors.accent
            case .fromTransfer: return CentmondTheme.Colors.warning
            case .manual: return CentmondTheme.Colors.textSecondary
            }
        }()
        let icon: String = {
            switch kind {
            case .fromIncome: return "arrow.down.circle.fill"
            case .autoRule: return "wand.and.rays"
            case .fromTransfer: return "arrow.left.arrow.right"
            case .manual: return "hand.tap.fill"
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(CentmondTheme.Typography.microBold.weight(.semibold))
            Text(CurrencyFormat.compact(amount))
                .font(CentmondTheme.Typography.micro.weight(.semibold).monospacedDigit())
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
        .help(kindLabel(kind))
    }

    private func kindLabel(_ k: GoalContributionKind) -> String {
        switch k {
        case .manual: return "Manual"
        case .fromIncome: return "Routed from income"
        case .fromTransfer: return "Transfer from account"
        case .autoRule: return "Auto rule"
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = switch goal.status {
        case .active: ("Active", CentmondTheme.Colors.positive)
        case .paused: ("Paused", CentmondTheme.Colors.warning)
        case .completed: ("Completed", CentmondTheme.Colors.accent)
        case .archived: ("Archived", CentmondTheme.Colors.textTertiary)
        }

        return Text(text)
            .font(CentmondTheme.Typography.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
    }

    private var progressColor: Color {
        let p = goal.progressPercentage
        if p >= 1.0 { return CentmondTheme.Colors.positive }
        if p >= 0.7 { return CentmondTheme.Colors.accent }
        if p >= 0.4 { return CentmondTheme.Colors.warning }
        // Brand-new / low-progress goals shouldn't read as alarming red —
        // a goal at 0% is just a goal that hasn't started, not a failure.
        // Only past-deadline goals get warning treatment via targetDateColor.
        return CentmondTheme.Colors.textSecondary
    }

    private func targetDateColor(_ date: Date) -> Color {
        if goal.status != .active { return CentmondTheme.Colors.textTertiary }
        let daysLeft = Calendar.current.dateComponents([.day], from: .now, to: date).day ?? 0
        if daysLeft < 0 { return CentmondTheme.Colors.negative }
        if daysLeft < 30 { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.textTertiary
    }
}
