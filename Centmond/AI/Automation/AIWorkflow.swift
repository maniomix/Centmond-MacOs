import Foundation
import SwiftData

// ============================================================
// MARK: - AI Workflow Engine
// ============================================================
//
// Multi-step workflow system that lets the AI execute
// structured, checkpointed, multi-action tasks safely.
//
// Supports:
//   - ordered step execution with progress tracking
//   - approval checkpoints (pause when risky)
//   - failure + retry per step
//   - trust system integration
//   - grouped audit trail
//   - 4 built-in workflow types
//
// macOS Centmond: @Observable instead of ObservableObject,
// ModelContext instead of Store, Decimal instead of cents.
// AIMerchantMemory stubbed until P8.
//
// ============================================================

// MARK: - Workflow Types

enum WorkflowType: String, Codable, CaseIterable, Identifiable {
    case cleanupUncategorized = "cleanup_uncategorized"
    case budgetRescue         = "budget_rescue"
    case monthlyClose         = "monthly_close"
    case subscriptionReview   = "subscription_review"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanupUncategorized: return "Cleanup Transactions"
        case .budgetRescue:         return "Budget Rescue"
        case .monthlyClose:         return "Monthly Close"
        case .subscriptionReview:   return "Subscription Review"
        }
    }

    var icon: String {
        switch self {
        case .cleanupUncategorized: return "tag.fill"
        case .budgetRescue:         return "lifepreserver.fill"
        case .monthlyClose:         return "calendar.badge.checkmark"
        case .subscriptionReview:   return "repeat"
        }
    }

    var subtitle: String {
        switch self {
        case .cleanupUncategorized: return "Find and fix uncategorized transactions"
        case .budgetRescue:         return "Rebalance over-budget categories"
        case .monthlyClose:         return "Review, clean up, and plan ahead"
        case .subscriptionReview:   return "Review recurring charges and optimize"
        }
    }
}

enum WorkflowStatus: String, Codable {
    case running
    case paused
    case completed
    case failed
    case cancelled
}

// MARK: - Workflow Model

struct AIWorkflow: Identifiable {
    let id: UUID
    let type: WorkflowType
    var status: WorkflowStatus
    var steps: [AIWorkflowStep]
    var currentStepIndex: Int
    let startedAt: Date
    var updatedAt: Date
    var completedAt: Date?
    let title: String
    let summary: String
    let groupId: UUID

    var currentStep: AIWorkflowStep? {
        guard currentStepIndex >= 0, currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }

    var isComplete: Bool { status == .completed }
    var isPaused: Bool { status == .paused }

    var progress: Double {
        guard !steps.isEmpty else { return 1.0 }
        let done = steps.filter { $0.status == .completed || $0.status == .skipped }.count
        return Double(done) / Double(steps.count)
    }

    var completedStepCount: Int {
        steps.filter { $0.status == .completed }.count
    }
}

// MARK: - Workflow Step

enum WorkflowStepKind: String, Codable {
    case analyze
    case autoExecute
    case review
    case apply
    case summary
}

enum WorkflowStepStatus: String, Codable {
    case pending
    case running
    case awaitingApproval
    case completed
    case failed
    case skipped
}

struct AIWorkflowStep: Identifiable {
    let id: UUID
    let title: String
    let icon: String
    let kind: WorkflowStepKind
    var status: WorkflowStepStatus = .pending
    var requiresApproval: Bool
    var isRetryable: Bool
    var resultMessage: String?
    var detailLines: [String] = []
    var error: String?
    var proposedItems: [ProposedItem] = []
    var executedCount: Int = 0
    var skippedCount: Int = 0
    var failedCount: Int = 0
}

struct ProposedItem: Identifiable {
    let id: UUID
    let summary: String
    let detail: String
    var isApproved: Bool
    var isHighConfidence: Bool
    var action: AIAction?
    var amount: Double?
    var categoryKey: String?
}

// MARK: - Workflow Engine

@MainActor @Observable
final class AIWorkflowEngine {
    static let shared = AIWorkflowEngine()

    var activeWorkflow: AIWorkflow?

    private init() {}

    // MARK: - Public API

