import SwiftUI
import SwiftData

// Visual language matches `NewTransactionSheet`:
//   - close chip in the top-right corner
//   - hero amount display (36pt monospaced) at top
//   - compact row-style fields grouped into one rounded background panel
//   - full-width primary button at the bottom
// Earlier version used the traditional "UPPERCASE label above each field
// in its own bordered box" layout that visibly diverged from every other
// sheet — user called it out: "it has to be like other boxes".
struct NewTransferSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    /// Active goals surface alongside accounts in the destination picker so
    /// users can route money directly into a goal.
    @Query(sort: [SortDescriptor(\Goal.priority, order: .reverse), SortDescriptor(\Goal.createdAt)])
    private var allGoals: [Goal]

    /// Raw cents digits (e.g. "125099" → $1,250.99). Mirrors the
    /// NewTransactionSheet amount-entry pattern exactly so the visual
    /// big-amount display can reuse the same formatting / animations.
    @State private var rawCents = ""
    @State private var amountInput = ""
    @State private var amountScale: CGFloat = 1.0
    @State private var fromAccount: Account?
    @State private var toAccount: Account?
    /// Set when the user picks a goal from the destination dropdown. Mutually
    /// exclusive with `toAccount` — picking a goal clears toAccount and vice
    /// versa. Drives the "transfer to goal" branch in `saveTransfer`.
    @State private var toGoal: Goal?
    @State private var date = Date.now
    @State private var showDatePopover = false
    @State private var notes = ""
    @State private var status: TransactionStatus = .cleared
    @State private var saveError: String?
    @State private var appeared = false
    @FocusState private var focusedField: FormField?

    private static let quickAmountPresets: [Int] = [5, 10, 20, 50, 100]

    /// True when the transfer amount exceeds the From account's current
    /// balance. Non-card accounts (checking/savings) would literally
    /// overdraft; card accounts are a soft warning since cards have
    /// credit limits not balance floors. Both surface the same inline
    /// warning below — leaving the user's judgment in charge of
    /// whether to proceed.
    private var exceedsFromBalance: Bool {
        guard let from = fromAccount, let amount = decimalAmount else { return false }
        return amount > from.currentBalance
    }

    private enum FormField: Hashable { case amount, notes }

    private var amountActive: Bool { focusedField == .amount }

    private var decimalAmount: Decimal? {
        guard !rawCents.isEmpty else { return nil }
        return Decimal(Int(rawCents) ?? 0) / 100
    }

    private var formattedAmount: String {
        guard !rawCents.isEmpty else { return "" }
        let cents = Int(rawCents) ?? 0
        let dollars = cents / 100
        let remainder = cents % 100
        let f = NumberFormatter(); f.numberStyle = .decimal
        let dollarsStr = f.string(from: NSNumber(value: dollars)) ?? "\(dollars)"
        return String(format: "%@.%02d", dollarsStr, remainder)
    }

    private var sameAccount: Bool {
        guard let f = fromAccount, let t = toAccount else { return false }
        return f.id == t.id
    }

    private var activeGoals: [Goal] { allGoals.filter { $0.status == .active } }

    private var destinationIsGoal: Bool { toGoal != nil }

    private var isValid: Bool {
        guard decimalAmount != nil, fromAccount != nil else { return false }
        if destinationIsGoal { return true }
        return toAccount != nil && !sameAccount
    }

    var body: some View {
        VStack(spacing: 0) {
            // Close chip — same as NewTransactionSheet.
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

            // Title + hero amount
            VStack(spacing: CentmondTheme.Spacing.sm) {
                Text("Transfer")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .tracking(0.5)
                    .textCase(.uppercase)

                ZStack {
                    // Hidden TextField — actual input target (same pattern as NewTransactionSheet)
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
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                rawCents = trimmed
                            }
                            if amountInput != trimmed { amountInput = trimmed }
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

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("$")
                            .font(.system(size: 36, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)

                        if rawCents.isEmpty {
                            BlinkingCursorTransfer(color: amountActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textQuaternary)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(formattedAmount)
                                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                    .monospacedDigit()
                                    .contentTransition(.numericText(countsDown: false))
                                    .scaleEffect(amountScale, anchor: .bottom)

                                if amountActive {
                                    BlinkingCursorTransfer(color: CentmondTheme.Colors.textPrimary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .amount }
                }
                .frame(height: 50)

                // Quick-amount chips, same pattern as NewTransactionSheet —
                // shown only when empty, routes through amountInput so
                // the bounce animation stays unified.
                if rawCents.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Self.quickAmountPresets, id: \.self) { dollars in
                            Button {
                                Haptics.tap()
                                amountInput = String(dollars * 100)
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

            // Fields — plain rows in one rounded panel. Matches NewTransactionSheet.
            VStack(spacing: 1) {
                customPickerRow(
                    icon: "arrow.up.circle",
                    label: fromAccount?.name ?? "From account",
                    options: accountOptions(placeholder: "From account"),
                    selectedID: fromAccount?.id.uuidString,
                    onSelect: { id in
                        fromAccount = id.flatMap { idStr in
                            accounts.first(where: { $0.id.uuidString == idStr })
                        }
                    }
                )

                // Balance preview for the From account — shown as soon
                // as an account + amount are chosen. "→" shows the
                // after-transfer balance so the user sees the effect
                // before committing. Color flips to negative when the
                // transfer would push the balance below zero.
                if let from = fromAccount {
                    balanceRow(for: from, delta: decimalAmount.map { -$0 } ?? 0, warnIfNegative: true)
                }

                // Tiny swap button between the two account pickers —
                // inverts From/To in one tap. Hidden when destination is a
                // goal (asymmetric — can't swap an account into a goal).
                if fromAccount != nil && toAccount != nil && !destinationIsGoal {
                    HStack {
                        Spacer()
                        Button {
                            Haptics.tap()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                let tmp = fromAccount
                                fromAccount = toAccount
                                toAccount = tmp
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                                .frame(width: 22, height: 22)
                                .background(CentmondTheme.Colors.bgTertiary)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plainHover)
                        .help("Swap From and To")
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }

                customPickerRow(
                    icon: destinationIsGoal ? "target" : "arrow.down.circle",
                    label: destinationLabel,
                    options: destinationOptions(),
                    selectedID: destinationSelectedID,
                    onSelect: { id in selectDestination(id) }
                )

                // Destination preview — balance row for account, or a goal
                // progress row for a goal.
                if let to = toAccount {
                    balanceRow(for: to, delta: decimalAmount ?? 0, warnIfNegative: false)
                } else if let g = toGoal {
                    goalProgressRow(for: g, delta: decimalAmount ?? 0)
                }

                // Insufficient-funds warning — inline below the
                // balance rows when the amount exceeds From's balance.
                // Still lets the user save (their call), but the red
                // banner makes the overdraft visible at a glance.
                if exceedsFromBalance {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("This transfer exceeds \(fromAccount?.name ?? "the source")'s balance")
                            .font(CentmondTheme.Typography.caption)
                    }
                    .foregroundStyle(CentmondTheme.Colors.negative)
                    .padding(.horizontal, CentmondTheme.Spacing.md)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                datePickerRow(
                    icon: "calendar",
                    label: date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
                )

                // Cleared / Pending status — same pattern as
                // NewTransactionSheet. Default `.cleared`.
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
            }
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .animation(.easeInOut(duration: 0.2), value: fromAccount?.id)
            .animation(.easeInOut(duration: 0.2), value: toAccount?.id)
            .animation(.easeInOut(duration: 0.2), value: toGoal?.id)
            .animation(.easeInOut(duration: 0.2), value: exceedsFromBalance)
            .offset(y: appeared ? 0 : 8)
            .opacity(appeared ? 1 : 0)
            .animation(CentmondTheme.Motion.default.delay(0.1), value: appeared)

            // Validation hint — inline, same font as other sheets.
            // Skip same-account warning when destination is a goal (no
            // account-account ambiguity possible in that path).
            if sameAccount && !destinationIsGoal {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text("From and To must differ")
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.warning)
                .padding(.top, CentmondTheme.Spacing.sm)
            }
            if let error = saveError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text(error)
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.negative)
                .padding(.top, CentmondTheme.Spacing.sm)
            }

            Spacer(minLength: CentmondTheme.Spacing.lg)

            Button { saveTransfer() } label: {
                Text("Create Transfer")
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
        }
    }

    private func fieldRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            content()
        }
        .frame(height: 36)
        .padding(.horizontal, CentmondTheme.Spacing.md)
    }

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

    /// Account options for From/To pickers. Placeholder = reset label.
    private func accountOptions(placeholder: String) -> [CentmondDropdownOption] {
        var opts: [CentmondDropdownOption] = [
            CentmondDropdownOption(id: "__reset__", name: placeholder, isResetOption: true)
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

    /// Destination options include every account plus every active goal.
    /// Goal IDs are prefixed with "goal:" so `onSelect` can route them to
    /// `toGoal` instead of `toAccount`.
    private func destinationOptions() -> [CentmondDropdownOption] {
        var opts: [CentmondDropdownOption] = [
            CentmondDropdownOption(id: "__reset__", name: "To account or goal", isResetOption: true)
        ]
        opts.append(contentsOf: accounts.map { acct in
            CentmondDropdownOption(
                id: acct.id.uuidString,
                name: acct.name,
                iconSystem: "creditcard.fill",
                iconColor: CentmondTheme.Colors.accent
            )
        })
        opts.append(contentsOf: activeGoals.map { goal in
            CentmondDropdownOption(
                id: "goal:\(goal.id.uuidString)",
                name: goal.name,
                iconSystem: goal.icon,
                iconColor: CentmondTheme.Colors.positive
            )
        })
        return opts
    }

    private var destinationSelectedID: String? {
        if let g = toGoal { return "goal:\(g.id.uuidString)" }
        return toAccount?.id.uuidString
    }

    private var destinationLabel: String {
        if let g = toGoal { return g.name }
        return toAccount?.name ?? "To account or goal"
    }

    private func selectDestination(_ id: String?) {
        guard let id else {
            toAccount = nil
            toGoal = nil
            return
        }
        if id.hasPrefix("goal:") {
            let uuidString = String(id.dropFirst("goal:".count))
            toGoal = activeGoals.first { $0.id.uuidString == uuidString }
            toAccount = nil
        } else {
            toAccount = accounts.first { $0.id.uuidString == id }
            toGoal = nil
        }
    }

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
    }

    private func rowIcon(_ system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 11))
            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            .frame(width: 16)
    }

    // MARK: - Balance preview

    /// Inline balance line under an account picker row. Shows the
    /// current balance and — if a transfer amount is set — the
    /// balance after this transfer with an arrow between them.
    ///
    ///   From:  $2,450.00 → $1,950.00
    ///   To:    $8,300.00 → $8,800.00
    ///
    /// `delta` is the signed change for this account (negative for
    /// From, positive for To). `warnIfNegative` flips the after-amount
    /// color to negative red when the transfer would drive the balance
    /// below zero.
    private func balanceRow(for account: Account, delta: Decimal, warnIfNegative: Bool) -> some View {
        let after = account.currentBalance + delta
        let amountIsSet = (decimalAmount != nil) && decimalAmount! > 0
        let afterColor: Color = (warnIfNegative && after < 0)
            ? CentmondTheme.Colors.negative
            : (delta > 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary)

        return HStack(spacing: 6) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 10))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .frame(width: 16)
            Text(account.currentBalance.formatted(.currency(code: "USD")))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .monospacedDigit()
            if amountIsSet {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                Text(after.formatted(.currency(code: "USD")))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(afterColor)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, 4)
        .transition(.opacity)
    }

    /// Progress preview for a goal destination — shows current balance, then
    /// post-transfer balance capped at the target. Mirrors `balanceRow` shape
    /// so both destination types feel consistent.
    private func goalProgressRow(for goal: Goal, delta: Decimal) -> some View {
        let after = goal.currentAmount + delta
        let cappedAfter = min(after, goal.targetAmount)
        let amountIsSet = (decimalAmount != nil) && decimalAmount! > 0
        let remaining = max(goal.targetAmount - after, 0)
        let completes = after >= goal.targetAmount

        return HStack(spacing: 6) {
            Image(systemName: "target")
                .font(.system(size: 10))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .frame(width: 16)
            Text(CurrencyFormat.compact(goal.currentAmount))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .monospacedDigit()
            if amountIsSet {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                Text(CurrencyFormat.compact(cappedAfter))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CentmondTheme.Colors.positive)
                    .monospacedDigit()
                Text(completes
                     ? "— completes goal"
                     : "— \(CurrencyFormat.compact(remaining)) left")
                    .font(.system(size: 10))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, 4)
        .transition(.opacity)
    }

    // MARK: - Status toggle pill (parallel to NewTransactionSheet)

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

    private func saveTransfer() {
        guard let amount = decimalAmount, amount > 0 else {
            saveError = "Enter a valid amount"
            return
        }
        guard let from = fromAccount else {
            saveError = "Pick a source account"
            return
        }

        if let goal = toGoal {
            guard TransferService.createTransferToGoal(
                amount: amount,
                date: date,
                from: from,
                to: goal,
                notes: notes,
                status: status,
                in: modelContext
            ) != nil else {
                saveError = "Could not create transfer"
                return
            }
            Haptics.impact()
            dismiss()
            return
        }

        guard let to = toAccount else {
            saveError = "Pick a destination"
            return
        }
        guard from.id != to.id else {
            saveError = "From and To must differ"
            return
        }
        guard TransferService.createTransfer(
            amount: amount,
            date: date,
            from: from,
            to: to,
            notes: notes,
            status: status,
            in: modelContext
        ) != nil else {
            saveError = "Could not create transfer"
            return
        }
        Haptics.impact()
        dismiss()
    }
}

// Duplicate of NewTransactionSheet.BlinkingCursor (private there). Kept
// as a fileprivate mirror here to avoid cross-file visibility changes.
private struct BlinkingCursorTransfer: View {
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
