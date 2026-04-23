import SwiftUI
import SwiftData

/// Shown immediately after an income transaction is inserted, when any active
/// rules produced proposals. The user reviews each row, optionally edits the
/// amount, toggles rows off, and confirms. "Apply" writes each enabled row as
/// a `.autoRule` `GoalContribution` with the source transaction's id so the
/// delete pipeline cascades correctly.
///
/// "Skip" dismisses without writing anything — rules never auto-apply.
struct AllocationPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let transactionID: UUID
    let transactionDate: Date
    let payeeNote: String?
    @State var proposals: [AllocationProposal]
    @State private var amountStrings: [UUID: String] = [:]

    var onComplete: (() -> Void)?

    private var enabledTotal: Decimal {
        proposals
            .filter { $0.enabled }
            .reduce(Decimal.zero) { $0 + (parsedAmount(for: $1) ?? $1.amount) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(CentmondTheme.Colors.strokeSubtle)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach($proposals) { $proposal in
                        proposalRow($proposal)
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.vertical, CentmondTheme.Spacing.md)
            }
            Divider().background(CentmondTheme.Colors.strokeSubtle)
            footer
        }
        .frame(width: 520, height: 480)
        .background(CentmondTheme.Colors.bgPrimary)
        .onAppear {
            for p in proposals {
                amountStrings[p.id] = DecimalInput.editableString(p.amount)
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
            Image(systemName: "wand.and.stars")
                .font(CentmondTheme.Typography.subheading)
                .foregroundStyle(CentmondTheme.Colors.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-allocation proposal")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text("Review before anything moves. Toggle off or edit amounts.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
            Spacer()
            Button {
                dismiss()
                onComplete?()
            } label: {
                Image(systemName: "xmark")
                    .font(CentmondTheme.Typography.captionSmallSemibold)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(CentmondTheme.Colors.bgQuaternary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plainHover)
        }
        .padding(CentmondTheme.Spacing.lg)
    }

    private func proposalRow(_ proposal: Binding<AllocationProposal>) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Toggle("", isOn: proposal.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)

            Image(systemName: proposal.wrappedValue.goal.icon)
                .font(CentmondTheme.Typography.captionSmall)
                .foregroundStyle(CentmondTheme.Colors.accent)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(proposal.wrappedValue.goal.name)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(ruleSummary(proposal.wrappedValue.rule))
                    .font(CentmondTheme.Typography.overlineRegular)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: CentmondTheme.Spacing.sm)

            Text("$")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            TextField("0", text: Binding(
                get: { amountStrings[proposal.wrappedValue.id] ?? "" },
                set: { amountStrings[proposal.wrappedValue.id] = $0 }
            ))
                .textFieldStyle(.plain)
                .font(CentmondTheme.Typography.mono.weight(.semibold))
                .foregroundStyle(proposal.wrappedValue.enabled ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textQuaternary)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .disabled(!proposal.wrappedValue.enabled)
        }
        .frame(height: 42)
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgSecondary)
        .opacity(proposal.wrappedValue.enabled ? 1 : 0.55)
    }

    private var footer: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Will move")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Text(CurrencyFormat.standard(enabledTotal))
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(CentmondTheme.Colors.positive)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button("Skip") {
                dismiss()
                onComplete?()
            }
            .buttonStyle(SecondaryButtonStyle())

            Button("Apply") {
                applyProposals()
                dismiss()
                onComplete?()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(enabledTotal <= 0)
            .opacity(enabledTotal > 0 ? 1 : 0.4)
        }
        .padding(CentmondTheme.Spacing.lg)
    }

    // MARK: - Helpers

    private func ruleSummary(_ rule: GoalAllocationRule) -> String {
        let amountText: String
        switch rule.type {
        case .percentOfIncome:
            let pct = (rule.amount as NSDecimalNumber).doubleValue
            amountText = "\(pct.formatted(.number.precision(.fractionLength(0...2))))% of income"
        case .fixedPerIncome:
            amountText = "\(CurrencyFormat.compact(rule.amount)) per income"
        case .fixedMonthly, .roundUpExpense:
            amountText = rule.type.displayName
        }
        switch rule.source {
        case .allIncome:
            return amountText
        case .category:
            return "\(amountText) · category match"
        case .payee:
            return "\(amountText) · payee “\(rule.sourceMatch ?? "")”"
        }
    }

    private func parsedAmount(for proposal: AllocationProposal) -> Decimal? {
        guard let raw = amountStrings[proposal.id] else { return nil }
        return DecimalInput.parsePositive(raw)
    }

    private func applyProposals() {
        Haptics.impact()
        for proposal in proposals where proposal.enabled {
            let amount = parsedAmount(for: proposal) ?? proposal.amount
            guard amount > 0, let goal = fetchGoal(proposal.goal.id) else { continue }
            GoalContributionService.addContribution(
                to: goal,
                amount: amount,
                kind: .autoRule,
                date: transactionDate,
                note: payeeNote,
                sourceTransactionID: transactionID,
                context: modelContext
            )
        }
    }

    /// Rule engine returned model objects owned by a short-lived fetch; re-resolve
    /// from the current context so we're writing to live instances.
    private func fetchGoal(_ id: UUID) -> Goal? {
        let descriptor = FetchDescriptor<Goal>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }
}