    func start(_ type: WorkflowType, context: ModelContext) {
        let groupId = UUID()

        let workflow: AIWorkflow
        switch type {
        case .cleanupUncategorized:
            workflow = buildCleanupWorkflow(context: context, groupId: groupId)
        case .budgetRescue:
            workflow = buildBudgetRescueWorkflow(groupId: groupId)
        case .monthlyClose:
            workflow = buildMonthlyCloseWorkflow(groupId: groupId)
        case .subscriptionReview:
            workflow = buildSubscriptionReviewWorkflow(groupId: groupId)
        }

        activeWorkflow = workflow
    }

    func toggleItemApproval(_ itemId: UUID) {
        guard var workflow = activeWorkflow,
              workflow.currentStepIndex < workflow.steps.count else { return }

        if let idx = workflow.steps[workflow.currentStepIndex]
            .proposedItems.firstIndex(where: { $0.id == itemId }) {
            workflow.steps[workflow.currentStepIndex].proposedItems[idx].isApproved.toggle()
            activeWorkflow = workflow
        }
    }

    func skipCurrentStep() {
        guard var workflow = activeWorkflow,
              workflow.currentStepIndex < workflow.steps.count else { return }
        workflow.steps[workflow.currentStepIndex].status = .skipped
        workflow.status = .running
        activeWorkflow = workflow
        advanceIfReady()
    }

    func cancel() {
        guard var workflow = activeWorkflow else { return }
        workflow.status = .cancelled
        workflow.updatedAt = Date()
        activeWorkflow = workflow
    }

    func dismiss() {
        activeWorkflow = nil
    }

    // MARK: - Step Advancement

    func markCurrentStepCompleted(message: String? = nil) {
        guard var workflow = activeWorkflow else { return }
        workflow.steps[workflow.currentStepIndex].status = .completed
        if let message { workflow.steps[workflow.currentStepIndex].resultMessage = message }
        workflow.updatedAt = Date()
        activeWorkflow = workflow
        advanceIfReady()
    }

    func markCurrentStepFailed(_ message: String) {
        guard var workflow = activeWorkflow else { return }
        workflow.steps[workflow.currentStepIndex].status = .failed
        workflow.steps[workflow.currentStepIndex].error = message
        workflow.status = .failed
        workflow.updatedAt = Date()
        activeWorkflow = workflow
    }

    func pauseForApproval(message: String? = nil) {
        guard var workflow = activeWorkflow else { return }
        workflow.steps[workflow.currentStepIndex].status = .awaitingApproval
        if let message { workflow.steps[workflow.currentStepIndex].resultMessage = message }
        workflow.status = .paused
        workflow.updatedAt = Date()
        activeWorkflow = workflow
    }

    private func advanceIfReady() {
        guard var workflow = activeWorkflow else { return }
        let idx = workflow.currentStepIndex

        if idx < workflow.steps.count && workflow.steps[idx].status == .completed || workflow.steps[idx].status == .skipped {
            let nextIdx = idx + 1
            if nextIdx >= workflow.steps.count {
                workflow.status = .completed
                workflow.completedAt = Date()
                workflow.updatedAt = Date()
                activeWorkflow = workflow
                return
            }
            workflow.currentStepIndex = nextIdx
            workflow.updatedAt = Date()
            activeWorkflow = workflow
        }
    }

    // MARK: - Workflow Builders

