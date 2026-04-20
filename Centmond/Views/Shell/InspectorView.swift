import SwiftUI
import SwiftData
import Flow

struct InspectorView: View {
    let context: InspectorContext

    var body: some View {
        Group {
            switch context {
            case .none:
                emptyInspector
            case .transaction(let id):
                TransactionInspectorView(transactionID: id)
            case .account(let id):
                AccountInspectorView(accountID: id)
            case .budgetCategory(let id):
                BudgetCategoryInspectorView(categoryID: id)
            case .goal(let id):
                GoalInspectorView(goalID: id)
            case .subscription(let id):
                SubscriptionInspectorView(subscriptionID: id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CentmondTheme.Colors.bgSecondary)
    }

    private var emptyInspector: some View {
        VStack(spacing: CentmondTheme.Spacing.md) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 32))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)

            Text("Select an item to inspect")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)

            Text("\u{2318}I to toggle inspector")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Transaction Inspector

struct TransactionInspectorView: View {
    let transactionID: UUID
    @Query private var transactions: [Transaction]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @Query(sort: \HouseholdMember.joinedAt) private var members: [HouseholdMember]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    @State private var isEditing = false
    @State private var editPayee = ""
    @State private var editAmount = ""
    @State private var editDate = Date.now
    @State private var editNotes = ""
    @State private var editIsIncome = false
    @State private var editCategory: BudgetCategory?
    @State private var editAccount: Account?
    @State private var editMember: HouseholdMember?
    @State private var editStatus: TransactionStatus = .cleared
    @State private var editTagsInput: String = ""
    @State private var editError: String?
    @State private var showDeleteConfirmation = false

