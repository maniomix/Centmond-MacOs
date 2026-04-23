import SwiftUI
import SwiftData

struct SplitTransactionSheet: View {
    let transaction: Transaction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var splits: [SplitEntry] = []
    @State private var saveError: String?

    /// Reconciliation tolerance: a split set is valid if |sum - parent| ≤ this.
    /// Decision Q3 — exact match preferred, 1¢ slack for rounding noise.
    private static let reconcileTolerance: Decimal = Decimal(string: "0.01") ?? 0

    private var originalAmount: Decimal { transaction.amount }
    private var allocatedAmount: Decimal {
        splits.reduce(0) { $0 + (DecimalInput.parseNonNegative($1.amount) ?? 0) }
    }
    private var remainingAmount: Decimal { originalAmount - allocatedAmount }
    private var remainingMagnitude: Decimal {
        remainingAmount < 0 ? -remainingAmount : remainingAmount
    }
    private var filteredCategories: [BudgetCategory] {
        categories.filter { transaction.isIncome ? !$0.isExpenseCategory : $0.isExpenseCategory }
    }
    private var isReconciled: Bool { remainingMagnitude <= Self.reconcileTolerance }
    private var allRowsParse: Bool {
        splits.allSatisfy { DecimalInput.parsePositive($0.amount) != nil }
    }
    private var isValid: Bool { splits.count >= 2 && allRowsParse && isReconciled }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SheetHeader(title: "Split Transaction") { dismiss() }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xl) {
                    // Original transaction info
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                        Text("ORIGINAL TRANSACTION")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.3)

                        HStack {
                            Text(transaction.payee)
                                .font(CentmondTheme.Typography.bodyMedium)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            Spacer()
                            Text(CurrencyFormat.standard(originalAmount))
                                .font(CentmondTheme.Typography.mono)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        }
                        .padding(CentmondTheme.Spacing.sm)
                        .background(CentmondTheme.Colors.bgQuaternary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
                    }

                    // Splits
                    VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                        Text("SPLITS")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            .tracking(0.3)

                        ForEach($splits) { $split in
                            splitRow(split: $split)
                        }

                        Button {
                            splits.append(SplitEntry())
                        } label: {
                            Label("Add Split", systemImage: "plus")
                                .font(CentmondTheme.Typography.bodyMedium)
                                .foregroundStyle(CentmondTheme.Colors.accent)
                        }
                        .buttonStyle(.plainHover)
                    }

                    // Remaining
                    HStack {
                        Text("Remaining")
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        Spacer()
                        Text(CurrencyFormat.standard(remainingAmount))
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(isReconciled ? CentmondTheme.Colors.positive : CentmondTheme.Colors.warning)
                    }

                    if let error = saveError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(CentmondTheme.Typography.overlineRegular)
                            Text(error)
                        }
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Footer
            HStack {
                if !transaction.splits.isEmpty {
                    Button(role: .destructive) {
                        clearSplits()
                    } label: {
                        Label("Clear Splits", systemImage: "trash")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button(transaction.splits.isEmpty ? "Split Transaction" : "Save Splits") { saveSplits() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isValid)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 480)
        .onAppear {
            if splits.isEmpty {
                if transaction.splits.isEmpty {
                    splits = [SplitEntry(), SplitEntry()]
                } else {
                    splits = transaction.splits
                        .sorted(by: { $0.sortOrder < $1.sortOrder })
                        .map {
                            SplitEntry(
                                amount: DecimalInput.editableString($0.amount),
                                note: $0.memo ?? "",
                                category: $0.category
                            )
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func splitRow(split: Binding<SplitEntry>) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            HStack {
                Text("$")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                TextField("0.00", text: split.amount)
                    .textFieldStyle(.plain)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
            }
            .padding(.horizontal, CentmondTheme.Spacing.sm)
            .frame(width: 110, height: CentmondTheme.Sizing.inputHeight)
            .background(CentmondTheme.Colors.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
            )

            Picker("", selection: split.category) {
                Text("Uncategorized").tag(nil as BudgetCategory?)
                ForEach(filteredCategories) { category in
                    Label(category.name, systemImage: category.icon)
                        .tag(category as BudgetCategory?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 150)

            TextField("Note (optional)", text: split.note)
                .textFieldStyle(.plain)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .padding(.horizontal, CentmondTheme.Spacing.sm)
                .frame(height: CentmondTheme.Sizing.inputHeight)
                .background(CentmondTheme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                        .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
                )

            if splits.count > 2 {
                Button {
                    splits.removeAll { $0.id == split.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(CentmondTheme.Colors.negative)
                }
                .buttonStyle(.plainHover)
            }
        }
    }

    private func saveSplits() {
        guard splits.count >= 2 else {
            saveError = "Add at least two splits"
            return
        }
        guard allRowsParse else {
            saveError = "Each split needs a positive amount"
            return
        }
        guard isReconciled else {
            saveError = "Splits must add up to the transaction amount"
            return
        }

        // Replace existing splits. Cascade delete on Transaction.splits
        // removes the old TransactionSplit rows when we drop the references.
        for old in transaction.splits {
            modelContext.delete(old)
        }

        var newSplits: [TransactionSplit] = []
        for (index, entry) in splits.enumerated() {
            guard let amount = DecimalInput.parsePositive(entry.amount) else { continue }
            let split = TransactionSplit(
                amount: amount,
                memo: TextNormalization.trimmedOrNil(entry.note),
                sortOrder: index,
                parentTransaction: transaction,
                category: entry.category
            )
            modelContext.insert(split)
            newSplits.append(split)
        }
        transaction.splits = newSplits
        transaction.updatedAt = .now
        Haptics.impact()
        dismiss()
    }

    private func clearSplits() {
        for old in transaction.splits {
            modelContext.delete(old)
        }
        transaction.splits = []
        transaction.updatedAt = .now
        Haptics.tap()
        dismiss()
    }
}

private struct SplitEntry: Identifiable {
    let id = UUID()
    var amount: String = ""
    var note: String = ""
    var category: BudgetCategory? = nil
}