    private func buildCleanupWorkflow(context: ModelContext, groupId: UUID) -> AIWorkflow {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isIncome && $0.date >= monthStart && $0.date < monthEnd }
        )
        let txns = (try? context.fetch(descriptor)) ?? []
        let uncategorized = txns.filter { $0.category == nil }

        let steps: [AIWorkflowStep] = [
            AIWorkflowStep(id: UUID(), title: "Scan Transactions", icon: "magnifyingglass",
                           kind: .analyze, requiresApproval: false, isRetryable: false),
            AIWorkflowStep(id: UUID(), title: "Auto-Categorize Safe", icon: "bolt.fill",
                           kind: .autoExecute, requiresApproval: false, isRetryable: true),
            AIWorkflowStep(id: UUID(), title: "Review Uncertain", icon: "hand.raised.fill",
                           kind: .review, requiresApproval: true, isRetryable: false),
            AIWorkflowStep(id: UUID(), title: "Apply Reviewed", icon: "checkmark.circle.fill",
                           kind: .apply, requiresApproval: false, isRetryable: true),
            AIWorkflowStep(id: UUID(), title: "Summary", icon: "list.clipboard.fill",
                           kind: .summary, requiresApproval: false, isRetryable: false),
        ]

        return AIWorkflow(
            id: UUID(), type: .cleanupUncategorized, status: .running,
            steps: steps, currentStepIndex: 0,
            startedAt: Date(), updatedAt: Date(),
            title: "Cleanup Transactions",
            summary: "\(uncategorized.count) uncategorized transaction(s) found",
            groupId: groupId
        )
    }

    private func buildBudgetRescueWorkflow(groupId: UUID) -> AIWorkflow {
        let steps: [AIWorkflowStep] = [
            AIWorkflowStep(id: UUID(), title: "Analyze Budget", icon: "chart.bar.fill",
                           kind: .analyze, requiresApproval: false, isRetryable: false),
            AIWorkflowStep(id: UUID(), title: "Prepare Rescue Plan", icon: "wand.and.stars",
                           kind: .review, requiresApproval: true, isRetryable: false),
            AIWorkflowStep(id: UUID(), title: "Apply Changes", icon: "checkmark.circle.fill",
                           kind: .apply, requiresApproval: false, isRetryable: true),
            AIWorkflowStep(id: UUID(), title: "Summary", icon: "list.clipboard.fill",
                           kind: .summary, requiresApproval: false, isRetryable: false),
        ]

        return AIWorkflow(
            id: UUID(), type: .budgetRescue, status: .running,
            steps: steps, currentStepIndex: 0,
            startedAt: Date(), updatedAt: Date(),
            title: "Budget Rescue", summary: "Rebalance over-budget categories",
            groupId: groupId
        )
    }

    private func buildMonthlyCloseWorkflow(groupId: UUID) -> AIWorkflow {
        let steps: [AIWorkflowStep] = [
            AIWorkflowStep(id: UUID(), title: "Cleanup Check", icon: "magnifyingglass",
                           kind: .analyze, requiresApproval: false, isRetryable: false),
            AIWorkflowStep(id: UUID(), title: "Month Review", icon: "chart.pie.fill",
                           kind: .analyze, requiresApproval: false, isRetryable: false),
            AIWorkflowStep(id: UUID(), title: "Next Month Budget", icon: "calendar.badge.plus",
                           kind: .review, requiresApproval: true, isRetryable: false),
            AIWorkflowStep(id: UUID(), title: "Apply Budget", icon: "checkmark.circle.fill",
                           kind: .apply, requiresApproval: false, isRetryable: true),
            AIWorkflowStep(id: UUID(), title: "Summary", icon: "list.clipboard.fill",
                           kind: .summary, requiresApproval: false, isRetryable: false),
        ]

        return AIWorkflow(
            id: UUID(), type: .monthlyClose, status: .running,
            steps: steps, currentStepIndex: 0,
            startedAt: Date(), updatedAt: Date(),
            title: "Monthly Close", summary: "Review, clean up, and plan ahead",
            groupId: groupId
        )
    }

    private func buildSubscriptionReviewWorkflow(groupId: UUID) -> AIWorkflow {
        let steps: [AIWorkflowStep] = [
            AIWorkflowStep(id: UUID(), title: "Scan Subscriptions", icon: "magnifyingglass",
                           kind: .analyze, requiresApproval: false, isRetryable: false),
            AIWorkflowStep(id: UUID(), title: "Review Findings", icon: "hand.raised.fill",
                           kind: .review, requiresApproval: true, isRetryable: false),
            AIWorkflowStep(id: UUID(), title: "Summary", icon: "list.clipboard.fill",
                           kind: .summary, requiresApproval: false, isRetryable: false),
        ]

        return AIWorkflow(
            id: UUID(), type: .subscriptionReview, status: .running,
            steps: steps, currentStepIndex: 0,
            startedAt: Date(), updatedAt: Date(),
            title: "Subscription Review", summary: "Review recurring charges and optimize",
            groupId: groupId
        )
    }
}
