import SwiftUI
import SwiftData

/// Rules editor for a single goal. Create, edit, toggle, and delete
/// `GoalAllocationRule` rows. Rules never apply silently — they only produce
/// proposals in `AllocationRuleEngine` that the user confirms elsewhere.
struct GoalAllocationRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let goal: Goal

    @Query private var rules: [GoalAllocationRule]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var editingRule: GoalAllocationRule?
    @State private var isCreatingRule = false

    init(goal: Goal) {
        self.goal = goal
        let goalID = goal.id
        _rules = Query(
            filter: #Predicate<GoalAllocationRule> { $0.goal?.id == goalID },
            sort: [SortDescriptor(\.priority, order: .reverse), SortDescriptor(\.createdAt)]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(CentmondTheme.Colors.strokeSubtle)
            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    if rules.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 1) {
                            ForEach(rules) { rule in
                                ruleRow(rule)
                            }
                        }
                        .background(CentmondTheme.Colors.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
                    }

                    Button {
                        isCreatingRule = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add rule")
                            Spacer()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(CentmondTheme.Spacing.lg)
            }
        }
        .frame(width: 560, height: 520)
        .background(CentmondTheme.Colors.bgPrimary)
        .sheet(isPresented: $isCreatingRule) {
            RuleEditSheet(goal: goal, rule: nil, categories: categories)
        }
        .sheet(item: $editingRule) { rule in
            RuleEditSheet(goal: goal, rule: rule, categories: categories)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
            Image(systemName: "wand.and.rays")
                .font(CentmondTheme.Typography.subheading)
                .foregroundStyle(CentmondTheme.Colors.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-allocation rules")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text("Rules propose contributions. You always confirm before money moves.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
            Spacer()
            Button {
                dismiss()
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

    private var emptyState: some View {
        VStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 22))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            Text("No rules yet")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text("Add a rule to route a slice of future income into “\(goal.name)”.")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CentmondTheme.Spacing.xl)
    }

    private func ruleRow(_ rule: GoalAllocationRule) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Toggle("", isOn: Binding(
                get: { rule.isActive },
                set: { rule.isActive = $0; rule.updatedAt = .now }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(ruleTitle(rule))
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(ruleSubtitle(rule))
                    .font(CentmondTheme.Typography.overlineRegular)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                editingRule = rule
            } label: {
                Image(systemName: "pencil")
                    .font(CentmondTheme.Typography.overlineRegular)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plainHover)

            Button {
                modelContext.delete(rule)
            } label: {
                Image(systemName: "trash")
                    .font(CentmondTheme.Typography.overlineRegular)
                    .foregroundStyle(CentmondTheme.Colors.negative)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plainHover)
        }
        .frame(height: 42)
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .opacity(rule.isActive ? 1 : 0.5)
    }

    private func ruleTitle(_ rule: GoalAllocationRule) -> String {
        switch rule.type {
        case .percentOfIncome:
            let pct = (rule.amount as NSDecimalNumber).doubleValue
            return "\(pct.formatted(.number.precision(.fractionLength(0...2))))% of income"
        case .fixedPerIncome:
            return "\(CurrencyFormat.standard(rule.amount)) per income"
        case .fixedMonthly, .roundUpExpense:
            return rule.type.displayName
        }
    }

    private func ruleSubtitle(_ rule: GoalAllocationRule) -> String {
        switch rule.source {
        case .allIncome: return "All income · priority \(rule.priority)"
        case .category:
            let name = categories.first(where: { $0.id.uuidString == rule.sourceMatch })?.name ?? "(unknown)"
            return "Category: \(name) · priority \(rule.priority)"
        case .payee:
            return "Payee: \(rule.sourceMatch ?? "") · priority \(rule.priority)"
        }
    }
}

// MARK: - RuleEditSheet

