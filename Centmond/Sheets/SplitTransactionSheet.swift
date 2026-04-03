import SwiftUI
import SwiftData

struct SplitTransactionSheet: View {
    let transaction: Transaction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var splits: [SplitEntry] = []

    private var originalAmount: Decimal { transaction.amount }
    private var allocatedAmount: Decimal { splits.reduce(0) { $0 + ($1.decimal ?? 0) } }
    private var remainingAmount: Decimal { originalAmount - allocatedAmount }
    private var isValid: Bool { splits.count >= 2 && remainingAmount == 0 }

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
                        .buttonStyle(.plain)
                    }

                    // Remaining
                    HStack {
                        Text("Remaining")
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        Spacer()
                        Text(CurrencyFormat.standard(remainingAmount))
                            .font(CentmondTheme.Typography.mono)
                            .foregroundStyle(remainingAmount == 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.warning)
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.xxl)
                .padding(.vertical, CentmondTheme.Spacing.lg)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Split Transaction") { saveSplits() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isValid)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 450)
        .onAppear {
            if splits.isEmpty {
                splits = [SplitEntry(), SplitEntry()]
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
            .frame(width: 120, height: CentmondTheme.Sizing.inputHeight)
            .background(CentmondTheme.Colors.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
            )

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
                .buttonStyle(.plain)
            }
        }
    }

    private func saveSplits() {
        // TODO: Create child transactions from splits
        dismiss()
    }
}

private struct SplitEntry: Identifiable {
    let id = UUID()
    var amount = ""
    var note = ""

    var decimal: Decimal? { Decimal(string: amount) }
}