    init(transactionID: UUID) {
        self.transactionID = transactionID
        let id = transactionID
        _transactions = Query(filter: #Predicate<Transaction> { $0.id == id })
    }

    private var transaction: Transaction? { transactions.first }

    var body: some View {
        if let transaction = transaction {
            VStack(spacing: 0) {
                // Header
                inspectorHeader(transaction)

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Amount section
                        amountSection(transaction)

                        sectionDivider

                        // Details section
                        if isEditing {
                            editFormSection(transaction)
                        } else {
                            detailsSection(transaction)
                        }

                        if transaction.isTransfer {
                            sectionDivider
                            transferSection(transaction)
                        }

                        sectionDivider

                        // Splits section
                        splitsSection(transaction)

                        sectionDivider

                        // Goal allocations — only renders if this tx funded any goals.
                        TransactionGoalAllocationsView(transactionID: transaction.id)
                            .padding(.horizontal, CentmondTheme.Spacing.md)
                            .padding(.vertical, CentmondTheme.Spacing.sm)

                        // Tags section
                        tagsSection(transaction)

                        sectionDivider

                        // Metadata section
                        metadataSection(transaction)
                    }
                }

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                // Footer actions
                inspectorFooter(transaction)
            }
        } else {
            VStack(spacing: CentmondTheme.Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                Text("Transaction not found")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header

    private func inspectorHeader(_ tx: Transaction) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            // Category icon
            if let category = tx.category {
                Image(systemName: category.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: category.colorHex))
                    .frame(width: 36, height: 36)
                    .background(Color(hex: category.colorHex).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("TXN")
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .tracking(0.5)

                Text(tx.payee)
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Edit toggle
            Button {
                if isEditing {
                    saveEdits(tx)
                } else {
                    startEditing(tx)
                }
            } label: {
                Image(systemName: isEditing ? "checkmark" : "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isEditing ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(isEditing ? CentmondTheme.Colors.positive.opacity(0.12) : CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plainHover)
            .help(isEditing ? "Save changes" : "Edit transaction")

            if isEditing {
                Button {
                    isEditing = false
                    editError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(width: 26, height: 26)
                        .background(CentmondTheme.Colors.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plainHover)
                .help("Cancel editing")
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    // MARK: - Amount Section

    private func amountSection(_ tx: Transaction) -> some View {
        VStack(spacing: CentmondTheme.Spacing.sm) {
            if isEditing {
                HStack {
                    Picker("", selection: $editIsIncome) {
                        Text("Expense").tag(false)
                        Text("Income").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)

                    Spacer()
                }

                HStack {
                    Text("$")
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)

                    TextField("0.00", text: $editAmount)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(editIsIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }
            } else {
                HStack(alignment: .top) {
                    // Type badge
                    HStack(spacing: 4) {
                        Image(systemName: tx.isIncome ? "arrow.down" : "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                        Text(tx.isIncome ? "income" : "expense")
                    }
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))

                    Spacer()

                    // Amount — sign + number only, no currency symbol
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatAmountShort(tx.amount, isIncome: tx.isIncome))
                            .font(CentmondTheme.Typography.heading2)
                            .foregroundStyle(tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)

                        if let account = tx.account {
                            Text(account.currency)
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.lg)
    }

    // MARK: - Details Section (View Mode)

    private func detailsSection(_ tx: Transaction) -> some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            // Date — include hour/minute so the user can see the time
            // they entered (or that was imported from the CSV Time column).
            // Without `.hour().minute()` the formatter silently dropped
            // the time component, which made imports look like every
            // transaction was midnight-dated even when it wasn't.
            inspectorField(
                icon: "calendar",
                label: "Date",
                value: tx.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
            )

            // Category
            inspectorField(
                icon: "tag",
                label: "Category",
                valueView: AnyView(
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        if let cat = tx.category {
                            Circle().fill(Color(hex: cat.colorHex)).frame(width: 8, height: 8)
                            Text(cat.name)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        } else {
                            Text("Uncategorized")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.warning)
                        }
                    }
                )
            )

            // Account
            inspectorField(
                icon: "building.columns",
                label: "Account",
                valueView: AnyView(
                    Group {
                        if let account = tx.account {
                            HStack(spacing: CentmondTheme.Spacing.xs) {
                                Image(systemName: account.type.iconName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                Text(account.name)
                                    .font(CentmondTheme.Typography.body)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                if let digits = account.lastFourDigits {
                                    Text("···· \(digits)")
                                        .font(CentmondTheme.Typography.mono)
                                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                }
                            }
                        } else {
                            Text("No account")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }
                )
            )

            // Member (only when household exists)
            if !members.isEmpty {
                inspectorField(
                    icon: "person.fill",
                    label: "Member",
                    valueView: AnyView(
                        Group {
                            if let member = tx.householdMember {
                                HStack(spacing: CentmondTheme.Spacing.xs) {
                                    Circle()
                                        .fill(Color(hex: member.avatarColor))
                                        .frame(width: 10, height: 10)
                                    Text(member.name)
                                        .font(CentmondTheme.Typography.body)
                                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                }
                            } else {
                                Text("Unassigned")
                                    .font(CentmondTheme.Typography.body)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            }
                        }
                    )
                )
            }

            // Status
            inspectorField(
                icon: "circle.inset.filled",
                label: "Status",
                valueView: AnyView(statusView(tx.status))
            )

            // Review status
            inspectorField(
                icon: "checkmark.seal",
                label: "Reviewed",
                valueView: AnyView(
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        Image(systemName: tx.isReviewed ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(tx.isReviewed ? CentmondTheme.Colors.positive : CentmondTheme.Colors.warning)
                        Text(tx.isReviewed ? "Reviewed" : "Needs Review")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }
                )
            )

            // Notes
            if let notes = tx.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: "note.text")
                            .font(.system(size: 12))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .frame(width: 20)
                        Text("Notes")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }

                    Text(notes)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .padding(CentmondTheme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CentmondTheme.Colors.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                }
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.lg)
    }

    // MARK: - Edit Form Section

    private func editFormSection(_ tx: Transaction) -> some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            // Payee
            editField("Payee") {
                TextField("Payee name", text: $editPayee)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }

            // Date + time — `.hourAndMinute` so edits preserve (and can
            // set) the hour-of-day. Needed so behavioural signals like
            // "late-night spending" work on both manually-created and
            // manually-edited transactions, matching the CSV import path.
            editField("Date") {
                DatePicker("", selection: $editDate, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .labelsHidden()
            }

            // Category
            editField("Category") {
                Picker("", selection: $editCategory) {
                    Text("Uncategorized").tag(nil as BudgetCategory?)
                    ForEach(categories) { category in
                        Label(category.name, systemImage: category.icon).tag(category as BudgetCategory?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Account
            editField("Account") {
                Picker("", selection: $editAccount) {
                    Text("No account").tag(nil as Account?)
                    ForEach(accounts) { account in
                        Text(account.name).tag(account as Account?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Member (only when household exists)
            if !members.isEmpty {
                editField("Member") {
                    Picker("", selection: $editMember) {
                        Text("Unassigned").tag(nil as HouseholdMember?)
                        ForEach(members) { member in
                            Text(member.name).tag(member as HouseholdMember?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            // Status
            editField("Status") {
                Picker("", selection: $editStatus) {
                    ForEach(TransactionStatus.allCases) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Notes
            editField("Notes") {
                TextField("Add notes...", text: $editNotes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(3...6)
            }

            // Tags
            editField("Tags") {
                TextField("Comma-separated", text: $editTagsInput)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }

            if let error = editError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text(error)
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.negative)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.lg)
    }

    // MARK: - Tags Section

    private func tagsSection(_ tx: Transaction) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            HStack {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "number")
                        .font(.system(size: 12))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(width: 20)
                    Text("Tags")
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
                Spacer()
            }

            if tx.tags.isEmpty {
                Text("No tags")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .padding(.leading, 32)
            } else {
                HFlow(spacing: CentmondTheme.Spacing.xs) {
                    ForEach(tx.tags) { tag in
                        Text("#\(tag.name)")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(CentmondTheme.Colors.accentMuted)
                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    // MARK: - Transfer Section

    private func transferSection(_ tx: Transaction) -> some View {
        let other = TransferService.pairedLeg(of: tx, in: modelContext)
        return VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 20)
                Text("Transfer")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Spacer()
                Text(tx.isIncome ? "Incoming" : "Outgoing")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(Capsule())
            }

            if let other = other {
                Button {
                    router.inspectorContext = .transaction(other.id)
                } label: {
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        Image(systemName: tx.isIncome ? "arrow.up.right" : "arrow.down.left")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        Text(tx.isIncome ? "From" : "To")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        Text(other.account?.name ?? "—")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    }
                    .padding(.horizontal, CentmondTheme.Spacing.sm)
                    .padding(.vertical, 6)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plainHover)
                .padding(.leading, 32)
            } else if tx.transferGroupID == nil {
                // Goal transfer — no paired account leg; destination is a
                // goal recorded as a .fromTransfer GoalContribution.
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "target")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Text("To")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Text("Goal (see below)")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, CentmondTheme.Spacing.sm)
                .padding(.vertical, 6)
                .background(CentmondTheme.Colors.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                .padding(.leading, 32)
            } else {
                Text("Paired leg missing")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.warning)
                    .padding(.leading, 32)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    // MARK: - Splits Section

    private func splitsSection(_ tx: Transaction) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            HStack {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 12))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(width: 20)
                    Text("Splits")
                        .font(CentmondTheme.Typography.captionMedium)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    if !tx.splits.isEmpty {
                        Text("\(tx.splits.count)")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(CentmondTheme.Colors.bgTertiary)
                            .clipShape(Capsule())
                    }
                }
                Spacer()
                Button {
                    router.showSheet(.splitTransaction(tx))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tx.splits.isEmpty ? "plus" : "pencil")
                            .font(.system(size: 10, weight: .medium))
                        Text(tx.splits.isEmpty ? "Split" : "Edit")
                    }
                    .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(isEditing || tx.isTransfer)
                .help(tx.isTransfer
                      ? "Transfers cannot be split"
                      : (isEditing ? "Finish editing first" : (tx.splits.isEmpty ? "Split this transaction" : "Edit splits")))
            }

            if tx.splits.isEmpty {
                Text("Not split")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .padding(.leading, 32)
            } else {
                VStack(spacing: CentmondTheme.Spacing.xs) {
                    ForEach(tx.splits.sorted(by: { $0.sortOrder < $1.sortOrder })) { split in
                        HStack(spacing: CentmondTheme.Spacing.sm) {
                            if let cat = split.category {
                                Circle().fill(Color(hex: cat.colorHex)).frame(width: 8, height: 8)
                                Text(cat.name)
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            } else {
                                Circle().fill(CentmondTheme.Colors.textQuaternary).frame(width: 8, height: 8)
                                Text("Uncategorized")
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            }
                            if let memo = split.memo, !memo.isEmpty {
                                Text("· \(memo)")
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(CurrencyFormat.standard(split.amount))
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        }
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    // MARK: - Metadata Section

    private func metadataSection(_ tx: Transaction) -> some View {
        VStack(spacing: CentmondTheme.Spacing.sm) {
            // Section header — short title only. Earlier iteration tried
            // to stuff a clarifying sub-caption ("when this entry was
            // saved in the app") inline next to "Record info", but the
            // inspector column is too narrow and the caption wrapped to
            // two lines, pushing the whole section out of alignment. The
            // short row labels ("Added" / "Edited") plus a `.help(...)`
            // tooltip on the icon carry the disambiguation now.
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 20)
                    .help("When this entry was added to or edited in the app. Not the transaction date.")
                Text("Record info")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Spacer()
            }

            VStack(spacing: CentmondTheme.Spacing.xs) {
                // Short single-word labels so they fit cleanly in the
                // 56pt label column without wrapping. The sub-caption in
                // the section header ("when this entry was saved in the
                // app") carries the disambiguating context — no need to
                // restate it in every row label.
                metaRow("Added", value: tx.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                metaRow("Edited", value: tx.updatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                metaRow("ID", value: String(tx.id.uuidString.prefix(8)))
            }
            .padding(.leading, 32)
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    // MARK: - Footer

    private func inspectorFooter(_ tx: Transaction) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            // Quick actions
            Button {
                tx.isReviewed.toggle()
                tx.updatedAt = .now
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tx.isReviewed ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 12))
                    Text(tx.isReviewed ? "Reviewed" : "Mark Reviewed")
                }
                .font(CentmondTheme.Typography.caption)
            }
            .buttonStyle(GhostButtonStyle())

            Spacer()

            Button {
                duplicateTransaction(tx)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(tx.isTransfer)
            .help(tx.isTransfer ? "Transfers cannot be duplicated" : "Duplicate")

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Delete")
            .alert(tx.isTransfer ? "Delete Transfer" : "Delete Transaction", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if tx.isTransfer {
                        TransferService.deletePair(tx, in: modelContext)
                    } else {
                        let account = tx.account
                        TransactionDeletionService.delete(tx, context: modelContext)
                        if let account { BalanceService.recalculate(account: account) }
                    }
                    router.inspectorContext = .none
                }
            } message: {
                Text(tx.isTransfer
                     ? "Both legs of this transfer will be removed. This cannot be undone."
                     : "Are you sure you want to delete this transaction? This cannot be undone.")
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.sm)
    }

    // MARK: - Helpers

    private var sectionDivider: some View {
        Rectangle()
            .fill(CentmondTheme.Colors.strokeSubtle)
            .frame(height: 1)
            .padding(.horizontal, CentmondTheme.Spacing.lg)
    }

    private func inspectorField(icon: String, label: String, value: String) -> some View {
        inspectorField(icon: icon, label: label, valueView: AnyView(
            Text(value)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
        ))
    }

    private func inspectorField(icon: String, label: String, valueView: AnyView) -> some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)

                valueView
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func editField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text(label.uppercased())
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.3)

            content()
                .padding(.horizontal, CentmondTheme.Spacing.sm)
                .frame(minHeight: CentmondTheme.Sizing.inputHeight)
                .background(CentmondTheme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                        .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func statusView(_ status: TransactionStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: status.dotColor))
                .frame(width: 8, height: 8)
            Text(status.displayName)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
        }
    }

    private func metaRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .frame(width: 56, alignment: .leading)

            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }

    private func startEditing(_ tx: Transaction) {
        editPayee = tx.payee
        editAmount = DecimalInput.editableString(tx.amount)
        editDate = tx.date
        editNotes = tx.notes ?? ""
        editIsIncome = tx.isIncome
        editCategory = tx.category
        editAccount = tx.account
        editMember = tx.householdMember
        editStatus = tx.status
        editTagsInput = tx.tags.map(\.name).joined(separator: ", ")
        editError = nil
        isEditing = true
    }

    private func saveEdits(_ tx: Transaction) {
        // Validation: refuse to save invalid edits. The pencil button stays
        // in edit mode so the user can correct the input.
        let trimmedPayee = TextNormalization.trimmed(editPayee)
        if trimmedPayee.isEmpty {
            editError = "Payee is required"
            Haptics.tap()
            return
        }
        guard let amount = DecimalInput.parsePositive(editAmount) else {
            editError = "Enter a valid amount"
            Haptics.tap()
            return
        }
        // When splits exist, the parent amount is reconciled against them.
        // Refuse changes here so reconciliation invariants stay intact —
        // the user must edit splits via the Split sheet (or clear them).
        if !tx.splits.isEmpty && amount != tx.amount {
            editError = "Clear splits before changing the amount"
            Haptics.tap()
            return
        }
        // Transfers are paired — amount, account, and direction must
        // match the other leg, so the inspector refuses changes that
        // would desync them. Edit the pair via Delete + recreate.
        if tx.isTransfer {
            if amount != tx.amount {
                editError = "Cannot edit transfer amount — delete and recreate"
                Haptics.tap()
                return
            }
            if editAccount?.id != tx.account?.id {
                editError = "Cannot move a transfer leg between accounts"
                Haptics.tap()
                return
            }
            if editIsIncome != tx.isIncome {
                editError = "Cannot flip transfer direction"
                Haptics.tap()
                return
            }
        }
        let previousAccount = tx.account
        tx.payee = trimmedPayee
        tx.amount = amount
        tx.date = editDate
        tx.notes = TextNormalization.trimmedOrNil(editNotes)
        tx.isIncome = editIsIncome
        tx.category = editCategory
        tx.account = editAccount
        tx.householdMember = editMember
        tx.status = editStatus
        tx.tags = TagService.resolve(input: editTagsInput, in: modelContext, existing: allTags)
        tx.updatedAt = .now
        // Recalculate both old and new accounts so an account swap or
        // amount/direction change is reflected immediately.
        BalanceService.recalculate(previousAccount, editAccount)
        editError = nil
        isEditing = false
    }

    private func formatAmount(_ amount: Decimal, isIncome: Bool) -> String {
        CurrencyFormat.signed(amount, isIncome: isIncome)
    }

    /// Compact amount for inspector: "+2,500.00" without currency symbol
    private func formatAmountShort(_ amount: Decimal, isIncome: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let num = formatter.string(from: abs(amount) as NSDecimalNumber) ?? "0.00"
        return isIncome ? "+\(num)" : "-\(num)"
    }

    private func duplicateTransaction(_ tx: Transaction) {
        let dupe = Transaction(
            date: .now,
            payee: tx.payee,
            amount: tx.amount,
            notes: tx.notes,
            isIncome: tx.isIncome,
            account: tx.account,
            category: tx.category
        )
        modelContext.insert(dupe)
        dupe.tags = tx.tags
        if let account = tx.account {
            BalanceService.recalculate(account: account)
        }
    }
}

// MARK: - Account Inspector

struct AccountInspectorView: View {
    let accountID: UUID
    @Query private var accounts: [Account]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    @State private var showDeleteConfirmation = false
    @State private var showCloseConfirmation = false

    init(accountID: UUID) {
        self.accountID = accountID
        let id = accountID
        _accounts = Query(filter: #Predicate<Account> { $0.id == id })
    }

    private var account: Account? { accounts.first }

    private var recentTransactions: [Transaction] {
        guard let account else { return [] }
        return account.transactions
            .sorted { $0.date > $1.date }
            .prefix(8)
            .map { $0 }
    }

    private var balanceColor: Color {
        guard let account else { return CentmondTheme.Colors.textPrimary }
        if account.type == .creditCard {
            return account.currentBalance > 0 ? CentmondTheme.Colors.negative : CentmondTheme.Colors.positive
        }
        return account.currentBalance >= 0 ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.negative
    }

    private var accountColor: Color {
        guard let account else { return CentmondTheme.Colors.accent }
        return Color(hex: account.effectiveColor)
    }

    // Quick stats
    private var totalIncome: Decimal {
        guard let account else { return 0 }
        return account.transactions.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
    }

    private var totalExpenses: Decimal {
        guard let account else { return 0 }
        return account.transactions.filter { !$0.isIncome }.reduce(0) { $0 + abs($1.amount) }
    }

    var body: some View {
        if let account {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: CentmondTheme.Spacing.md) {
                    // Color indicator + icon
                    Image(systemName: account.type.iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accountColor)
                        .frame(width: 36, height: 36)
                        .background(accountColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ACCT")
                            .font(CentmondTheme.Typography.overline)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            .tracking(0.3)

                        Text(account.name)
                            .font(CentmondTheme.Typography.heading3)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        router.showSheet(.editAccount(account))
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(CentmondTheme.Colors.bgTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.plainHover)
                    .help("Edit account")
                }
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.vertical, CentmondTheme.Spacing.md)

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                ScrollView {
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                        // Status badges
                        if account.statusLabel != nil || !account.includeInNetWorth || !account.includeInBudgeting {
                            HStack(spacing: CentmondTheme.Spacing.sm) {
                                if account.isClosed {
                                    acctStatusBadge("Closed", icon: "xmark.circle.fill", color: CentmondTheme.Colors.textQuaternary)
                                }
                                if account.isArchived {
                                    acctStatusBadge("Archived", icon: "archivebox.fill", color: CentmondTheme.Colors.warning)
                                }
                                if !account.includeInNetWorth {
                                    acctStatusBadge("Excluded from Net Worth", icon: "eye.slash", color: CentmondTheme.Colors.textQuaternary)
                                }
                                if !account.includeInBudgeting {
                                    acctStatusBadge("Excluded from Budget", icon: "eye.slash", color: CentmondTheme.Colors.textQuaternary)
                                }
                            }
                        }

                        // Balance
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current Balance")
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)

                            Text(CurrencyFormat.standard(account.currentBalance, currencyCode: account.currency))
                                .font(CentmondTheme.Typography.heading1)
                                .monospacedDigit()
                                .foregroundStyle(balanceColor)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(.vertical, CentmondTheme.Spacing.xs)

                        // Credit card utilization
                        if account.type == .creditCard, let limit = account.creditLimit, limit > 0 {
                            acctCreditCardSection(account, limit: limit)
                        }

                        acctDivider

                        // Quick stats
                        if !account.transactions.isEmpty {
                            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                                Text("QUICK STATS")
                                    .font(CentmondTheme.Typography.overline)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .tracking(0.5)

                                HStack(spacing: 0) {
                                    acctStatItem("Income", value: CurrencyFormat.compact(totalIncome), color: CentmondTheme.Colors.positive)
                                    acctStatItem("Expenses", value: CurrencyFormat.compact(totalExpenses), color: CentmondTheme.Colors.negative)
                                    let net = totalIncome - totalExpenses
                                    acctStatItem("Net", value: CurrencyFormat.compact(net), color: net >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                                }
                            }

                            acctDivider
                        }

                        // Details
                        VStack(spacing: CentmondTheme.Spacing.md) {
                            acctDetailRow("Type", value: account.type.displayName)
                            if let institution = account.institutionName, !institution.isEmpty {
                                acctDetailRow("Institution", value: institution)
                            }
                            if let digits = account.lastFourDigits, !digits.isEmpty {
                                acctDetailRow("Last 4", value: "···· \(digits)")
                            }
                            acctDetailRow("Currency", value: account.currency)
                            if account.openingBalance != 0 {
                                acctDetailRow("Opening", value: CurrencyFormat.standard(account.openingBalance, currencyCode: account.currency))
                            }
                            acctDetailRow("Txns", value: "\(account.transactions.count)")
                            acctDetailRow("Created", value: account.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))

                            if account.isClosed, let closedAt = account.closedAt {
                                acctDetailRow("Closed", value: closedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                            }
                        }

                        // Notes
                        if let notes = account.notes, !notes.isEmpty {
                            acctDivider

                            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                                Text("NOTES")
                                    .font(CentmondTheme.Typography.overline)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .tracking(0.5)

                                Text(notes)
                                    .font(CentmondTheme.Typography.body)
                                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            }
                        }

                        acctDivider

                        // Recent transactions
                        recentTransactionsSection
                    }
                    .padding(CentmondTheme.Spacing.lg)
                }

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                // Footer actions
                acctFooterActions(account)
            }
            .alert("Delete Account", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    for tx in account.transactions {
                        tx.account = nil
                    }
                    modelContext.delete(account)
                    router.inspectorContext = .none
                }
            } message: {
                let txCount = account.transactions.count
                if txCount > 0 {
                    Text("This will permanently delete \"\(account.name)\" and unlink \(txCount) transaction\(txCount == 1 ? "" : "s"). Consider archiving instead. This cannot be undone.")
                } else {
                    Text("This will permanently delete \"\(account.name)\". This cannot be undone.")
                }
            }
            .alert("Close Account", isPresented: $showCloseConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Close Account", role: .destructive) {
                    account.isClosed = true
                    account.closedAt = .now
                    account.includeInNetWorth = false
                    account.includeInBudgeting = false
                }
            } message: {
                Text("Closing \"\(account.name)\" will mark it as inactive. It won't count toward budgets or net worth. You can reopen it later.")
            }
        } else {
            VStack(spacing: CentmondTheme.Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                Text("Account not found")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Credit Card Section

    private func acctCreditCardSection(_ account: Account, limit: Decimal) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            let utilization = account.creditUtilization ?? 0
            let available = account.availableCredit ?? limit

            // Utilization bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Credit Utilization")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Spacer()
                    Text("\(Int(utilization * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(acctUtilizationColor(utilization))
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(CentmondTheme.Colors.bgQuaternary)
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(acctUtilizationColor(utilization))
                            .frame(width: max(0, geo.size.width * min(utilization, 1.0)))
                    }
                }
                .frame(height: 5)
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Available")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    Text(CurrencyFormat.compact(available))
                        .font(CentmondTheme.Typography.mono)
                        .foregroundStyle(CentmondTheme.Colors.positive)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Limit")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    Text(CurrencyFormat.compact(limit))
                        .font(CentmondTheme.Typography.mono)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }
            }
        }
        .padding(CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
    }

    // MARK: - Recent Transactions

    private var recentTransactionsSection: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            Text("RECENT TRANSACTIONS")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)

            if recentTransactions.isEmpty {
                Text("No transactions yet")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .padding(.vertical, CentmondTheme.Spacing.md)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentTransactions) { tx in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tx.payee)
                                    .font(CentmondTheme.Typography.body)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                Text(tx.date.formatted(.dateTime.month(.abbreviated).day()))
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            }

                            Spacer()

                            Text(CurrencyFormat.standard(tx.amount))
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, CentmondTheme.Spacing.xs)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            router.inspectTransaction(tx.id)
                        }

                        if tx.id != recentTransactions.last?.id {
                            Divider().background(CentmondTheme.Colors.strokeSubtle)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private func acctFooterActions(_ account: Account) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            if account.isClosed {
                Button {
                    account.isClosed = false
                    account.closedAt = nil
                    account.includeInNetWorth = true
                    account.includeInBudgeting = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11))
                        Text("Reopen")
                    }
                    .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .help("Reopen this account")
            } else if account.isArchived {
                Button {
                    account.isArchived = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.up")
                            .font(.system(size: 11))
                        Text("Unarchive")
                    }
                    .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .help("Unarchive this account")
            } else {
                Menu {
                    Button {
                        showCloseConfirmation = true
                    } label: {
                        Label("Close Account", systemImage: "xmark.circle")
                    }

                    Button {
                        account.isArchived = true
                        router.inspectorContext = .none
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }

                    Button {
                        duplicateAccount(account)
                    } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                        Text("More")
                    }
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .padding(.horizontal, CentmondTheme.Spacing.sm)
                    .padding(.vertical, CentmondTheme.Spacing.xs)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(Capsule())
                }
                .help("More actions")
            }

            Spacer()

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Delete account permanently")
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.sm)
    }

    // MARK: - Helpers

    private var acctDivider: some View {
        Rectangle()
            .fill(CentmondTheme.Colors.strokeSubtle)
            .frame(height: 1)
    }

    private func acctDetailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .lineLimit(1)
            Spacer()
        }
    }

    private func acctStatusBadge(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
    }

    private func acctStatItem(_ label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            Text(value)
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func acctUtilizationColor(_ utilization: Double) -> Color {
        if utilization > 0.9 { return CentmondTheme.Colors.negative }
        if utilization > 0.7 { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.positive
    }

    private func duplicateAccount(_ account: Account) {
        let copy = Account(
            name: "\(account.name) (Copy)",
            type: account.type,
            institutionName: account.institutionName,
            lastFourDigits: nil,
            currentBalance: 0,
            currency: account.currency,
            colorHex: account.colorHex,
            sortOrder: account.sortOrder + 1,
            openingBalance: 0,
            openingBalanceDate: .now,
            notes: account.notes,
            includeInNetWorth: account.includeInNetWorth,
            includeInBudgeting: account.includeInBudgeting,
            creditLimit: account.creditLimit
        )
        modelContext.insert(copy)
    }
}

// MARK: - Budget Category Inspector

struct BudgetCategoryInspectorView: View {
    let categoryID: UUID
    @Query private var categories: [BudgetCategory]
    @Query private var transactions: [Transaction]
    @Query private var monthlyBudgets: [MonthlyBudget]
    @Query private var totalBudgets: [MonthlyTotalBudget]
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext

    @State private var isEditingBudget = false
    @State private var editBudgetAmount = ""
    @State private var editName = ""
    @State private var showDeleteConfirmation = false

    init(categoryID: UUID) {
        self.categoryID = categoryID
        let id = categoryID
        _categories = Query(filter: #Predicate<BudgetCategory> { $0.id == id })
    }

    private var category: BudgetCategory? { categories.first }

    private var selectedYear: Int  { Calendar.current.component(.year,  from: router.selectedMonth) }
    private var selectedMonthNum: Int { Calendar.current.component(.month, from: router.selectedMonth) }

    private var effectiveBudget: Decimal {
        guard let cat = category else { return 0 }
        return monthlyBudgets.first(where: {
            $0.categoryID == cat.id && $0.year == selectedYear && $0.month == selectedMonthNum
        })?.amount ?? cat.budgetAmount
    }

    private var monthlyTotalBudgetAmount: Decimal {
        totalBudgets.first(where: { $0.year == selectedYear && $0.month == selectedMonthNum })?.amount ?? 0
    }

    private var shareOfTotal: Double {
        guard monthlyTotalBudgetAmount > 0 else { return 0 }
        return Double(truncating: (effectiveBudget / monthlyTotalBudgetAmount) as NSDecimalNumber)
    }

    private var monthlyTransactions: [Transaction] {
        guard let cat = category else { return [] }
        return transactions
            .filter { !$0.isIncome && $0.category?.id == cat.id && $0.date >= router.selectedMonthStart && $0.date < router.selectedMonthEnd }
            .sorted { $0.date > $1.date }
    }

    private var spent: Decimal {
        monthlyTransactions.reduce(0) { $0 + $1.amount }
    }

    private var isOverBudget: Bool {
        effectiveBudget > 0 && spent > effectiveBudget
    }

    var body: some View {
        if let category = category {
            let accentColor = isOverBudget ? CentmondTheme.Colors.negative : Color(hex: category.colorHex)

            VStack(spacing: 0) {
                // Header
                HStack(spacing: CentmondTheme.Spacing.md) {
                    Image(systemName: category.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(accentColor)
                        .frame(width: 40, height: 40)
                        .background(accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Budget Category")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .textCase(.uppercase)
                            .tracking(0.3)

                        if isEditingBudget {
                            TextField("Category name", text: $editName)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.heading3)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        } else {
                            Text(category.name)
                                .font(CentmondTheme.Typography.heading3)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        }
                    }

                    Spacer()

                    Button {
                        if isEditingBudget {
                            saveBudgetEdit(category)
                        } else {
                            startBudgetEdit(category)
                        }
                    } label: {
                        Image(systemName: isEditingBudget ? "checkmark" : "pencil")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isEditingBudget ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(isEditingBudget ? CentmondTheme.Colors.positive.opacity(0.12) : CentmondTheme.Colors.bgTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.plainHover)
                    .help(isEditingBudget ? "Save" : "Edit")

                    if isEditingBudget {
                        Button {
                            isEditingBudget = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .frame(width: 28, height: 28)
                                .background(CentmondTheme.Colors.bgTertiary)
                                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                        }
                        .buttonStyle(.plainHover)
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.vertical, CentmondTheme.Spacing.md)
                .background(isOverBudget ? CentmondTheme.Colors.negative.opacity(0.06) : .clear)

                Divider().background(isOverBudget ? CentmondTheme.Colors.negative.opacity(0.3) : CentmondTheme.Colors.strokeSubtle)

                ScrollView {
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                        if isEditingBudget {
                            budgetEditSection(category)
                        } else {
                            budgetProgressSection(category)
                        }

                        catDivider

                        catDetailsSection(category)

                        catDivider

                        catRecentTransactionsSection
                    }
                    .padding(CentmondTheme.Spacing.lg)
                }

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                // Footer
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Spacer()

                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(CentmondTheme.Colors.negative)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Delete category")
                }
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.vertical, CentmondTheme.Spacing.sm)
            }
            .alert("Delete Category", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    for tx in category.transactions {
                        tx.category = nil
                    }
                    modelContext.delete(category)
                    router.inspectorContext = .none
                }
            } message: {
                let txCount = category.transactions.count
                if txCount > 0 {
                    Text("This will delete \"\(category.name)\" and uncategorize \(txCount) transaction\(txCount == 1 ? "" : "s").")
                } else {
                    Text("This will delete \"\(category.name)\".")
                }
            }
        } else {
            catNotFoundView("Category not found")
        }
    }

    // MARK: - Budget Edit

    private func budgetEditSection(_ cat: BudgetCategory) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Text("BUDGET — \(router.selectedMonth.formatted(.dateTime.month(.wide).year()).uppercased())")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.accent)
                .tracking(0.5)

            HStack {
                Text("$")
                    .font(CentmondTheme.Typography.heading1)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                TextField("0.00", text: $editBudgetAmount)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.heading1)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
            }
            .padding(.horizontal, CentmondTheme.Spacing.sm)
            .padding(.vertical, CentmondTheme.Spacing.sm)
            .background(CentmondTheme.Colors.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
            )
        }
    }

    private func budgetProgressSection(_ cat: BudgetCategory) -> some View {
        let budget = effectiveBudget
        let remaining = budget - spent
        let progress = budget > 0 ? Double(truncating: (spent / budget) as NSDecimalNumber) : 0
        let isOver = spent > budget

        return VStack(spacing: CentmondTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(CurrencyFormat.standard(spent))
                    .font(CentmondTheme.Typography.heading1)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()

                Text("of \(CurrencyFormat.standard(budget))")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)

                Spacer()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(CentmondTheme.Colors.strokeSubtle)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOver ? CentmondTheme.Colors.negative : Color(hex: cat.colorHex))
                        .frame(width: geo.size.width * min(CGFloat(progress), 1.0))
                }
            }
            .frame(height: 8)

            HStack {
                Text(isOver ? "\(CurrencyFormat.standard(-remaining)) over budget" : "\(CurrencyFormat.standard(remaining)) remaining")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(isOver ? CentmondTheme.Colors.negative : CentmondTheme.Colors.positive)

                Spacer()

                Text("\(Int(progress * 100))%")
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    private func catDetailsSection(_ cat: BudgetCategory) -> some View {
        VStack(spacing: CentmondTheme.Spacing.md) {
            catDetailRow("Budget", value: CurrencyFormat.standard(effectiveBudget))
            if monthlyTotalBudgetAmount > 0 {
                catDetailRow("Share of Total", value: "\(Int(shareOfTotal * 100))% of \(CurrencyFormat.standard(monthlyTotalBudgetAmount))")
            }
            catDetailRow("Default", value: CurrencyFormat.standard(cat.budgetAmount))
            catDetailRow("Type", value: cat.isExpenseCategory ? "Expense" : "Income")
            catDetailRow("Transactions", value: "\(monthlyTransactions.count) this month")
            catDetailRow("Total (all time)", value: "\(cat.transactions.count)")
        }
    }

    private var catRecentTransactionsSection: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            Text("RECENT TRANSACTIONS")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)

            if monthlyTransactions.isEmpty {
                Text("No transactions this month")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .padding(.vertical, CentmondTheme.Spacing.md)
            } else {
                VStack(spacing: 0) {
                    ForEach(monthlyTransactions.prefix(8)) { tx in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tx.payee)
                                    .font(CentmondTheme.Typography.body)
                                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                Text(tx.date.formatted(.dateTime.month(.abbreviated).day()))
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            }

                            Spacer()

                            Text(CurrencyFormat.standard(tx.amount))
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, CentmondTheme.Spacing.xs)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            router.inspectTransaction(tx.id)
                        }

                        if tx.id != monthlyTransactions.prefix(8).last?.id {
                            Divider().background(CentmondTheme.Colors.strokeSubtle)
                        }
                    }
                }
            }
        }
    }

    private var catDivider: some View {
        Rectangle()
            .fill(CentmondTheme.Colors.strokeSubtle)
            .frame(height: 1)
    }

    private func catDetailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Spacer()
        }
    }

    private func catNotFoundView(_ text: String) -> some View {
        VStack(spacing: CentmondTheme.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            Text(text)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startBudgetEdit(_ cat: BudgetCategory) {
        editBudgetAmount = "\(effectiveBudget)"
        editName = cat.name
        isEditingBudget = true
    }

    private func saveBudgetEdit(_ cat: BudgetCategory) {
        if let amount = Decimal(string: editBudgetAmount), amount >= 0 {
            // Upsert a MonthlyBudget override for the selected month
            if let existing = monthlyBudgets.first(where: {
                $0.categoryID == cat.id && $0.year == selectedYear && $0.month == selectedMonthNum
            }) {
                existing.amount = amount
            } else {
                modelContext.insert(MonthlyBudget(
                    categoryID: cat.id,
                    year: selectedYear,
                    month: selectedMonthNum,
                    amount: amount
                ))
            }
        }
        let trimmed = editName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            cat.name = trimmed
        }
        isEditingBudget = false
    }
}