private struct RuleEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let goal: Goal
    let rule: GoalAllocationRule?
    let categories: [BudgetCategory]

    @State private var type: AllocationRuleType = .percentOfIncome
    @State private var source: AllocationRuleSource = .allIncome
    @State private var matchCategoryID: String?
    @State private var payeeMatch: String = ""
    @State private var amountString: String = ""
    @State private var priorityString: String = "0"

    private var parsedAmount: Decimal? { DecimalInput.parsePositive(amountString) }
    private var parsedPriority: Int { Int(priorityString) ?? 0 }
    private var isValid: Bool {
        guard let a = parsedAmount, a > 0 else { return false }
        if type == .percentOfIncome, a > 100 { return false }
        if source == .category, matchCategoryID == nil { return false }
        if source == .payee, payeeMatch.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return type.isIncomeDriven  // only income-driven types available in Phase 3 UI
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(rule == nil ? "New rule" : "Edit rule")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Spacer()
                Button { dismiss() } label: {
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

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    // Type
                    sectionLabel("Rule type")
                    HStack(spacing: 6) {
                        typeChip(.percentOfIncome, title: "% of income")
                        typeChip(.fixedPerIncome, title: "Fixed $")
                    }

                    // Amount
                    sectionLabel(type == .percentOfIncome ? "Percentage (0–100)" : "Amount ($)")
                    TextField(type == .percentOfIncome ? "10" : "250", text: $amountString)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, CentmondTheme.Spacing.md)
                        .frame(height: 36)
                        .background(CentmondTheme.Colors.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

                    // Source
                    sectionLabel("Applies to")
                    HStack(spacing: 6) {
                        sourceChip(.allIncome, title: "All income")
                        sourceChip(.category, title: "Category")
                        sourceChip(.payee, title: "Payee")
                    }

                    if source == .category {
                        sectionLabel("Category")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(categories.filter { !$0.isExpenseCategory }) { cat in
                                    Button {
                                        matchCategoryID = cat.id.uuidString
                                    } label: {
                                        Text(cat.name)
                                            .font(CentmondTheme.Typography.captionSmall.weight(.medium))
                                            .padding(.horizontal, 10)
                                            .frame(height: 24)
                                            .background(matchCategoryID == cat.id.uuidString
                                                        ? CentmondTheme.Colors.accent.opacity(0.2)
                                                        : CentmondTheme.Colors.bgTertiary)
                                            .foregroundStyle(matchCategoryID == cat.id.uuidString
                                                             ? CentmondTheme.Colors.accent
                                                             : CentmondTheme.Colors.textSecondary)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plainHover)
                                }
                            }
                        }
                    }

                    if source == .payee {
                        sectionLabel("Payee (case-insensitive)")
                        TextField("e.g. Acme Corp", text: $payeeMatch)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .padding(.horizontal, CentmondTheme.Spacing.md)
                            .frame(height: 36)
                            .background(CentmondTheme.Colors.bgSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                    }

                    sectionLabel("Priority (higher runs first)")
                    TextField("0", text: $priorityString)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.mono.weight(.semibold))
                        .padding(.horizontal, CentmondTheme.Spacing.md)
                        .frame(height: 36)
                        .background(CentmondTheme.Colors.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                }
                .padding(CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button(rule == nil ? "Create" : "Save") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.4)
            }
            .padding(CentmondTheme.Spacing.lg)
        }
        .frame(width: 480, height: 560)
        .background(CentmondTheme.Colors.bgPrimary)
        .onAppear(perform: hydrate)
    }

    // MARK: - Chips

    private func typeChip(_ t: AllocationRuleType, title: String) -> some View {
        Button { type = t } label: {
            Text(title)
                .font(CentmondTheme.Typography.captionSmallSemibold)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(type == t ? CentmondTheme.Colors.accent : CentmondTheme.Colors.bgTertiary)
                .foregroundStyle(type == t ? .white : CentmondTheme.Colors.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plainHover)
    }

    private func sourceChip(_ s: AllocationRuleSource, title: String) -> some View {
        Button { source = s } label: {
            Text(title)
                .font(CentmondTheme.Typography.captionSmallSemibold)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(source == s ? CentmondTheme.Colors.accent.opacity(0.2) : CentmondTheme.Colors.bgTertiary)
                .foregroundStyle(source == s ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plainHover)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(CentmondTheme.Typography.captionMedium)
            .foregroundStyle(CentmondTheme.Colors.textTertiary)
            .textCase(.uppercase)
            .tracking(0.3)
    }

    // MARK: - Hydrate / Save

    private func hydrate() {
        guard let rule else { return }
        type = rule.type
        source = rule.source
        matchCategoryID = rule.source == .category ? rule.sourceMatch : nil
        payeeMatch = rule.source == .payee ? (rule.sourceMatch ?? "") : ""
        amountString = DecimalInput.editableString(rule.amount)
        priorityString = String(rule.priority)
    }

    private func save() {
        guard let amount = parsedAmount else { return }
        let match: String?
        switch source {
        case .allIncome: match = nil
        case .category: match = matchCategoryID
        case .payee: match = payeeMatch.trimmingCharacters(in: .whitespaces)
        }
        if let existing = rule {
            existing.type = type
            existing.source = source
            existing.sourceMatch = match
            existing.amount = amount
            existing.priority = parsedPriority
            existing.updatedAt = .now
        } else {
            let new = GoalAllocationRule(
                goal: goal,
                type: type,
                source: source,
                sourceMatch: match,
                amount: amount,
                priority: parsedPriority,
                isActive: true
            )
            modelContext.insert(new)
        }
        dismiss()
    }
}
