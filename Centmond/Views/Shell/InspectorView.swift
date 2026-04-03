import SwiftUI
import SwiftData

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
    @State private var editStatus: TransactionStatus = .cleared
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

                        sectionDivider

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
                Text("Transaction")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.3)

                Text(tx.payee)
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            // Edit toggle
            Button {
                if isEditing {
                    saveEdits(tx)
                } else {
                    startEditing(tx)
                }
            } label: {
                Image(systemName: isEditing ? "checkmark" : "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isEditing ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(isEditing ? CentmondTheme.Colors.positive.opacity(0.12) : CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(isEditing ? "Save changes" : "Edit transaction")

            if isEditing {
                Button {
                    isEditing = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(CentmondTheme.Colors.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
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
                HStack(alignment: .firstTextBaseline) {
                    Text(formatAmount(tx.amount, isIncome: tx.isIncome))
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()

                    Spacer()

                    // Type badge
                    HStack(spacing: 4) {
                        Image(systemName: tx.isIncome ? "arrow.down" : "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                        Text(tx.isIncome ? "Income" : "Expense")
                    }
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
                }
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.lg)
    }

    // MARK: - Details Section (View Mode)

    private func detailsSection(_ tx: Transaction) -> some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            // Date
            inspectorField(
                icon: "calendar",
                label: "Date",
                value: tx.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
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

            // Date
            editField("Date") {
                DatePicker("", selection: $editDate, displayedComponents: .date)
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
                FlowLayout(spacing: CentmondTheme.Spacing.xs) {
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

    // MARK: - Metadata Section

    private func metadataSection(_ tx: Transaction) -> some View {
        VStack(spacing: CentmondTheme.Spacing.sm) {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 20)
                Text("Metadata")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Spacer()
            }

            VStack(spacing: CentmondTheme.Spacing.xs) {
                metaRow("Created", value: tx.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                metaRow("Updated", value: tx.updatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
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
            .help("Duplicate")

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Delete")
            .alert("Delete Transaction", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    modelContext.delete(tx)
                    router.inspectorContext = .none
                }
            } message: {
                Text("Are you sure you want to delete this transaction? This cannot be undone.")
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
                .frame(width: 60, alignment: .leading)

            Text(value)
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .textSelection(.enabled)

            Spacer()
        }
    }

    private func startEditing(_ tx: Transaction) {
        editPayee = tx.payee
        editAmount = "\(tx.amount)"
        editDate = tx.date
        editNotes = tx.notes ?? ""
        editIsIncome = tx.isIncome
        editCategory = tx.category
        editAccount = tx.account
        editStatus = tx.status
        isEditing = true
    }

    private func saveEdits(_ tx: Transaction) {
        tx.payee = editPayee
        if let amount = Decimal(string: editAmount) {
            tx.amount = amount
        }
        tx.date = editDate
        tx.notes = editNotes.isEmpty ? nil : editNotes
        tx.isIncome = editIsIncome
        tx.category = editCategory
        tx.account = editAccount
        tx.status = editStatus
        tx.updatedAt = .now
        isEditing = false
    }

    private func formatAmount(_ amount: Decimal, isIncome: Bool) -> String {
        CurrencyFormat.signed(amount, isIncome: isIncome)
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
    }
}

// MARK: - Account Inspector

struct AccountInspectorView: View {
    let accountID: UUID
    @Query private var accounts: [Account]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    @State private var isEditing = false
    @State private var editName = ""
    @State private var editType: AccountType = .checking
    @State private var editInstitution = ""
    @State private var editLastFour = ""
    @State private var editBalance = ""
    @State private var editCurrency = "USD"
    @State private var showDeleteConfirmation = false

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

    var body: some View {
        if let account {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: CentmondTheme.Spacing.md) {
                    Image(systemName: account.type.iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .frame(width: 40, height: 40)
                        .background(CentmondTheme.Colors.accentMuted)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Account")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .textCase(.uppercase)
                            .tracking(0.3)

                        Text(account.name)
                            .font(CentmondTheme.Typography.heading3)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    }

                    Spacer()

                    Button {
                        if isEditing {
                            saveEdits(account)
                        } else {
                            startEditing(account)
                        }
                    } label: {
                        Image(systemName: isEditing ? "checkmark" : "pencil")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isEditing ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(isEditing ? CentmondTheme.Colors.positive.opacity(0.12) : CentmondTheme.Colors.bgTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(isEditing ? "Save changes" : "Edit account")

                    if isEditing {
                        Button {
                            isEditing = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .frame(width: 28, height: 28)
                                .background(CentmondTheme.Colors.bgTertiary)
                                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Cancel editing")
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.vertical, CentmondTheme.Spacing.md)

                Divider().background(CentmondTheme.Colors.strokeSubtle)

                ScrollView {
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                        if isEditing {
                            editFormSection
                        } else {
                            // Balance
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Current Balance")
                                    .font(CentmondTheme.Typography.captionMedium)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)

                                Text(CurrencyFormat.standard(account.currentBalance, currencyCode: account.currency))
                                    .font(CentmondTheme.Typography.heading1)
                                    .monospacedDigit()
                                    .foregroundStyle(balanceColor)
                            }
                            .padding(.vertical, CentmondTheme.Spacing.sm)

                            if account.isArchived {
                                HStack(spacing: CentmondTheme.Spacing.sm) {
                                    Image(systemName: "archivebox.fill")
                                        .font(.system(size: 12))
                                    Text("Archived")
                                }
                                .font(CentmondTheme.Typography.captionMedium)
                                .foregroundStyle(CentmondTheme.Colors.warning)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(CentmondTheme.Colors.warning.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
                            }

                            acctDivider

                            // Details
                            VStack(spacing: CentmondTheme.Spacing.md) {
                                acctDetailRow("Type", value: account.type.displayName)
                                if let institution = account.institutionName, !institution.isEmpty {
                                    acctDetailRow("Institution", value: institution)
                                }
                                if let digits = account.lastFourDigits, !digits.isEmpty {
                                    acctDetailRow("Last 4 Digits", value: "···· \(digits)")
                                }
                                acctDetailRow("Currency", value: account.currency)
                                acctDetailRow("Transactions", value: "\(account.transactions.count)")
                                acctDetailRow("Created", value: account.createdAt.formatted(date: .abbreviated, time: .omitted))
                            }

                            acctDivider

                            // Recent transactions
                            recentTransactionsSection
                        }
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
                    Text("This will permanently delete \"\(account.name)\" and unlink \(txCount) transaction\(txCount == 1 ? "" : "s"). This cannot be undone.")
                } else {
                    Text("This will permanently delete \"\(account.name)\". This cannot be undone.")
                }
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

    // MARK: - Edit Form

    private var editFormSection: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            acctEditField("NAME") {
                TextField("Account name", text: $editName)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }

            acctEditField("TYPE") {
                Picker("", selection: $editType) {
                    ForEach(AccountType.allCases) { type in
                        Label(type.displayName, systemImage: type.iconName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            acctEditField("INSTITUTION") {
                TextField("e.g., Chase Bank", text: $editInstitution)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }

            acctEditField("LAST 4 DIGITS") {
                TextField("e.g., 4521", text: $editLastFour)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }

            acctEditField("CURRENT BALANCE") {
                HStack {
                    Text("$")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    TextField("0.00", text: $editBalance)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }
            }
        }
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
                            Text(tx.payee)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .lineLimit(1)

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
            if account.isArchived {
                Button {
                    account.isArchived = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.up")
                            .font(.system(size: 12))
                        Text("Unarchive")
                    }
                    .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                Button {
                    account.isArchived = true
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
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Delete")
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
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Spacer()
        }
    }

    @ViewBuilder
    private func acctEditField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
            Text(label)
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

    private func startEditing(_ account: Account) {
        editName = account.name
        editType = account.type
        editInstitution = account.institutionName ?? ""
        editLastFour = account.lastFourDigits ?? ""
        editBalance = "\(account.currentBalance)"
        editCurrency = account.currency
        isEditing = true
    }

    private func saveEdits(_ account: Account) {
        account.name = editName
        account.type = editType
        account.institutionName = editInstitution.isEmpty ? nil : editInstitution
        account.lastFourDigits = editLastFour.isEmpty ? nil : editLastFour
        if let balance = Decimal(string: editBalance) {
            account.currentBalance = balance
        }
        account.currency = editCurrency
        isEditing = false
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
                    .buttonStyle(.plain)
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
                        .buttonStyle(.plain)
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
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    @State private var contributionAmount = ""
    @State private var showDeleteConfirmation = false

    init(goalID: UUID) {
        self.goalID = goalID
        let id = goalID
        _goals = Query(filter: #Predicate<Goal> { $0.id == id })
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

                        // Quick contribute
                        if goal.status == .active {
                            contributeSection(goal)
                        }
                    }
                    .padding(CentmondTheme.Spacing.lg)
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
                        goal.currentAmount += amount
                        if goal.currentAmount >= goal.targetAmount {
                            goal.status = .completed
                        }
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
                .buttonStyle(.plain)
                .foregroundStyle(CentmondTheme.Colors.warning)
            } else if sub.status == .paused {
                Button {
                    sub.status = .active
                } label: {
                    Label("Resume", systemImage: "play.circle")
                        .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(CentmondTheme.Colors.positive)
            } else {
                Button {
                    sub.status = .active
                } label: {
                    Label("Reactivate", systemImage: "arrow.uturn.backward")
                        .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(CentmondTheme.Colors.accent)
            }

            if sub.status != .cancelled {
                Button {
                    sub.status = .cancelled
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .font(CentmondTheme.Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Spacer()

            Button {
                router.showSheet(.editSubscription(sub))
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Edit subscription")

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }
            .buttonStyle(.plain)
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
