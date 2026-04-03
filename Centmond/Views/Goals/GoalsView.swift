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
                        goalsSummaryBar

                        if activeGoals.isEmpty && !doneGoals.isEmpty {
                            VStack(spacing: CentmondTheme.Spacing.md) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 32))
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
                goal.currentAmount = goal.targetAmount
                goal.status = .completed
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
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("New Goal")
                        .font(CentmondTheme.Typography.captionMedium)
                }
                .foregroundStyle(CentmondTheme.Colors.accent)
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .padding(.vertical, CentmondTheme.Spacing.sm)
                .background(CentmondTheme.Colors.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
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
                .font(.system(size: 16, weight: .medium))
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
                        .font(.system(size: 10, weight: .semibold))
                    Text("Completed & Archived (\(doneGoals.count))")
                        .font(CentmondTheme.Typography.captionMedium)
                }
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .textCase(.uppercase)
            }
            .buttonStyle(.plain)

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
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            // Header: icon + name + status
            HStack {
                Image(systemName: goal.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)

                Text(goal.name)
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                statusBadge
            }

            // Amount progress
            HStack(alignment: .lastTextBaseline) {
                Text(CurrencyFormat.compact(goal.currentAmount))
                    .font(CentmondTheme.Typography.monoLarge)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()

                Text("of \(CurrencyFormat.compact(goal.targetAmount))")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)

                Spacer()

                Text("\(Int(goal.progressPercentage * 100))%")
                    .font(CentmondTheme.Typography.monoLarge)
                    .foregroundStyle(progressColor)
                    .monospacedDigit()
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(CentmondTheme.Colors.strokeSubtle)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
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

            // Footer: target date + contribution
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

                if let monthly = goal.monthlyContribution, monthly > 0 {
                    Text("\(CurrencyFormat.compact(monthly))/mo")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(CentmondTheme.Spacing.lg)
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
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
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
        return CentmondTheme.Colors.negative
    }

    private func targetDateColor(_ date: Date) -> Color {
        if goal.status != .active { return CentmondTheme.Colors.textTertiary }
        let daysLeft = Calendar.current.dateComponents([.day], from: .now, to: date).day ?? 0
        if daysLeft < 0 { return CentmondTheme.Colors.negative }
        if daysLeft < 30 { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.textTertiary
    }
}
