import SwiftUI
import SwiftData

struct NewTransactionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \Tag.name) private var existingTags: [Tag]
    @Query(sort: \HouseholdMember.joinedAt) private var members: [HouseholdMember]
    /// Active/trial subscriptions feed the "Link to X subscription?" chip
    /// that appears on entry when date + merchant + amount all align with a
    /// live subscription's next payment.
    @Query private var allSubscriptions: [Subscription]
    /// Powers payee autocomplete + category auto-suggestion. Sorted by
    /// date desc so more-recent entries dominate frequency ties.
    ///
    /// Bounded to the last 365 days — type-ahead needs recent payees, not
    /// full history. Unbounded before: a multi-year database materialized
    /// thousands of Transaction objects on every sheet present even though
    /// >99% of suggestions come from the trailing year.
    @Query(filter: Self.lastYearPredicate, sort: \Transaction.date, order: .reverse)
    private var historicalTransactions: [Transaction]

    /// Static predicate capturing "within the last year". Declared static
    /// so the macro can resolve `Date.now` offset at property-wrapper init.
    private static var lastYearPredicate: Predicate<Transaction> {
        let cutoff = Calendar.current.date(byAdding: .day, value: -365, to: .now) ?? .now
        return #Predicate<Transaction> { $0.date >= cutoff }
    }
    /// Active goals surface in the "Allocate to Goals" panel when income is selected.
    @Query(sort: [SortDescriptor(\Goal.priority, order: .reverse), SortDescriptor(\Goal.createdAt)])
    private var allGoals: [Goal]

    /// Raw cents digits (only digits stored, e.g. "125099" → $1,250.99)
    @State private var rawCents = ""
    @State private var payee = ""
    @State private var selectedCategory: BudgetCategory?
    @State private var selectedAccount: Account?
    @State private var selectedMember: HouseholdMember?
    @State private var date = Date.now
    @State private var showDatePopover = false
    @State private var notes = ""
    @State private var tagsInput = ""
    @State private var isIncome = false
    @State private var status: TransactionStatus = .cleared
    /// `true` means the user explicitly touched the category picker, so
    /// we stop auto-suggesting from payee history (don't clobber their
    /// deliberate choice on every keystroke).
    @State private var categoryManuallyChosen = false
    @State private var appeared = false
    @State private var amountScale: CGFloat = 1.0
    /// Per-goal allocation dollar-strings, keyed by Goal.id. Only populated
    /// when the user is entering an income transaction. Parsed in `allocations`.
    @State private var allocationInput: [UUID: String] = [:]
    /// Rule-engine proposals pending user confirmation. Set after a successful
    /// income insert; presence triggers the AllocationPreviewSheet.
    @State private var pendingPreview: PendingPreview?

    /// Defaults to true — mirrors the reconciliation service's current
    /// behavior (auto-link on match). When the chip is shown and the user
    /// toggles off, `saveTransaction` skips the reconcile call so nothing
    /// gets linked for this one transaction.
    @State private var linkToSubscription: Bool = true

    private struct PendingPreview: Identifiable {
        let id = UUID()
        let transactionID: UUID
        let transactionDate: Date
        let payeeNote: String?
        let proposals: [AllocationProposal]
    }
    @FocusState private var focusedField: FormField?

    private enum FormField: Hashable { case amount, payee, notes, tags }

    private var amountActive: Bool { focusedField == .amount }

    private var isValid: Bool {
        guard !rawCents.isEmpty, !allocationOverLimit else { return false }
        if !TextNormalization.isBlank(payee) { return true }
        // Blank payee is OK when the subscription link chip is present AND the
        // user hasn't turned it off — we'll borrow the subscription's name on
        // save. Mirrors the "Add as Netflix?" suggestion copy.
        return candidateSubscription != nil && linkToSubscription
    }

    /// Active or trial subscription that closely matches the in-progress
    /// transaction. Gates:
    /// - amount within ±10% of the sub's stored amount
    /// - transaction date within ±3 days of `nextPaymentDate`
    /// - if the user has typed a payee, its merchant key must also match
    ///
    /// Deliberately does NOT require a payee — the chip doubles as a
    /// "suggest this is Netflix" affordance so the user can pick up a
    /// pre-made Expense/Amount from a glance at the Subscriptions hub
    /// ("In 5 days, $9.99") and confirm with one tap rather than retyping.
    /// When multiple subs could match, pick whichever's `nextPaymentDate` is
    /// closest to the transaction date.
    private var candidateSubscription: Subscription? {
        guard !isIncome else { return nil }
        guard let amount = decimalAmount, amount > 0 else { return nil }

        let payeeTrimmed = TextNormalization.trimmed(payee)
        let txKey = payeeTrimmed.isEmpty ? nil : Subscription.merchantKey(for: payeeTrimmed)

        let cal = Calendar.current
        let matches: [(sub: Subscription, dateDelta: Int)] = allSubscriptions.compactMap { sub in
            guard sub.status == .active || sub.status == .trial else { return nil }

            // Amount within ±10% of the stored sub amount.
            let baseD = (sub.amount as NSDecimalNumber).doubleValue
            guard baseD > 0 else { return nil }
            let txD = (amount as NSDecimalNumber).doubleValue
            guard abs(txD - baseD) / baseD <= 0.10 else { return nil }

            // Date within ±3 days of nextPaymentDate.
            let delta = abs(cal.dateComponents([.day], from: date, to: sub.nextPaymentDate).day ?? Int.max)
            guard delta <= 3 else { return nil }

            // If the user has typed a payee, it must match (exact or substring).
            // Empty payee = no merchant filter; the chip becomes a suggestion.
            if let tx = txKey, !tx.isEmpty {
                let subKey = sub.merchantKey.isEmpty
                    ? Subscription.merchantKey(for: sub.serviceName)
                    : sub.merchantKey
                let merchantOK = !subKey.isEmpty
                    && (tx == subKey || tx.contains(subKey) || subKey.contains(tx))
                guard merchantOK else { return nil }
            }

            return (sub, delta)
        }

        return matches.min(by: { $0.dateDelta < $1.dateDelta })?.sub
    }

    // MARK: - Goal allocations

    private var activeGoals: [Goal] { allGoals.filter { $0.status == .active } }

    /// Parsed (goal, amount) pairs for any row the user filled in.
    private var allocations: [(goal: Goal, amount: Decimal)] {
        activeGoals.compactMap { g in
            guard let raw = allocationInput[g.id],
                  let amt = DecimalInput.parsePositive(raw) else { return nil }
            return (g, amt)
        }
    }

    private var allocatedTotal: Decimal {
        allocations.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var allocationOverLimit: Bool {
        guard isIncome, let total = decimalAmount, total > 0 else { return false }
        return allocatedTotal > total
    }

    private var allocationRemaining: Decimal {
        max((decimalAmount ?? 0) - allocatedTotal, 0)
    }

    private var filteredCategories: [BudgetCategory] {
        categories.filter { isIncome ? !$0.isExpenseCategory : $0.isExpenseCategory }
    }

    /// "125099" → "1,250.99"
    private var formattedAmount: String {
        guard !rawCents.isEmpty else { return "" }
        let cents = Int(rawCents) ?? 0
        let dollars = cents / 100
        let remainder = cents % 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let dollarsStr = formatter.string(from: NSNumber(value: dollars)) ?? "\(dollars)"
        return String(format: "%@.%02d", dollarsStr, remainder)
    }

    private var decimalAmount: Decimal? {
        guard !rawCents.isEmpty else { return nil }
        return Decimal(Int(rawCents) ?? 0) / 100
    }

    private var amountColor: Color {
        if rawCents.isEmpty { return CentmondTheme.Colors.textTertiary }
        return isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary
    }

    // The hidden TextField binds to this — we intercept and filter to digits only
    @State private var amountInput = ""

    // MARK: - Smart suggestions

    /// Quick-amount presets shown under the amount field when empty.
    /// Values chosen as globally useful round numbers — not derived
    /// from user history (that'd be data-dependent and noisy). If we
    /// ever want "your top 5 amounts", replace this with a computed var.
    private static let quickAmountPresets: [Int] = [5, 10, 20, 50, 100]

    /// Normalised payee key for history matching — lowercase + trimmed.
    private func payeeKey(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unique payee names from history, ranked by recent-frequency.
    /// Filtered by the current `payee` text (prefix OR contains, case-
    /// insensitive). Capped at 3 suggestions so the chip row stays on
    /// one line; types like "S" yield "Starbucks / Spotify / Shell".
    private var payeeSuggestions: [String] {
        let trimmed = payeeKey(payee)
        guard !trimmed.isEmpty else { return [] }
        // Walk historicalTransactions (already date-desc). First occurrence
        // of each payee wins and carries recency; we also dedupe on key.
        var seen = Set<String>()
        var ordered: [String] = []
        for tx in historicalTransactions {
            let key = payeeKey(tx.payee)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            // Match: case-insensitive contains OR prefix. Contains is
            // more forgiving for mid-word typing ("bucks" → Starbucks).
            if key.contains(trimmed) || trimmed.contains(key) {
                seen.insert(key)
                ordered.append(tx.payee)  // original case for display
                if ordered.count >= 3 { break }
            }
        }
        // Exclude the exact current input (user already has it typed).
        return ordered.filter { payeeKey($0) != trimmed }
    }

    /// Most-used category for a given payee based on history. Used when
    /// the user picks a payee suggestion to auto-fill the category.
    private func inferredCategory(for payeeName: String) -> BudgetCategory? {
        let key = payeeKey(payeeName)
        let matches = historicalTransactions.filter { payeeKey($0.payee) == key }
        // Count by category id, find the most-used.
        var tallies: [UUID: Int] = [:]
        for tx in matches {
            if let cat = tx.category { tallies[cat.id, default: 0] += 1 }
        }
        guard let topId = tallies.max(by: { $0.value < $1.value })?.key else { return nil }
        return categories.first(where: { $0.id == topId })
    }

    /// Current-calendar-month spend on the selected category, summed
    /// across its existing transactions. Used by the budget-impact
    /// preview under the category row.
    private func currentMonthSpend(of category: BudgetCategory) -> Decimal {
        let cal = Calendar.current
        let now = Date()
        let (y, m) = (cal.component(.year, from: now), cal.component(.month, from: now))
        return category.transactions.reduce(Decimal.zero) { acc, tx in
            guard !tx.isIncome,
                  cal.component(.year, from: tx.date) == y,
                  cal.component(.month, from: tx.date) == m else { return acc }
            return acc + tx.amount
        }
    }

    /// Human caption for how this pending transaction will affect the
    /// selected category's budget. Returns nil when no category is
    /// chosen or the category has no budget set (nothing to compare to).
    private var budgetImpactCaption: (text: String, color: Color)? {
        guard !isIncome,
              let category = selectedCategory,
              category.budgetAmount > 0,
              let newAmount = decimalAmount else { return nil }
        let current = currentMonthSpend(of: category)
        let afterThis = current + newAmount
        let budget = category.budgetAmount
        let pct = Int((NSDecimalNumber(decimal: afterThis).doubleValue
                       / NSDecimalNumber(decimal: budget).doubleValue * 100).rounded())
        if afterThis > budget {
            let over = afterThis - budget
            return (
                "This puts \(category.name) $\(over.formatted(.number.precision(.fractionLength(0)))) over budget",
                CentmondTheme.Colors.negative
            )
        } else if pct >= 80 {
            return (
                "\(category.name) at \(pct)% of $\(budget.formatted(.number.precision(.fractionLength(0)))) budget",
                CentmondTheme.Colors.warning
            )
        } else {
            return (
                "\(category.name) at \(pct)% of $\(budget.formatted(.number.precision(.fractionLength(0)))) budget",
                CentmondTheme.Colors.textTertiary
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Close chip — simple, right-aligned, no title alongside. The
            // hero amount below IS the visual anchor; a competing title
            // text was making the top of the sheet feel crowded.
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(width: 22, height: 22)
                        .background(CentmondTheme.Colors.bgQuaternary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plainHover)
            }
            .padding(.trailing, CentmondTheme.Spacing.lg)
            .padding(.top, CentmondTheme.Spacing.md)

            // Type + Amount
            VStack(spacing: CentmondTheme.Spacing.md) {
                HStack(spacing: 6) {
                    typeChip("Expense", color: CentmondTheme.Colors.negative, selected: !isIncome) {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            isIncome = false
                            selectedCategory = nil
                        }
                    }
                    typeChip("Income", color: CentmondTheme.Colors.positive, selected: isIncome) {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            isIncome = true
                            selectedCategory = nil
                        }
                    }
                }

                // Amount area — tap to activate
                ZStack {
                    // Hidden TextField — actual input target for amount
                    TextField("", text: $amountInput)
                        .textFieldStyle(.plain)
                        .frame(width: 1, height: 1)
                        .opacity(0.001)
                        .focused($focusedField, equals: .amount)
                        .onChange(of: amountInput) { _, new in
                            let digits = new.filter(\.isNumber)
                            let capped = String(digits.prefix(8))
                            let trimmed = capped.isEmpty ? "" : String(Int(capped) ?? 0)
                            let oldCount = rawCents.count
                            // Animate rawCents change so contentTransition(.numericText) fires
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                rawCents = trimmed
                            }
                            if amountInput != trimmed {
                                amountInput = trimmed
                            }
                            // Scale bounce
                            if trimmed.count > oldCount {
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { amountScale = 1.06 }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { amountScale = 1.0 }
                                }
                            } else if trimmed.count < oldCount {
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { amountScale = 0.95 }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                    withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { amountScale = 1.0 }
                                }
                            }
                        }

                    // Visual display — clean, no background wash.
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("$")
                            .font(.system(size: 36, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)

                        if rawCents.isEmpty {
                            BlinkingCursor(color: amountActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textQuaternary)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(formattedAmount)
                                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(amountColor)
                                    .monospacedDigit()
                                    .contentTransition(.numericText(countsDown: false))
                                    .scaleEffect(amountScale, anchor: .bottom)
                                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isIncome)

                                if amountActive {
                                    BlinkingCursor(color: amountColor)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .amount }
                }
                .frame(height: 50)

                // Quick-amount chips — shown only when no amount yet.
                // Tapping sets the amount in cents and triggers the
                // same bounce animation as typing, so the transition
                // from "empty" to "filled" feels unified.
                if rawCents.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Self.quickAmountPresets, id: \.self) { dollars in
                            Button {
                                Haptics.tap()
                                let cents = String(dollars * 100)
                                amountInput = cents   // flows through .onChange → animations
                                focusedField = .amount
                            } label: {
                                Text("$\(dollars)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                                    .padding(.horizontal, 10)
                                    .frame(height: 24)
                                    .background(CentmondTheme.Colors.bgTertiary)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule().stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plainHover)
                        }
                    }
                    .padding(.top, -4)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(.bottom, CentmondTheme.Spacing.lg)
            .offset(y: appeared ? 0 : 8)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.05), value: appeared)

            // Fields — plain rows in one rounded panel. Icons are simple
            // monochrome SF Symbols on the left. Cleaner and quieter
            // than the colored-pill experiment; matches Apple HIG
            // form conventions.
            VStack(spacing: 1) {
                fieldRow {
                    rowIcon("pencil")
                    TextField("Transaction name", text: $payee)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .focused($focusedField, equals: .payee)
                }

                // Payee autocomplete — inline chip row appears below the
                // name field as the user types. Tap a chip to fill the
                // name AND (if they haven't manually set a category)
                // auto-select the most-used category for that payee. The
                // inference stops once the user explicitly opens the
                // category picker.
                if !payeeSuggestions.isEmpty && focusedField == .payee {
                    payeeSuggestionRow
                }

                customPickerRow(
                    icon: "tag.fill",
                    label: selectedCategory?.name ?? "Uncategorized",
                    options: categoryOptions,
                    selectedID: selectedCategory?.id.uuidString,
                    onSelect: { id in
                        categoryManuallyChosen = true
                        selectedCategory = id.flatMap { idStr in
                            filteredCategories.first(where: { $0.id.uuidString == idStr })
                        }
                    }
                )

                // Budget impact caption — rendered inside the field
                // panel so it visually belongs to the category row
                // above.
                if let impact = budgetImpactCaption {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.pie.fill")
                            .font(.system(size: 10))
                        Text(impact.text)
                            .font(CentmondTheme.Typography.caption)
                    }
                    .foregroundStyle(impact.color)
                    .padding(.horizontal, CentmondTheme.Spacing.md)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                customPickerRow(
                    icon: "creditcard.fill",
                    label: selectedAccount?.name ?? "No account",
                    options: accountOptions,
                    selectedID: selectedAccount?.id.uuidString,
                    onSelect: { id in
                        selectedAccount = id.flatMap { idStr in
                            accounts.first(where: { $0.id.uuidString == idStr })
                        }
                    }
                )

                if !members.isEmpty {
                    customPickerRow(
                        icon: "person.fill",
                        label: selectedMember?.name ?? "Unassigned",
                        options: memberOptions,
                        selectedID: selectedMember?.id.uuidString,
                        onSelect: { id in
                            selectedMember = id.flatMap { idStr in
                                members.first(where: { $0.id.uuidString == idStr })
                            }
                        }
                    )
                }

                datePickerRow(
                    icon: "calendar",
                    label: date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
                )

                // Cleared / Pending pill toggle. Most transactions are
                // cleared at entry time; pending is useful for CC
                // charges that haven't posted yet. Default `.cleared`
                // keeps the fast path fast.
                fieldRow {
                    rowIcon("circle.dotted")
                    Text("Status")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    statusSegment
                }

                fieldRow {
                    rowIcon("note.text")
                    TextField("Note (optional)", text: $notes)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .focused($focusedField, equals: .notes)
                }

                fieldRow {
                    rowIcon("number")
                    TextField("Tags (comma-separated)", text: $tagsInput)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .focused($focusedField, equals: .tags)
                }
            }
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .animation(.easeInOut(duration: 0.2), value: payeeSuggestions)
            .animation(.easeInOut(duration: 0.2), value: budgetImpactCaption?.text)
            // Income↔expense layout changes (category filter swap, budget
            // impact caption toggling) need the same symmetric spring the
            // type chips already use. Without this the fields panel jumps
            // in one direction (income→expense) because the caption
            // removal happens without an animation transaction covering
            // siblings that only depend on isIncome.
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isIncome)
            .offset(y: appeared ? 0 : 8)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.1), value: appeared)

            // Goal allocations — income-only panel for routing some/all of
            // this income into active goals. Writes GoalContributions with
            // .fromIncome kind + this transaction's id on save so deleting
            // the income cascades the goal adjustment back out.
            // Symmetric `asymmetric` transitions so insertion and removal
            // each slide from the same edge — matches the type-chip spring.
            // Earlier `.move(edge: .top)` removed by sliding UP, which
            // looked fine going expense→income (panel slid in from top)
            // but felt abrupt going income→expense (everything below
            // snapped up). Pure opacity + a small scale gives a calm
            // symmetric fade that reads cleanly in both directions.
            if isIncome && !activeGoals.isEmpty {
                goalAllocationPanel
                    .padding(.horizontal, CentmondTheme.Spacing.lg)
                    .padding(.top, CentmondTheme.Spacing.md)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if let sub = candidateSubscription {
                subscriptionLinkChip(for: sub)
                    .padding(.horizontal, CentmondTheme.Spacing.lg)
                    .padding(.top, CentmondTheme.Spacing.md)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            Spacer(minLength: CentmondTheme.Spacing.lg)

            Button { saveTransaction() } label: {
                Text("Add Transaction")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!isValid)
            .opacity(isValid ? 1 : 0.4)
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.bottom, CentmondTheme.Spacing.lg)
            .offset(y: appeared ? 0 : 8)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.15), value: appeared)
        }
        .background(CentmondTheme.Colors.bgPrimary)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                appeared = true
                focusedField = .amount
            }
            // Default payer (P9) — if Settings specifies a default household
            // payer AND the user hasn't picked yet, seed the member picker.
            // Empty/unmatched UUIDs fall through to nil (Unassigned).
            if selectedMember == nil {
                let raw = UserDefaults.standard.string(forKey: "householdDefaultPayerID") ?? ""
                if let uuid = UUID(uuidString: raw),
                   let defaultMember = members.first(where: { $0.id == uuid && $0.isActive }) {
                    selectedMember = defaultMember
                }
            }
        }
        // Auto-suggest category when the payee EXACTLY matches a
        // historical payee (case-insensitive). Only runs if the user
        // hasn't explicitly picked a category — respects manual choice.
        .onChange(of: payee) { _, newPayee in
            guard !categoryManuallyChosen else { return }
            let trimmed = payeeKey(newPayee)
            guard !trimmed.isEmpty else { return }
            let match = historicalTransactions.first { payeeKey($0.payee) == trimmed }
            if let cat = match?.category {
                selectedCategory = cat
            }
        }
        .sheet(item: $pendingPreview) { preview in
            AllocationPreviewSheet(
                transactionID: preview.transactionID,
                transactionDate: preview.transactionDate,
                payeeNote: preview.payeeNote,
                proposals: preview.proposals,
                onComplete: { dismiss() }
            )
        }
    }

    /// Leading icon for a field row. Monochrome, subtle, fixed 16pt
    /// width so text across rows aligns consistently.
    private func rowIcon(_ system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 11))
            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            .frame(width: 16)
    }

    // MARK: - Payee autocomplete row

    /// Inline chip row showing up to three history-derived payees.
    /// Tapping a chip fills `payee` and — only if the user hasn't
    /// explicitly chosen a category yet — auto-selects the most-used
    /// category for that payee from history. Respects user intent:
    /// once `categoryManuallyChosen` is true we stop overriding.
    private var payeeSuggestionRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .frame(width: 16)
            ForEach(payeeSuggestions, id: \.self) { suggestion in
                Button {
                    Haptics.tap()
                    payee = suggestion
                    if !categoryManuallyChosen, let cat = inferredCategory(for: suggestion) {
                        selectedCategory = cat
                    }
                } label: {
                    Text(suggestion)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(CentmondTheme.Colors.accent.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plainHover)
            }
            Spacer()
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, 4)
        .transition(.opacity)
    }

    // MARK: - Goal allocations panel

    private var goalAllocationPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.positive)
                Text("Allocate to Goals")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                Spacer()
                Text(allocationCaption)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(allocationOverLimit ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textTertiary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, CentmondTheme.Spacing.md)
            .padding(.top, CentmondTheme.Spacing.md)
            .padding(.bottom, 6)

            VStack(spacing: 1) {
                ForEach(activeGoals) { goal in
                    goalAllocationRow(goal)
                }
            }
            .padding(.bottom, CentmondTheme.Spacing.sm)
        }
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .stroke(allocationOverLimit ? CentmondTheme.Colors.negative.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private var allocationCaption: String {
        if allocationOverLimit {
            return "Over by \(CurrencyFormat.compact(allocatedTotal - (decimalAmount ?? 0)))"
        }
        guard (decimalAmount ?? 0) > 0, allocatedTotal > 0 else {
            return "Optional"
        }
        return "\(CurrencyFormat.compact(allocationRemaining)) left"
    }

    private func goalAllocationRow(_ goal: Goal) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: goal.icon)
                .font(.system(size: 11))
                .foregroundStyle(CentmondTheme.Colors.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(goal.name)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text("\(Int(goal.progressPercentage * 100))% of \(CurrencyFormat.compact(goal.targetAmount))")
                    .font(.system(size: 10))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            Spacer(minLength: CentmondTheme.Spacing.sm)
            Text("$")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            TextField("0", text: allocationBinding(for: goal))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
        }
        .frame(height: 36)
        .padding(.horizontal, CentmondTheme.Spacing.md)
    }

    private func allocationBinding(for goal: Goal) -> Binding<String> {
        Binding(
            get: { allocationInput[goal.id] ?? "" },
            set: { allocationInput[goal.id] = $0 }
        )
    }

    // MARK: - Status toggle pill

    /// Single tappable pill showing the current status. Click toggles
    /// between `.cleared` ↔ `.pending`. Two-segment design read as two
    /// competing buttons; one-pill-that-changes reads as "the current
    /// status is X, tap to flip."
    private var statusSegment: some View {
        let isCleared = status == .cleared
        let tint = isCleared ? CentmondTheme.Colors.positive : CentmondTheme.Colors.warning
        return Button {
            Haptics.tap()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                status = isCleared ? .pending : .cleared
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(isCleared ? "Cleared" : "Pending")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(tint.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plainHover)
        .help("Tap to toggle status")
    }

    // MARK: - Components

    private func typeChip(_ title: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(selected ? .white : CentmondTheme.Colors.textQuaternary)
                .padding(.horizontal, CentmondTheme.Spacing.xl)
                .frame(height: 28)
                .background(selected ? color : CentmondTheme.Colors.bgTertiary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plainHover)
    }

    private func fieldRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            content()
        }
        .frame(height: 36)
        .padding(.horizontal, CentmondTheme.Spacing.md)
    }

    /// Fully custom picker row — replaces the old Menu-based variant.
    /// Uses `CentmondDropdown` which renders a themed popover list
    /// instead of macOS's native menu chrome.
    private func customPickerRow(
        icon: String,
        label: String,
        options: [CentmondDropdownOption],
        selectedID: String?,
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        CentmondDropdown(options: options, selectedID: selectedID, onSelect: onSelect) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                rowIcon(icon)
                Text(label)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
            .frame(height: 36)
            .padding(.horizontal, CentmondTheme.Spacing.md)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Dropdown option builders

    /// Category options with colored icon dots + "Uncategorized" reset row.
    private var categoryOptions: [CentmondDropdownOption] {
        var opts: [CentmondDropdownOption] = [
            CentmondDropdownOption(
                id: "__reset__",
                name: "Uncategorized",
                iconSystem: "questionmark.circle",
                iconColor: nil,
                isResetOption: true
            )
        ]
        opts.append(contentsOf: filteredCategories.map { cat in
            CentmondDropdownOption(
                id: cat.id.uuidString,
                name: cat.name,
                iconSystem: cat.icon,
                iconColor: Color(hex: cat.colorHex)
            )
        })
        return opts
    }

    private var accountOptions: [CentmondDropdownOption] {
        var opts: [CentmondDropdownOption] = [
            CentmondDropdownOption(id: "__reset__", name: "No account", isResetOption: true)
        ]
        opts.append(contentsOf: accounts.map { acct in
            CentmondDropdownOption(
                id: acct.id.uuidString,
                name: acct.name,
                iconSystem: "creditcard.fill",
                iconColor: CentmondTheme.Colors.accent
            )
        })
        return opts
    }

    private var memberOptions: [CentmondDropdownOption] {
        var opts: [CentmondDropdownOption] = [
            CentmondDropdownOption(id: "__reset__", name: "Unassigned", isResetOption: true)
        ]
        // Only active members show up in the picker. Archived members stay
        // in the store (their historical attribution is preserved) but they
        // must NOT appear as selectable options — otherwise the same name
        // duplicates in the menu for every restore/re-archive cycle.
        opts.append(contentsOf: members.filter(\.isActive).map { m in
            CentmondDropdownOption(
                id: m.id.uuidString,
                name: m.name,
                iconSystem: "person.fill",
                iconColor: CentmondTheme.Colors.accent
            )
        })
        return opts
    }

    /// Date row — Button + `.popover` with a split layout: graphical
    /// calendar on top, modern numeric time picker below. Using a
    /// single `DatePicker([.date, .hourAndMinute]).graphical` renders
    /// an analog CLOCK face for the time component, which looks dated.
    /// Splitting into `.date` (graphical calendar only) + `.hourAndMinute`
    /// (compact field) gives us a month grid + a clean "HH:MM" stepper.
    private func datePickerRow(icon: String, label: String) -> some View {
        Button {
            showDatePopover.toggle()
        } label: {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                rowIcon(icon)
                Text(label)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
            .frame(height: 36)
            .padding(.horizontal, CentmondTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDatePopover) {
            dateTimePopoverContent
        }
    }

    @ViewBuilder
    private var dateTimePopoverContent: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            ModernCalendarPicker(date: $date)

            Divider()

            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Text("Time")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                Spacer()
                CentmondTimePicker(date: $date)
            }
        }
        .padding(CentmondTheme.Spacing.md)
        .frame(width: 280)
    }

    // MARK: - Subscription link chip

    /// Day-of confirmation chip. Shows up only when amount/payee/date all
    /// match an active subscription, reassuring the user the transaction is
    /// about to be linked — or giving them one tap to opt out. Mirrors the
    /// Liquid-Glass styling of the goal allocation panel so the sheet feels
    /// coherent.
    @ViewBuilder
    private func subscriptionLinkChip(for sub: Subscription) -> some View {
        let daysOut = Calendar.current.dateComponents([.day], from: date, to: sub.nextPaymentDate).day ?? 0
        let when: String = {
            if daysOut == 0 { return "today" }
            if daysOut > 0 { return "in \(daysOut)d" }
            return "\(-daysOut)d overdue"
        }()
        // When the user hasn't typed a payee yet, the chip reads as a suggestion
        // ("Add as Netflix?") rather than a confirmation ("Payment for Netflix?")
        // — different intent, different copy.
        let isSuggestion = TextNormalization.isBlank(payee)
        let headline = isSuggestion ? "Add as \(sub.serviceName)?" : "Payment for \(sub.serviceName)?"
        HStack(spacing: CentmondTheme.Spacing.md) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CentmondTheme.Colors.accent)
                .frame(width: 28, height: 28)
                .background(CentmondTheme.Colors.accent.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text("Renews \(when) · \(CurrencyFormat.standard(sub.amount))")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $linkToSubscription)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(CentmondTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .fill(CentmondTheme.Colors.bgSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .stroke(CentmondTheme.Colors.accent.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Save

    private func saveTransaction() {
        Haptics.impact()
        guard let amount = decimalAmount, amount > 0 else { return }

        // When the subscription link chip is shown + toggled ON, borrow the
        // subscription's serviceName for the payee (and category, when the
        // user hasn't picked one) so an empty sheet can be confirmed with
        // one tap. Fills happen here instead of on @State directly so the
        // user's in-progress edits are never clobbered mid-typing.
        let linkedSub = (candidateSubscription != nil && linkToSubscription) ? candidateSubscription : nil
        let resolvedPayee: String = {
            let typed = TextNormalization.trimmed(payee)
            if !typed.isEmpty { return typed }
            return linkedSub?.serviceName ?? ""
        }()
        guard !resolvedPayee.isEmpty else { return }
        let trimmedPayee = resolvedPayee

        var resolvedCategory = selectedCategory
        if resolvedCategory == nil, let sub = linkedSub {
            let target = TextNormalization.trimmed(sub.categoryName)
            resolvedCategory = categories.first { TextNormalization.equalsNormalized($0.name, target) }
        }
        let transaction = Transaction(
            date: date,
            payee: trimmedPayee,
            amount: amount,
            notes: TextNormalization.trimmedOrNil(notes),
            isIncome: isIncome,
            status: status,
            account: selectedAccount,
            category: resolvedCategory
        )
        modelContext.insert(transaction)
        transaction.householdMember = selectedMember
        // Auto-split new expenses across the household (P9 Settings toggle).
        // Skipped for income and transfers — those aren't shared costs.
        let autoSplit = UserDefaults.standard.bool(forKey: "householdAutoSplitNewExpenses")
        if autoSplit, !isIncome, !transaction.isTransfer, members.filter(\.isActive).count >= 2 {
            HouseholdService.applyEqualSplit(
                to: transaction,
                members: members.filter(\.isActive),
                in: modelContext
            )
        }
        let resolved = TagService.resolve(input: tagsInput, in: modelContext, existing: existingTags)
        if !resolved.isEmpty {
            transaction.tags = resolved
        }
        if let account = selectedAccount {
            BalanceService.recalculate(account: account)
        }

        // Try to link this transaction to an existing active Subscription.
        // Idempotent — safe to call repeatedly; the service guards against
        // re-linking via the SubscriptionCharge.transactionID lookup.
        // If the confirm chip was shown and the user toggled it off, skip
        // reconciliation for THIS transaction only — respecting their opt-out.
        let skipLink = (candidateSubscription != nil) && !linkToSubscription
        if !skipLink {
            SubscriptionReconciliationService.reconcile(transaction: transaction, in: modelContext)
        }

        // Route income slices into goals. `allocations` already filters to
        // rows > 0 and `allocationOverLimit` is gated by isValid so we can
        // trust the total here without re-validating.
        if isIncome {
            for (goal, amount) in allocations {
                GoalContributionService.addContribution(
                    to: goal,
                    amount: amount,
                    kind: .fromIncome,
                    date: date,
                    note: trimmedPayee,
                    sourceTransactionID: transaction.id,
                    context: modelContext
                )
            }

            // Rule engine proposes additional contributions on top of any
            // manual ones. User MUST confirm in the preview sheet before
            // anything is written — never auto-apply.
            let proposals = AllocationRuleEngine.proposals(
                for: transaction,
                alreadyAllocated: allocatedTotal,
                context: modelContext
            )
            if !proposals.isEmpty {
                pendingPreview = PendingPreview(
                    transactionID: transaction.id,
                    transactionDate: date,
                    payeeNote: trimmedPayee,
                    proposals: proposals
                )
                return // dismiss happens after the sheet completes
            }
        }
        dismiss()
    }
}

// MARK: - Blinking Cursor

private struct BlinkingCursor: View {
    let color: Color
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2.5, height: 32)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible = false }
    }
}
