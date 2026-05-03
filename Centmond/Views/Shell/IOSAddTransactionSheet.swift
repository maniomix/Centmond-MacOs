#if os(iOS)
import SwiftUI
import SwiftData

/// iOS Add/Edit Transaction sheet (Track B3). Same form drives both new
/// rows and editing existing ones — pass `editing:` to load an existing
/// Transaction for edit. Saving inserts/mutates and hands the change to
/// CloudSyncCoordinator's willSave hook for the next debounce window.
struct IOSAddTransactionSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BudgetCategory.sortOrder) private var allCategories: [BudgetCategory]
    @Query(sort: \Account.name) private var allAccounts: [Account]
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"

    /// Pass nil to add a new tx; pass an existing model to edit it. Held
    /// as an @Bindable model below so writes go straight back to SwiftData.
    let editing: Transaction?

    init(editing: Transaction? = nil) {
        self.editing = editing
    }

    @State private var isIncome: Bool = false
    @State private var amount: Decimal = 0
    @State private var payee: String = ""
    @State private var date: Date = .now
    @State private var notes: String = ""
    @State private var selectedAccountID: UUID?
    @State private var selectedCategoryID: UUID?
    @State private var didLoadExisting: Bool = false

    /// Snapshot of the editing tx's pre-edit account + amount + isIncome
    /// so we can reverse the running-balance adjustment before re-applying
    /// the new one. Keeps account.currentBalance in sync across edits.
    @State private var originalAccountID: UUID?
    @State private var originalAmount: Decimal = 0
    @State private var originalIsIncome: Bool = false

    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                amountSection
                detailsSection
                notesSection
                if editing != nil { deleteSection }
            }
            .navigationTitle(editing == nil ? "New Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let tx = editing, !didLoadExisting {
                    isIncome = tx.isIncome
                    amount = tx.amount
                    payee = tx.payee
                    date = tx.date
                    notes = tx.notes ?? ""
                    selectedAccountID = tx.account?.id
                    selectedCategoryID = tx.category?.id
                    originalAccountID = tx.account?.id
                    originalAmount = tx.amount
                    originalIsIncome = tx.isIncome
                    didLoadExisting = true
                } else if editing == nil {
                    amountFocused = true
                    if selectedAccountID == nil {
                        selectedAccountID = activeAccounts.first?.id
                    }
                    if selectedCategoryID == nil {
                        selectedCategoryID = relevantCategories.first?.id
                    }
                }
            }
            .onChange(of: isIncome) { _, _ in
                // Categories filter on income/expense — pick a sensible default
                // for the new direction so the row never shows an invalid
                // selection that's been hidden by the picker filter.
                if let id = selectedCategoryID,
                   relevantCategories.contains(where: { $0.id == id }) == false {
                    selectedCategoryID = relevantCategories.first?.id
                }
            }
        }
    }

    // MARK: - Sections

    private var typeSection: some View {
        Section {
            Picker("", selection: $isIncome) {
                Text("Expense").tag(false)
                Text("Income").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var amountSection: some View {
        Section {
            HStack(spacing: 6) {
                Text(currencySymbol)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                TextField("0", value: $amount, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .focused($amountFocused)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 4)
        }
    }

    private var detailsSection: some View {
        Section {
            HStack {
                Image(systemName: "person").frame(width: 22)
                TextField("Payee", text: $payee)
                    .textInputAutocapitalization(.words)
            }

            HStack {
                Image(systemName: "tag").frame(width: 22)
                Picker("Category", selection: $selectedCategoryID) {
                    Text("None").tag(UUID?.none)
                    ForEach(relevantCategories) { c in
                        Text(c.name).tag(Optional(c.id))
                    }
                }
            }

            HStack {
                Image(systemName: "creditcard").frame(width: 22)
                Picker("Account", selection: $selectedAccountID) {
                    Text("None").tag(UUID?.none)
                    ForEach(activeAccounts) { a in
                        Text(a.name).tag(Optional(a.id))
                    }
                }
            }

            HStack {
                Image(systemName: "calendar").frame(width: 22)
                DatePicker("Date", selection: $date, displayedComponents: [.date])
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Optional", text: $notes, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                if let tx = editing {
                    if let acc = tx.account {
                        // reverse the running balance before delete
                        if tx.isIncome { acc.currentBalance -= tx.amount }
                        else            { acc.currentBalance += tx.amount }
                    }
                    modelContext.delete(tx)
                    try? modelContext.save()
                    Haptics.impact()
                    dismiss()
                }
            } label: {
                HStack {
                    Spacer()
                    Label("Delete Transaction", systemImage: "trash")
                    Spacer()
                }
            }
        }
    }

    // MARK: - Derived

    private var activeAccounts: [Account] {
        allAccounts.filter { !$0.isArchived }
    }

    private var relevantCategories: [BudgetCategory] {
        allCategories.filter { isIncome ? !$0.isExpenseCategory : $0.isExpenseCategory }
    }

    private var canSave: Bool {
        amount > 0 && !payee.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var currencySymbol: String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = defaultCurrency
        return nf.currencySymbol ?? "$"
    }

    // MARK: - Save

    private func save() {
        let category = selectedCategoryID.flatMap { id in allCategories.first { $0.id == id } }
        let account = selectedAccountID.flatMap { id in allAccounts.first { $0.id == id } }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        let trimmedPayee = payee.trimmingCharacters(in: .whitespaces)

        if let tx = editing {
            // Reverse the original account's running balance, mutate the
            // tx, then apply the new running balance. This is what the Mac
            // edit path does — keeps account.currentBalance correct even
            // when the user moves a tx between accounts or flips its sign.
            if let originalAccountID,
               let originalAccount = allAccounts.first(where: { $0.id == originalAccountID }) {
                if originalIsIncome { originalAccount.currentBalance -= originalAmount }
                else                 { originalAccount.currentBalance += originalAmount }
            }

            tx.date = date
            tx.payee = trimmedPayee
            tx.amount = amount
            tx.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
            tx.isIncome = isIncome
            tx.account = account
            tx.category = category

            if let account {
                if isIncome { account.currentBalance += amount }
                else         { account.currentBalance -= amount }
            }
        } else {
            let tx = Transaction(
                date: date,
                payee: trimmedPayee,
                amount: amount,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                isIncome: isIncome,
                account: account,
                category: category
            )
            modelContext.insert(tx)

            if let account {
                if isIncome { account.currentBalance += amount }
                else         { account.currentBalance -= amount }
            }
        }

        try? modelContext.save()
        Haptics.impact()
        dismiss()
    }
}
#endif