// MARK: - Goal Inspector

struct GoalInspectorView: View {
    let goalID: UUID
    @Query private var goals: [Goal]
    @Query private var rulesForGoal: [GoalAllocationRule]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    @State private var contributionAmount = ""
    @State private var showDeleteConfirmation = false
    @State private var showRulesSheet = false

    init(goalID: UUID) {
        self.goalID = goalID
        let id = goalID
        _goals = Query(filter: #Predicate<Goal> { $0.id == id })
        _rulesForGoal = Query(filter: #Predicate<GoalAllocationRule> { $0.goal?.id == id })
    }

    private var goal: Goal? { goals.first }

    var body: some View {
        if let goal = goal {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: CentmondTheme.Spacing.md) {
                    Image(systemName: goal.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .frame(width: 40, height: 40)
                        .background(CentmondTheme.Colors.accentMuted)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Goal")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .textCase(.uppercase)
                            .tracking(0.3)

                        Text(goal.name)
                            .font(CentmondTheme.Typography.heading3)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    Spacer()

                    goalStatusBadge(goal.status)
                }
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.vertical, CentmondTheme.Spacing.md)

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                ScrollView {
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                        // Progress section
                        progressSection(goal)

                        divider

                        // Details
                        detailsSection(goal)

                        divider

                        // Auto-allocation rules — summary + open editor
                        rulesSection(goal)

                        divider

                        // Quick contribute
                        if goal.status == .active {
                            contributeSection(goal)
                        }

                        divider

                        // Contribution timeline — shows the last 10 rows of
                        // history with kind-colored chips + source captions.
                        timelineSection(goal)
                    }
                    .padding(CentmondTheme.Spacing.lg)
                }
                .sheet(isPresented: $showRulesSheet) {
                    GoalAllocationRulesSheet(goal: goal)
                }

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                // Footer actions
                footerActions(goal)
            }
        } else {
            VStack(spacing: CentmondTheme.Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                Text("Goal not found")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func progressSection(_ goal: Goal) -> some View {
        let progress = goal.progressPercentage
        let remaining = goal.targetAmount - goal.currentAmount

        return VStack(spacing: CentmondTheme.Spacing.md) {
            // Amount
            HStack(alignment: .firstTextBaseline) {
                Text(CurrencyFormat.standard(goal.currentAmount))
                    .font(CentmondTheme.Typography.heading1)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()

                Text("of \(CurrencyFormat.standard(goal.targetAmount))")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)

                Spacer()
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(CentmondTheme.Colors.strokeSubtle)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [CentmondTheme.Colors.accent, progressColor(progress)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * min(progress, 1.0))
                }
            }
            .frame(height: 10)

            HStack {
                Text("\(Int(progress * 100))% complete")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(progressColor(progress))

                Spacer()

                if remaining > 0 {
                    Text("\(CurrencyFormat.standard(remaining)) to go")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }
        }
    }

    private func detailsSection(_ goal: Goal) -> some View {
        VStack(spacing: CentmondTheme.Spacing.md) {
            detailRow("Status", value: goal.status.displayName)

            if let targetDate = goal.targetDate {
                let daysLeft = Calendar.current.dateComponents([.day], from: .now, to: targetDate).day ?? 0
                detailRow("Target Date", value: targetDate.formatted(date: .abbreviated, time: .omitted))
                if daysLeft > 0 && goal.status == .active {
                    detailRow("Days Left", value: "\(daysLeft)")
                }
            }

            if let monthly = goal.monthlyContribution, monthly > 0 {
                detailRow("Monthly", value: CurrencyFormat.standard(monthly))
            }

            detailRow("Created", value: goal.createdAt.formatted(date: .abbreviated, time: .omitted))
        }
    }

    private func timelineSection(_ goal: Goal) -> some View {
        let sorted = goal.contributions.sorted { $0.date > $1.date }
        let recent = Array(sorted.prefix(10))
        let thisMonth = GoalAnalytics.thisMonthContribution(goal)
        let avgMonthly = GoalAnalytics.averageMonthlyContribution(goal)
        let projected = GoalAnalytics.projectedCompletion(goal)

        return VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            Text("ACTIVITY")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)

            HStack(spacing: CentmondTheme.Spacing.md) {
                timelineStat(
                    label: "This month",
                    value: CurrencyFormat.compact(thisMonth),
                    color: CentmondTheme.Colors.positive
                )
                timelineStat(
                    label: "3-mo avg",
                    value: CurrencyFormat.compact(avgMonthly),
                    color: CentmondTheme.Colors.accent
                )
                if let p = projected {
                    timelineStat(
                        label: "At target",
                        value: p.formatted(.dateTime.month(.abbreviated).year(.twoDigits)),
                        color: CentmondTheme.Colors.warning
                    )
                }
            }

            if recent.isEmpty {
                HStack {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text("No contributions yet")
                        .font(CentmondTheme.Typography.caption)
                    Spacer()
                }
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .padding(.vertical, CentmondTheme.Spacing.sm)
            } else {
                VStack(spacing: 1) {
                    ForEach(recent) { c in
                        timelineRow(c)
                    }
                }
                .background(CentmondTheme.Colors.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                if sorted.count > recent.count {
                    Text("Showing \(recent.count) of \(sorted.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
        }
    }

    private func timelineStat(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timelineRow(_ c: GoalContribution) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            kindGlyph(c.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.note ?? kindTitle(c.kind))
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(c.date.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.system(size: 10))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            Spacer()
            Text(c.amount >= 0 ? CurrencyFormat.standard(c.amount) : "-\(CurrencyFormat.standard(-c.amount))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(c.amount >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .frame(height: 38)
    }

    private func kindGlyph(_ kind: GoalContributionKind) -> some View {
        let (icon, color): (String, Color) = {
            switch kind {
            case .manual: return ("hand.tap.fill", CentmondTheme.Colors.textSecondary)
            case .fromIncome: return ("arrow.down.circle.fill", CentmondTheme.Colors.positive)
            case .fromTransfer: return ("arrow.left.arrow.right", CentmondTheme.Colors.warning)
            case .autoRule: return ("wand.and.rays", CentmondTheme.Colors.accent)
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(color.opacity(0.12))
            .clipShape(Circle())
    }

    private func kindTitle(_ kind: GoalContributionKind) -> String {
        switch kind {
        case .manual: return "Manual contribution"
        case .fromIncome: return "Routed from income"
        case .fromTransfer: return "Transfer from account"
        case .autoRule: return "Auto rule"
        }
    }

    private func rulesSection(_ goal: Goal) -> some View {
        let activeCount = rulesForGoal.filter { $0.isActive }.count
        let total = rulesForGoal.count
        return VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            Text("AUTO-ALLOCATION RULES")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)

            Button {
                showRulesSheet = true
            } label: {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "wand.and.rays")
                        .font(.system(size: 12))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(total == 0 ? "No rules" : "\(activeCount) active · \(total) total")
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Text("Propose contributions from future income")
                            .font(.system(size: 10))
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .frame(height: 44)
                .background(CentmondTheme.Colors.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func contributeSection(_ goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            Text("ADD CONTRIBUTION")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)

            HStack(spacing: CentmondTheme.Spacing.sm) {
                HStack {
                    Text("$")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)

                    TextField("0.00", text: $contributionAmount)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }
                .padding(.horizontal, CentmondTheme.Spacing.sm)
                .frame(height: CentmondTheme.Sizing.inputHeight)
                .background(CentmondTheme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                        .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                )

                Button("Add") {
                    if let amount = Decimal(string: contributionAmount), amount > 0 {
                        GoalContributionService.addContribution(
                            to: goal,
                            amount: amount,
                            kind: .manual,
                            context: modelContext
                        )
                        contributionAmount = ""
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(Decimal(string: contributionAmount) == nil || Decimal(string: contributionAmount)! <= 0)
            }
        }
    }

    private func footerActions(_ goal: Goal) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            if goal.status == .active {
                Button {
                    goal.status = .paused
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 12))
                        Text("Pause")
                    }
                    .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
            } else if goal.status == .paused {
                Button {
                    goal.status = .active
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 12))
                        Text("Resume")
                    }
                    .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
            } else if goal.status == .completed || goal.status == .archived {
                Button {
                    goal.status = .active
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12))
                        Text("Reactivate")
                    }
                    .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
            }

