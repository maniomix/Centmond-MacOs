import SwiftUI

// ============================================================
// MARK: - AI Action Card
// ============================================================
//
// Detailed card showing a parsed AI action with confirm/reject buttons.
// Appears inline in the chat after assistant messages.
//
// macOS Centmond: amounts are Double (dollars), not Int (cents).
//
// ============================================================

struct AIActionCard: View {
    let action: AIAction
    let onConfirm: (UUID) -> Void
    let onReject: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(DS.Colors.text)
                Spacer()
                statusBadge
            }

            // Detailed info rows
            if !detailRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(detailRows, id: \.label) { row in
                        HStack(spacing: 6) {
                            Image(systemName: row.icon)
                                .font(.caption2)
                                .foregroundStyle(DS.Colors.subtext)
                                .frame(width: 14)
                            Text(row.label)
                                .font(.caption)
                                .foregroundStyle(DS.Colors.subtext)
                            Spacer()
                            Text(row.value)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(DS.Colors.text)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(colorScheme == .dark
                              ? Color.white.opacity(0.05)
                              : Color.black.opacity(0.03))
                )
            }

            // Rich analysis block
            if let text = action.params.analysisText, !text.isEmpty {
                analysisBlock(text)
            }

            // Buttons — only show for pending actions
            if action.status == .pending {
                HStack(spacing: 12) {
                    Button {
                        onReject(action.id)
                    } label: {
                        Text("Skip")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DS.Colors.subtext)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(DS.Colors.surface2)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onConfirm(action.id)
                    } label: {
                        Text("Confirm")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accentColor.opacity(action.status == .pending ? 0.4 : 0.15), lineWidth: 1)
        )
        .opacity(action.status == .rejected ? 0.5 : 1.0)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .scaleEffect(appeared ? 1 : 0.92)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) {
                appeared = true
            }
        }
    }

    // MARK: - Detail Rows

    private struct DetailRow: Hashable {
        let icon: String
        let label: String
        let value: String
    }

    private var detailRows: [DetailRow] {
        let p = action.params
        var rows: [DetailRow] = []

        if let amt = p.amount { rows.append(DetailRow(icon: "dollarsign.circle", label: "Amount", value: fmtDollars(amt))) }
        if let amt = p.budgetAmount { rows.append(DetailRow(icon: "dollarsign.circle", label: "Budget", value: fmtDollars(amt))) }
        if let amt = p.contributionAmount { rows.append(DetailRow(icon: "dollarsign.circle", label: "Contribution", value: fmtDollars(amt))) }
        if let amt = p.subscriptionAmount { rows.append(DetailRow(icon: "dollarsign.circle", label: "Amount", value: fmtDollars(amt))) }
        if let amt = p.goalTarget { rows.append(DetailRow(icon: "target", label: "Target", value: fmtDollars(amt))) }
        if let amt = p.accountBalance { rows.append(DetailRow(icon: "banknote", label: "Balance", value: fmtDollars(amt))) }
        if let cat = p.category { rows.append(DetailRow(icon: "square.grid.2x2", label: "Category", value: cat.capitalized)) }
        if let cat = p.budgetCategory { rows.append(DetailRow(icon: "square.grid.2x2", label: "Category", value: cat.capitalized)) }
        if let type = p.transactionType {
            rows.append(DetailRow(icon: type == "income" ? "arrow.down.circle" : "arrow.up.circle",
                                  label: "Type", value: type.capitalized))
        }
        if let note = p.note, !note.isEmpty { rows.append(DetailRow(icon: "note.text", label: "Note", value: note)) }
        if let date = p.date { rows.append(DetailRow(icon: "calendar", label: "Date", value: formatDateDisplay(date))) }
        if let month = p.budgetMonth { rows.append(DetailRow(icon: "calendar", label: "Month", value: month)) }
        if let name = p.goalName { rows.append(DetailRow(icon: "target", label: "Goal", value: name)) }
        if let deadline = p.goalDeadline { rows.append(DetailRow(icon: "clock", label: "Deadline", value: deadline)) }
        if let name = p.subscriptionName { rows.append(DetailRow(icon: "repeat.circle", label: "Name", value: name)) }
        if let freq = p.subscriptionFrequency { rows.append(DetailRow(icon: "clock.arrow.circlepath", label: "Frequency", value: freq.capitalized)) }
        if let partner = p.splitWith { rows.append(DetailRow(icon: "person.2", label: "Split with", value: partner)) }
        if let ratio = p.splitRatio { rows.append(DetailRow(icon: "percent", label: "Your share", value: "\(Int(ratio * 100))%")) }
        if let name = p.accountName { rows.append(DetailRow(icon: "building.columns", label: "Account", value: name)) }
        if let from = p.fromAccount { rows.append(DetailRow(icon: "arrow.right.circle", label: "From", value: from)) }
        if let to = p.toAccount { rows.append(DetailRow(icon: "arrow.left.circle", label: "To", value: to)) }
        if let name = p.recurringName { rows.append(DetailRow(icon: "clock.arrow.2.circlepath", label: "Recurring", value: name)) }
        if let freq = p.recurringFrequency { rows.append(DetailRow(icon: "clock.arrow.circlepath", label: "Frequency", value: freq.capitalized)) }

        return rows
    }

    // MARK: - Computed Properties

    private var iconName: String {
        switch action.type {
        case .addTransaction: return "plus.circle.fill"
        case .editTransaction: return "pencil.circle.fill"
        case .deleteTransaction: return "trash.circle.fill"
        case .splitTransaction: return "arrow.triangle.branch"
        case .transfer: return "arrow.left.arrow.right.circle.fill"
        case .addRecurring: return "clock.arrow.2.circlepath"
        case .editRecurring: return "pencil.circle.fill"
        case .cancelRecurring: return "xmark.circle.fill"
        case .setBudget, .adjustBudget: return "chart.pie.fill"
        case .setCategoryBudget: return "slider.horizontal.3"
        case .createGoal: return "target"
        case .addContribution: return "arrow.up.circle.fill"
        case .updateGoal: return "pencil"
        case .addSubscription: return "repeat.circle.fill"
        case .cancelSubscription: return "xmark.circle.fill"
        case .updateBalance: return "banknote.fill"
        case .assignMember: return "person.badge.plus"
        case .analyze, .compare, .forecast, .advice: return "chart.bar.xaxis"
        }
    }

    private var accentColor: Color {
        switch action.type {
        case .deleteTransaction, .cancelSubscription, .cancelRecurring: return DS.Colors.danger
        case .addTransaction, .addContribution, .addSubscription, .addRecurring: return DS.Colors.positive
        case .setBudget, .adjustBudget, .setCategoryBudget: return DS.Colors.warning
        case .createGoal, .updateGoal: return DS.Colors.accent
        case .transfer: return DS.Colors.accent
        default: return DS.Colors.accent
        }
    }

    private var title: String {
        switch action.type {
        case .addTransaction:
            let type = action.params.transactionType == "income" ? "Income" : "Expense"
            return "Add \(type)"
        case .editTransaction: return "Edit Transaction"
        case .deleteTransaction: return "Delete Transaction"
        case .splitTransaction: return "Split Transaction"
        case .transfer: return "Transfer"
        case .addRecurring: return "Add Recurring"
        case .editRecurring: return "Edit Recurring"
        case .cancelRecurring: return "Cancel Recurring"
        case .setBudget, .adjustBudget: return "Set Monthly Budget"
        case .setCategoryBudget: return "Set Category Budget"
        case .createGoal: return "Create Goal"
        case .addContribution: return "Add to Goal"
        case .updateGoal: return "Update Goal"
        case .addSubscription: return "Add Subscription"
        case .cancelSubscription: return "Cancel Subscription"
        case .updateBalance: return "Update Balance"
        case .assignMember: return "Assign Member"
        case .analyze, .compare, .forecast, .advice: return "Analysis"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch action.status {
        case .pending:
            EmptyView()
        case .confirmed:
            Label("Processing…", systemImage: "hourglass.circle.fill")
                .font(.caption2)
                .foregroundStyle(DS.Colors.warning)
        case .rejected:
            Label("Skipped", systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(DS.Colors.subtext)
        case .executed:
            Label("Done", systemImage: "checkmark.seal.fill")
                .font(.caption2)
                .foregroundStyle(DS.Colors.positive)
        }
    }

    // MARK: - Rich Analysis Block

    private func analysisBlock(_ text: String) -> some View {
        let entries = parseAnalysisEntries(text)

        return VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(DS.Colors.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(categoryColor(for: idx))
                            .frame(width: 8, height: 8)
                        Text(entry.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DS.Colors.text)
                        Spacer()
                        Text(entry.value)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DS.Colors.text)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                    if idx < entries.count - 1 {
                        Divider().padding(.horizontal, 10)
                    }
                }

                if entries.count > 1 {
                    let total = entries.compactMap { parseDollarAmount($0.value) }.reduce(0.0, +)
                    if total > 0 {
                        Divider().padding(.horizontal, 10)
                        HStack {
                            Text("Total")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DS.Colors.subtext)
                            Spacer()
                            Text(String(format: "$%.2f", total))
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(DS.Colors.accent)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color.white.opacity(0.05)
                      : Color.black.opacity(0.03))
        )
    }

    private struct AnalysisEntry {
        let label: String
        let value: String
    }

    private func parseAnalysisEntries(_ text: String) -> [AnalysisEntry] {
        var entries: [AnalysisEntry] = []

        // Split by newlines first, then by commas — but only commas NOT inside parentheses
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var segments: [String] = []
        for line in lines {
            segments.append(contentsOf: splitIgnoringParentheses(line))
        }

        for segment in segments {
            // Strip parenthetical content from labels: "Shopping (clothes, shoes)" → "Shopping"
            let cleaned = segment.replacingOccurrences(
                of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression
            )

            if let dollarIdx = cleaned.range(of: "$") {
                let beforeDollar = String(cleaned[cleaned.startIndex..<dollarIdx.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var label = beforeDollar
                if label.hasSuffix(":") { label = String(label.dropLast()).trimmingCharacters(in: .whitespaces) }
                if let lastColon = label.lastIndex(of: ":") {
                    label = String(label[label.index(after: lastColon)...]).trimmingCharacters(in: .whitespaces)
                }
                // Remove leading conjunctions
                for prefix in ["and ", "و "] {
                    if label.lowercased().hasPrefix(prefix) {
                        label = String(label.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    }
                }
                let valueStr = String(cleaned[dollarIdx.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanValue = extractDollarValue(valueStr)
                let pctMatch = extractPercentage(from: segment)

                if !label.isEmpty && !cleanValue.isEmpty {
                    let lowerLabel = label.lowercased()
                    if !lowerLabel.contains("breakdown") && !lowerLabel.contains("total") {
                        let displayValue = pctMatch != nil ? "\(cleanValue) (\(pctMatch!))" : cleanValue
                        entries.append(AnalysisEntry(label: label, value: displayValue))
                    }
                }
            } else if let colonRange = cleaned.range(of: ":") {
                let label = cleaned[cleaned.startIndex..<colonRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = cleaned[colonRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty && !value.isEmpty && Double(value.replacingOccurrences(of: ",", with: "")) != nil {
                    entries.append(AnalysisEntry(label: label, value: value))
                }
            }
        }
        return entries
    }

    /// Split a string by commas, but ignore commas inside parentheses.
    private func splitIgnoringParentheses(_ text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var depth = 0
        for char in text {
            if char == "(" { depth += 1 }
            else if char == ")" { depth = max(0, depth - 1) }

            if char == "," && depth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { segments.append(trimmed) }
                current = ""
            } else {
                current.append(char)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { segments.append(trimmed) }
        return segments
    }

    private func extractDollarValue(_ str: String) -> String {
        var result = ""
        var inDollar = false
        for char in str {
            if char == "$" { inDollar = true }
            if inDollar {
                if char == "$" || char == "." || char == "," || char.isNumber { result.append(char) }
                else { break }
            }
        }
        return result
    }

    private func extractPercentage(from text: String) -> String? {
        let parts = text.components(separatedBy: .whitespaces)
        for part in parts {
            let cleaned = part.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: ".%")))
            if cleaned.hasSuffix("%") && cleaned.count > 1 {
                let numPart = cleaned.dropLast()
                if Double(numPart) != nil { return cleaned }
            }
        }
        return nil
    }

    private func parseDollarAmount(_ str: String) -> Double? {
        let cleaned = extractDollarValue(str)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    private func categoryColor(for index: Int) -> Color {
        let colors: [Color] = [
            DS.Colors.accent, DS.Colors.positive, DS.Colors.warning, DS.Colors.danger,
            .purple, .cyan, .orange, .mint, .indigo, .teal
        ]
        return colors[index % colors.count]
    }

    private func fmtDollars(_ dollars: Double) -> String {
        if dollars == dollars.rounded() && dollars >= 1 {
            return String(format: "$%.0f", dollars)
        }
        return String(format: "$%.2f", dollars)
    }

    private func formatDateDisplay(_ date: String) -> String {
        if date == "today" { return "Today" }
        if date == "yesterday" { return "Yesterday" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        if let d = formatter.date(from: date) {
            let display = DateFormatter()
            display.dateStyle = .medium
            return display.string(from: d)
        }
        return date
    }
}
