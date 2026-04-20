import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// ============================================================
// MARK: - AI Receipt Scanner View
// ============================================================
//
// File-picker based receipt scanning for macOS.
// Shows parsed results with confirm/edit before adding.
//
// macOS Centmond: NSImage, NSOpenPanel, ModelContext,
// Decimal amounts, BudgetCategory lookup.
//
// ============================================================

struct AIReceiptScannerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let scanner = AIReceiptScanner.shared
    @State private var scannedImage: NSImage?
    @State private var showConfirm = false

    // Editable fields after scan
    @State private var editAmount: String = ""
    @State private var editMerchant: String = ""
    @State private var editCategoryName: String = "Other"
    @State private var editDate: Date = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if scanner.isScanning {
                    scanningView
                } else if let result = scanner.lastResult, showConfirm {
                    confirmView(result)
                } else {
                    pickerView
                }
            }
            .padding()
            .background(DS.Colors.bg)
            .navigationTitle("Scan Receipt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DS.Colors.subtext)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 500)
    }

    // MARK: - Picker View

    private var pickerView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 60))
                .foregroundStyle(DS.Colors.accent)

            Text("Scan a Receipt")
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.text)

            Text("Choose an image from your Mac. We'll extract the amount, merchant, and date automatically.")
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.subtext)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button {
                    openFilePicker()
                } label: {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text("Choose Image")
                    }
                    .font(DS.Typography.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if let error = scanner.errorMessage {
                Text(error)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.danger)
            }

            Spacer()
        }
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Scanning receipt...")
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.subtext)
            Spacer()
        }
    }

    // MARK: - Confirm View

    private func confirmView(_ result: ReceiptData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Preview image thumbnail
                if let img = scannedImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                }

                DS.Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scanned Data")
                            .font(DS.Typography.section)
                            .foregroundStyle(DS.Colors.text)

                        Divider()

                        // Merchant
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Merchant")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Colors.subtext)
                            TextField("Merchant name", text: $editMerchant)
                                .font(DS.Typography.body)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Amount
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Amount")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Colors.subtext)
                            TextField("0.00", text: $editAmount)
                                .font(DS.Typography.body)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Date
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Date")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Colors.subtext)
                            DatePicker("", selection: $editDate, displayedComponents: .date)
                                .labelsHidden()
                        }

                        // Category
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Category")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Colors.subtext)

                            let categories = fetchCategoryNames()
                            Picker("Category", selection: $editCategoryName) {
                                ForEach(categories, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(DS.Colors.accent)
                        }
                    }
                }

                // Line items
                if !result.lineItems.isEmpty {
                    DS.Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Line Items")
                                .font(DS.Typography.section)
                                .foregroundStyle(DS.Colors.text)

                            ForEach(result.lineItems) { item in
                                HStack {
                                    Text(item.description)
                                        .font(DS.Typography.caption)
                                        .foregroundStyle(DS.Colors.text)
                                    Spacer()
                                    Text(String(format: "$%.2f", item.amount))
                                        .font(DS.Typography.caption)
                                        .foregroundStyle(DS.Colors.subtext)
                                }
                            }
                        }
                    }
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        scanner.lastResult = nil
                        showConfirm = false
                    } label: {
                        Text("Rescan")
                            .font(DS.Typography.callout)
                            .foregroundStyle(DS.Colors.subtext)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(DS.Colors.subtext.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        addTransaction()
                    } label: {
                        Text("Add Transaction")
                            .font(DS.Typography.callout)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a receipt image"
        panel.prompt = "Open"

        if panel.runModal() == .OK, let url = panel.url,
           let image = NSImage(contentsOf: url) {
            scannedImage = image
            startScan(image: image)
        }
    }

    private func startScan(image: NSImage) {
        Task {
            if let result = await scanner.scan(image: image) {
                // Populate editable fields
                editMerchant = result.merchantName ?? ""
                if let amount = result.totalAmount {
                    editAmount = String(format: "%.2f", amount)
                }
                editDate = result.date ?? Date()

                // Auto-suggest category from merchant name
                if let merchant = result.merchantName,
                   let suggested = AICategorySuggester.shared.suggest(note: merchant) {
                    editCategoryName = suggested
                }

                showConfirm = true
            }
        }
    }

    private func addTransaction() {
        guard let value = Double(editAmount.replacingOccurrences(of: ",", with: ".")),
              value > 0 else { return }

        let amount = Decimal(value)

        // Look up BudgetCategory by name
        let catName = editCategoryName
        var descriptor = FetchDescriptor<BudgetCategory>(
            predicate: #Predicate { $0.name == catName }
        )
        descriptor.fetchLimit = 1
        let category = try? context.fetch(descriptor).first

        // Get default account (first by sortOrder)
        var accountDescriptor = FetchDescriptor<Account>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        accountDescriptor.fetchLimit = 1
        let account = try? context.fetch(accountDescriptor).first

        let txn = Transaction(
            date: editDate,
            payee: editMerchant.isEmpty ? "Receipt scan" : editMerchant,
            amount: amount,
            isIncome: false,
            account: account,
            category: category
        )
        context.insert(txn)
        try? context.save()

        SubscriptionReconciliationService.reconcile(transaction: txn, in: context)

        // Learn from this
        if !editMerchant.isEmpty {
            AICategorySuggester.shared.learn(note: editMerchant, categoryName: editCategoryName)
        }

        // Event insight
        AIInsightEngine.shared.onTransactionAdded(txn, context: context)

        dismiss()
    }

    // MARK: - Helpers

    private func fetchCategoryNames() -> [String] {
        let descriptor = FetchDescriptor<BudgetCategory>(
            sortBy: [SortDescriptor(\.name)]
        )
        let categories = (try? context.fetch(descriptor)) ?? []
        var names = categories.map(\.name)
        if !names.contains(editCategoryName) {
            names.append(editCategoryName)
        }
        return names.sorted()
    }
}