            if goal.status == .active || goal.status == .paused {
                Button {
                    goal.status = .archived
                    router.inspectorContext = .none
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 12))
                        Text("Archive")
                    }
                    .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
            }

            Spacer()

            Button {
                router.showSheet(.editGoal(goal))
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
            }
            .buttonStyle(GhostButtonStyle())
            .help("Edit")

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Delete")
            .alert("Delete Goal", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    modelContext.delete(goal)
                    router.inspectorContext = .none
                }
            } message: {
                Text("Are you sure you want to delete this goal? This cannot be undone.")
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.sm)
    }

    private var divider: some View {
        Rectangle()
            .fill(CentmondTheme.Colors.strokeSubtle)
            .frame(height: 1)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Spacer()
        }
    }

    private func goalStatusBadge(_ status: GoalStatus) -> some View {
        let (text, color): (String, Color) = switch status {
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

    private func progressColor(_ progress: Double) -> Color {
        if progress >= 1.0 { return CentmondTheme.Colors.positive }
        if progress >= 0.7 { return CentmondTheme.Colors.accent }
        if progress >= 0.4 { return CentmondTheme.Colors.warning }
        return CentmondTheme.Colors.negative
    }

}

// MARK: - Subscription Inspector

struct SubscriptionInspectorView: View {
    let subscriptionID: UUID
    @Query private var subscriptions: [Subscription]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    @State private var showDeleteConfirmation = false

    init(subscriptionID: UUID) {
        self.subscriptionID = subscriptionID
        let id = subscriptionID
        _subscriptions = Query(filter: #Predicate<Subscription> { $0.id == id })
    }

    private var subscription: Subscription? { subscriptions.first }

    var body: some View {
        if let sub = subscription {
            VStack(spacing: 0) {
                subscriptionHeader(sub)

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        costSection(sub)
                        sectionDivider
                        detailsSection(sub)
                        sectionDivider
                        paymentSection(sub)
                    }
                }

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                subscriptionFooter(sub)
            }
            .alert("Delete Subscription?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    modelContext.delete(sub)
                    router.inspectorContext = .none
                    router.isInspectorVisible = false
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete \"\(sub.serviceName)\".")
            }
        } else {
            VStack(spacing: CentmondTheme.Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                Text("Subscription not found")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header

    private func subscriptionHeader(_ sub: Subscription) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            // Service icon
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(hex: sub.status.dotColor))
                .frame(width: 36, height: 36)
                .background(Color(hex: sub.status.dotColor).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Subscription")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.3)

                Text(sub.serviceName)
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            // Status badge
            Text(sub.status.displayName)
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(Color(hex: sub.status.dotColor))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(hex: sub.status.dotColor).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    // MARK: - Cost Section

    private func costSection(_ sub: Subscription) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Text("COST")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)

            HStack(alignment: .firstTextBaseline, spacing: CentmondTheme.Spacing.sm) {
                Text(CurrencyFormat.standard(sub.amount))
                    .font(CentmondTheme.Typography.monoDisplay)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()

                Text("/ \(sub.billingCycle.displayName.lowercased())")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            HStack(spacing: CentmondTheme.Spacing.xxl) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MONTHLY")
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .tracking(0.5)
                    Text(CurrencyFormat.standard(sub.monthlyCost))
                        .font(CentmondTheme.Typography.mono)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ANNUAL")
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .tracking(0.5)
                    Text(CurrencyFormat.standard(sub.annualCost))
                        .font(CentmondTheme.Typography.mono)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    // MARK: - Details Section

    private func detailsSection(_ sub: Subscription) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Text("DETAILS")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)

            detailRow(label: "Category", value: sub.categoryName)
            detailRow(label: "Billing Cycle", value: sub.billingCycle.displayName)
            detailRow(label: "Status", value: sub.status.displayName)
            detailRow(label: "Created", value: sub.createdAt.formatted(date: .abbreviated, time: .omitted))

            if let account = sub.account {
                detailRow(label: "Account", value: account.name)
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    // MARK: - Payment Section

    private func paymentSection(_ sub: Subscription) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            Text("NEXT PAYMENT")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)

            if sub.status == .cancelled {
                Text("Cancelled - no upcoming payments")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            } else if sub.status == .paused {
                Text("Paused - payments on hold")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.warning)
            } else {
                let daysUntil = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: sub.nextPaymentDate)).day ?? 0
                let isOverdue = daysUntil < 0

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sub.nextPaymentDate.formatted(date: .abbreviated, time: .omitted))
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(isOverdue ? CentmondTheme.Colors.negative : CentmondTheme.Colors.textPrimary)

                        if isOverdue {
                            Text("Overdue by \(abs(daysUntil)) day\(abs(daysUntil) == 1 ? "" : "s")")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.negative)
                        } else if daysUntil == 0 {
                            Text("Due today")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.warning)
                        } else {
                            Text("In \(daysUntil) day\(daysUntil == 1 ? "" : "s")")
                                .font(CentmondTheme.Typography.caption)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        }
                    }

                    Spacer()

                    Text(CurrencyFormat.standard(sub.amount))
                        .font(CentmondTheme.Typography.monoLarge)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    // MARK: - Footer

    private func subscriptionFooter(_ sub: Subscription) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            if sub.status == .active {
                Button {
                    sub.status = .paused
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                        .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(.plainHover)
                .foregroundStyle(CentmondTheme.Colors.warning)
            } else if sub.status == .paused {
                Button {
                    sub.status = .active
                } label: {
                    Label("Resume", systemImage: "play.circle")
                        .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(.plainHover)
                .foregroundStyle(CentmondTheme.Colors.positive)
            } else {
                Button {
                    sub.status = .active
                } label: {
                    Label("Reactivate", systemImage: "arrow.uturn.backward")
                        .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(.plainHover)
                .foregroundStyle(CentmondTheme.Colors.accent)
            }

            if sub.status != .cancelled {
                Button {
                    sub.status = .cancelled
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(.plainHover)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Spacer()

            Button {
                router.showSheet(.editSubscription(sub))
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plainHover)
            .help("Edit subscription")

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }
            .buttonStyle(.plainHover)
            .help("Delete subscription")
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.sm)
    }

    // MARK: - Helpers

    private var sectionDivider: some View {
        Divider()
            .background(CentmondTheme.Colors.strokeSubtle)
            .padding(.horizontal, CentmondTheme.Spacing.lg)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Spacer()
            Text(value)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
        }
    }

}
