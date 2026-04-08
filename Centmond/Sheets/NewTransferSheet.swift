import SwiftUI
import SwiftData

struct NewTransferSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var amount = ""
    @State private var fromAccount: Account?
    @State private var toAccount: Account?
    @State private var date = Date.now
    @State private var notes = ""
    @State private var saveError: String?

    private var parsedAmount: Decimal? { DecimalInput.parsePositive(amount) }
    private var sameAccount: Bool {
        guard let f = fromAccount, let t = toAccount else { return false }
        return f.id == t.id
    }
    private var isValid: Bool {
        parsedAmount != nil && fromAccount != nil && toAccount != nil && !sameAccount
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New Transfer") { dismiss() }
            Divider().background(CentmondTheme.Colors.strokeSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                    field("Amount") {
                        HStack {
                            Text("$")
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                            TextField("0.00", text: $amount)
                                .textFieldStyle(.plain)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                                .monospacedDigit()
                        }
                    }

                    field("From Account") {
                        Picker("", selection: $fromAccount) {
                            Text("Select…").tag(nil as Account?)
                            ForEach(accounts) { account in
                                Text(account.name).tag(account as Account?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    field("To Account") {
                        Picker("", selection: $toAccount) {
                            Text("Select…").tag(nil as Account?)
                            ForEach(accounts) { account in
                                Text(account.name).tag(account as Account?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    if sameAccount {
                        Text("From and To must differ")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.warning)
                    }

                    field("Date") {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.field)
                            .labelsHidden()
                    }

                    field("Notes") {
                        TextField("Optional", text: $notes, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(CentmondTheme.Typography.body)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .lineLimit(2...4)
                    }

                    if let error = saveError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 10))
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

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Create Transfer") { saveTransfer() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isValid)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
        }
        .frame(minHeight: 460)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
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

    private func saveTransfer() {
        guard let amount = parsedAmount else {
            saveError = "Enter a valid amount"
            return
        }
        guard let from = fromAccount, let to = toAccount else {
            saveError = "Pick both accounts"
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
            in: modelContext
        ) != nil else {
            saveError = "Could not create transfer"
            return
        }
        Haptics.impact()
        dismiss()
    }
}
