import SwiftUI
import SwiftData

// ============================================================
// MARK: - AI Workflow View (Phase 4)
// ============================================================
//
// Displays workflow progress with:
//   - workflow selector (when no active workflow)
//   - step-by-step progress with status indicators
//   - current step detail with results + approval toggles
//   - skip / cancel controls
//   - completion summary
//
// macOS Centmond: @Observable singletons, ModelContext,
// no runNextStep/approveAndContinue/retryCurrentStep
// (engine simplified on macOS), DS.Card replaced.
//
// ============================================================

struct AIWorkflowView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let engine = AIWorkflowEngine.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                if let workflow = engine.activeWorkflow {
                    workflowContent(workflow)
                } else {
                    workflowSelector
                }
            }
            .background(DS.Colors.bg)
            .navigationTitle(engine.activeWorkflow?.title ?? "Workflows")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DS.Colors.subtext)
                    }
                    .buttonStyle(.plain)
                }
                if let wf = engine.activeWorkflow,
                   wf.status == .running || wf.status == .paused {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            engine.cancel()
                        } label: {
                            Text("Cancel")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Colors.danger)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 450)
    }

    // ================================================================
    // MARK: - Workflow Selector
    // ================================================================

    private var workflowSelector: some View {
        VStack(spacing: 16) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(DS.Colors.accent)

                Text("AI Workflows")
                    .font(DS.Typography.title)
                    .foregroundStyle(DS.Colors.text)

                Text("Multi-step tasks the AI runs for you.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.subtext)
            }
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Workflow cards
            ForEach(WorkflowType.allCases) { type in
                workflowTypeCard(type)
            }
        }
        .padding()
    }

    private func workflowTypeCard(_ type: WorkflowType) -> some View {
        Button {
            engine.start(type, context: context)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: type.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(DS.Colors.accent)
                    .frame(width: 40, height: 40)
                    .background(DS.Colors.accent.opacity(0.1), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.title)
                        .font(DS.Typography.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(DS.Colors.text)
                    Text(type.subtitle)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.subtext)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Colors.subtext.opacity(0.5))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Colors.surface)
            )
        }
        .buttonStyle(.plain)
    }

    // ================================================================
    // MARK: - Active Workflow Content
    // ================================================================

    private func workflowContent(_ workflow: AIWorkflow) -> some View {
        VStack(spacing: 16) {
            progressBar(workflow)
            stepsTimeline(workflow)
            currentStepDetail(workflow)
        }
        .padding()
    }

    // MARK: Progress Bar

    private func progressBar(_ workflow: AIWorkflow) -> some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DS.Colors.surface)
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(progressColor(workflow.status))
                        .frame(width: max(0, geo.size.width * workflow.progress), height: 8)
                        .animation(.easeInOut(duration: 0.3), value: workflow.progress)
                }
            }
            .frame(height: 8)

            HStack {
                Text(statusLabel(workflow.status))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(progressColor(workflow.status))

                Spacer()

                Text("\(Int(workflow.progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.subtext)
            }
        }
    }

    // MARK: Steps Timeline

    private func stepsTimeline(_ workflow: AIWorkflow) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 12) {
                    // Status circle + connector line
                    VStack(spacing: 0) {
                        stepStatusCircle(step, isCurrent: index == workflow.currentStepIndex)
                        if index < workflow.steps.count - 1 {
                            Rectangle()
                                .fill(step.status == .completed ? DS.Colors.positive.opacity(0.4) : DS.Colors.surface)
                                .frame(width: 2, height: 24)
                        }
                    }

                    // Step info
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(step.title)
                                .font(DS.Typography.callout)
                                .fontWeight(index == workflow.currentStepIndex ? .semibold : .regular)
                                .foregroundStyle(
                                    step.status == .skipped
                                        ? DS.Colors.subtext.opacity(0.5)
                                        : (index == workflow.currentStepIndex ? DS.Colors.text : DS.Colors.subtext)
                                )

                            if step.status == .awaitingApproval {
                                Text("APPROVAL")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(DS.Colors.warning)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(DS.Colors.warning.opacity(0.15), in: Capsule())
                            }
                            if step.status == .failed {
                                Text("FAILED")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(DS.Colors.danger)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(DS.Colors.danger.opacity(0.15), in: Capsule())
                            }
                        }

                        if let msg = step.resultMessage, step.status != .pending {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Colors.subtext)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    if step.executedCount > 0 {
                        Text("\(step.executedCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Colors.positive)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DS.Colors.positive.opacity(0.1), in: Capsule())
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func stepStatusCircle(_ step: AIWorkflowStep, isCurrent: Bool) -> some View {
        ZStack {
            Circle()
                .fill(stepCircleColor(step.status, isCurrent: isCurrent))
                .frame(width: 28, height: 28)

            switch step.status {
            case .completed:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            case .skipped:
                Image(systemName: "forward.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
            case .running:
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.white)
            case .awaitingApproval:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            case .pending:
                Image(systemName: step.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isCurrent ? DS.Colors.accent : DS.Colors.subtext.opacity(0.4))
            }
        }
    }

    // MARK: Current Step Detail

    private func currentStepDetail(_ workflow: AIWorkflow) -> some View {
        Group {
            if workflow.isComplete || workflow.status == .cancelled {
                completionCard(workflow)
            } else if let step = workflow.currentStep {
                stepDetailCard(step, workflow: workflow)
            }
        }
    }

    private func stepDetailCard(_ step: AIWorkflowStep, workflow: AIWorkflow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: step.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(DS.Colors.accent)
                Text(step.title)
                    .font(DS.Typography.section)
                    .foregroundStyle(DS.Colors.text)
            }

            // Detail lines
            if !step.detailLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(step.detailLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Colors.subtext)
                    }
                }
            }

            // Error
            if let error = step.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.danger)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.danger)
                }
            }

            // Proposed items (for review/approval steps)
            if step.status == .awaitingApproval && !step.proposedItems.isEmpty {
                proposedItemsList(step.proposedItems)
            }

            // Action buttons
            actionButtons(step, workflow: workflow)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
    }

    // MARK: Proposed Items

    private func proposedItemsList(_ items: [ProposedItem]) -> some View {
        VStack(spacing: 6) {
            Divider()

            ForEach(items) { item in
                Button {
                    engine.toggleItemApproval(item.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.isApproved ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(item.isApproved ? DS.Colors.accent : DS.Colors.subtext.opacity(0.4))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.summary)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DS.Colors.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(item.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Colors.subtext)
                                .lineLimit(1)
                        }

                        Spacer()

                        if item.isHighConfidence {
                            Text("HIGH")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(DS.Colors.positive)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(DS.Colors.positive.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Action Buttons

    private func actionButtons(_ step: AIWorkflowStep, workflow: AIWorkflow) -> some View {
        HStack(spacing: 12) {
            // Skip (always available unless complete/failed)
            if step.status == .running || step.status == .awaitingApproval || step.status == .pending {
                Button {
                    engine.skipCurrentStep()
                } label: {
                    Text("Skip")
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Colors.subtext)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(DS.Colors.subtext.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            // Mark completed (for awaiting approval -- simplified approve)
            if step.status == .awaitingApproval {
                Button {
                    engine.markCurrentStepCompleted(message: "Approved by user")
                } label: {
                    Text("Approve & Continue")
                        .font(DS.Typography.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Completion Card

    private func completionCard(_ workflow: AIWorkflow) -> some View {
        VStack(spacing: 14) {
            Image(systemName: workflow.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(workflow.status == .completed ? DS.Colors.positive : DS.Colors.subtext)

            Text(workflow.status == .completed ? "Complete!" : "Workflow Cancelled")
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.text)

            // Step results summary
            VStack(alignment: .leading, spacing: 6) {
                ForEach(workflow.steps) { step in
                    if step.status == .completed, let msg = step.resultMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(DS.Colors.positive)
                            Text(msg)
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Colors.subtext)
                        }
                    }
                }
            }

            // Stats
            let executed = workflow.steps.reduce(0) { $0 + $1.executedCount }
            let skipped = workflow.steps.reduce(0) { $0 + $1.skippedCount }
            if executed > 0 || skipped > 0 {
                HStack(spacing: 16) {
                    if executed > 0 {
                        statPill(value: "\(executed)", label: "Changes", color: DS.Colors.positive)
                    }
                    if skipped > 0 {
                        statPill(value: "\(skipped)", label: "Skipped", color: DS.Colors.subtext)
                    }
                }
            }

            Button {
                engine.dismiss()
                dismiss()
            } label: {
                Text("Done")
                    .font(DS.Typography.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
    }

    // ================================================================
    // MARK: - Helpers
    // ================================================================

    private func progressColor(_ status: WorkflowStatus) -> Color {
        switch status {
        case .running:   return DS.Colors.accent
        case .paused:    return DS.Colors.warning
        case .completed: return DS.Colors.positive
        case .failed:    return DS.Colors.danger
        case .cancelled: return DS.Colors.subtext
        }
    }

    private func statusLabel(_ status: WorkflowStatus) -> String {
        switch status {
        case .running:   return "Running..."
        case .paused:    return "Waiting for approval"
        case .completed: return "Complete"
        case .failed:    return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func stepCircleColor(_ status: WorkflowStepStatus, isCurrent: Bool) -> Color {
        switch status {
        case .completed:        return DS.Colors.positive
        case .failed:           return DS.Colors.danger
        case .skipped:          return DS.Colors.subtext
        case .running:          return DS.Colors.accent
        case .awaitingApproval: return DS.Colors.warning
        case .pending:          return isCurrent ? DS.Colors.accent.opacity(0.2) : DS.Colors.surface
        }
    }

    private func statPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.subtext)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
