#if os(iOS)
import SwiftUI
import SwiftData

/// iOS Add Transaction sheet (Track B3). Bare minimum to capture a tx
/// so iOS isn't read-only. Saving inserts into modelContext; the
/// CloudSyncCoordinator's willSave hook queues the upload, and the
/// next debounce window (2 s) pushes it to Supabase.
struct IOSAddTransactionSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BudgetCategory.sortOrder) private var allCategories: [BudgetCategory]
    @Query(sort: \Account.name) private var allAccounts: [Account]
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"

    @State private var isIncome: Bool = false
    @State private var amount: Decimal = 0
    @State private var payee: String = ""
    @State private var date: Date = .now
    @State private var notes: String = ""
    @State private var selectedAccountID: UUID?
    @State private var selectedCategoryID: UUID?

    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                amountSection
                detailsSection
                notesSection
            }
            .navigationTitle("New Transaction")
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
                amountFocused = true
                if selectedAccountID == nil {
                    selectedAccountID = activeAccounts.first?.id
                }
                if selectedCategoryID == nil {
                    selectedCategoryID = relevantCategories.first?.id
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

        let tx = Transaction(
            date: date,
            payee: payee.trimmingCharacters(in: .whitespaces),
            amount: amount,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            isIncome: isIncome,
            account: account,
            category: category
        )
        modelContext.insert(tx)

        // Mirror Mac semantics: a manual entry adjusts the linked account's
        // running balance immediately so dashboards/account cards reflect it
        // before the next aggregate refresh runs.
        if let account {
            if isIncome {
                account.currentBalance += amount
            } else {
                account.currentBalance -= amount
            }
        }

        try? modelContext.save()
        Haptics.impact()
        dismiss()
    }
}
#endif
