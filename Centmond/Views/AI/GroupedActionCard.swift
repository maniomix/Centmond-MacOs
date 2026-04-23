import SwiftUI

// ============================================================
// MARK: - Grouped Action Card
// ============================================================
//
// Shows multiple identical actions as a single compact card.
// e.g. "5× Add Expense: $5 each — Total: $25"
//
// macOS Centmond: amounts are Double (dollars), not Int (cents).
//
// ============================================================

struct GroupedActionCard: View {
    let actions: [AIAction]
    let onConfirmAll: () -> Void
    let onRejectAll: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var template: AIAction { actions[0] }
    private var count: Int { actions.count }
    private var allPending: Bool { actions.allSatisfy { $0.status == .pending } }
    private var allExecuted: Bool { actions.allSatisfy { $0.status == .executed } }
    private var allRejected: Bool { actions.allSatisfy { $0.status == .rejected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(CentmondTheme.Typography.subheading)
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(DS.Colors.text)
                Text("×\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accentColor))
                Spacer()
                statusBadge
            }

            VStack(alignment: .leading, spacing: 6) {
                if let amt = template.params.amount {
                    summaryRow(icon: "dollarsign.circle", label: "Each", value: fmtDollars(amt))
                    summaryRow(icon: "sum", label: "Total", value: fmtDollars(amt * Double(count)))
                }
                if let amt = template.params.budgetAmount {
                    summaryRow(icon: "dollarsign.circle", label: "Each", value: fmtDollars(amt))
                }
                if let cat = template.params.category {
                    summaryRow(icon: "square.grid.2x2", label: "Category", value: cat.capitalized)
                }
                if let type = template.params.transactionType {
                    summaryRow(icon: type == "income" ? "arrow.down.circle" : "arrow.up.circle",
                              label: "Type", value: type.capitalized)
                }
                if let date = template.params.date {
                    summaryRow(icon: "calendar", label: "Date", value: date == "today" ? "Today" : date)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color.white.opacity(0.05)
                          : Color.black.opacity(0.03))
            )

            if allPending {
                HStack(spacing: 12) {
                    Button {
                        onRejectAll()
                    } label: {
                        Text("Skip All")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DS.Colors.subtext)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                                    .fill(DS.Colors.surface2)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onConfirmAll()
                    } label: {
                        Text("Confirm All (\(count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous)
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .strokeBorder(accentColor.opacity(allPending ? 0.4 : 0.15), lineWidth: 1)
        )
        .opacity(allRejected ? 0.5 : 1.0)
    }

    // MARK: - Helpers

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(DS.Colors.subtext)
                .frame(width: 14)
            Text(label)
                .font(.caption)
                .foregroundStyle(DS.Colors.subtext)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(DS.Colors.text)
        }
    }

    private var iconName: String {
        switch template.type {
        case .addTransaction: return "plus.circle.fill"
        case .setBudget, .adjustBudget: return "chart.pie.fill"
        default: return "square.stack.fill"
        }
    }

    private var accentColor: Color {
        switch template.type {
        case .deleteTransaction, .cancelSubscription: return DS.Colors.danger
        case .addTransaction, .addContribution, .addSubscription: return DS.Colors.positive
        case .setBudget, .adjustBudget, .setCategoryBudget: return DS.Colors.warning
        default: return DS.Colors.accent
        }
    }

    private var title: String {
        switch template.type {
        case .addTransaction:
            let type = template.params.transactionType == "income" ? "Income" : "Expense"
            return "Add \(type)"
        case .setBudget, .adjustBudget: return "Set Budget"
        default: return template.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if allExecuted {
            Label("Done", systemImage: "checkmark.seal.fill")
                .font(.caption2)
                .foregroundStyle(DS.Colors.positive)
        } else if allRejected {
            Label("Skipped", systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(DS.Colors.subtext)
        } else if !allPending {
            Label("Processing…", systemImage: "hourglass.circle.fill")
                .font(.caption2)
                .foregroundStyle(DS.Colors.warning)
        }
    }

    private func fmtDollars(_ dollars: Double) -> String {
        if dollars == dollars.rounded() && dollars >= 1 {
            return String(format: "$%.0f", dollars)
        }
        return String(format: "$%.2f", dollars)
    }
}
