import SwiftUI

// ============================================================
// MARK: - AI Suggested Prompts
// ============================================================
//
// Tappable prompt chips shown when the chat is empty.
//
// ============================================================

struct AISuggestedPrompts: View {
    let onSelect: (String) -> Void

    private let prompts: [(icon: String, text: String)] = [
        ("cart", "Add a $15 lunch expense"),
        ("chart.pie", "How much did I spend on dining this month?"),
        ("target", "Create a vacation savings goal for $2000"),
        ("arrow.triangle.branch", "Split a $80 dinner with Sara"),
        ("chart.bar", "Show me my spending breakdown"),
        ("banknote", "Set my monthly budget to $3000"),
        ("lightbulb", "Any tips to save more?"),
        ("repeat.circle", "What subscriptions do I have?"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.subtext)
                .padding(.horizontal, 4)

            FlowLayout(spacing: 8) {
                ForEach(prompts, id: \.text) { prompt in
                    Button {
                        onSelect(prompt.text)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: prompt.icon)
                                .font(.system(size: 12))
                            Text(prompt.text)
                                .font(DS.Typography.caption)
                        }
                        .foregroundStyle(DS.Colors.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Flow Layout

/// Simple flow layout that wraps items to the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for row in rows {
            height += row.maxHeight
            if row !== rows.last { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.sizeThatFits(.unspecified)
                item.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.maxHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]
        var x: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
                x = 0
            }
            rows[rows.count - 1].items.append(subview)
            rows[rows.count - 1].maxHeight = max(rows[rows.count - 1].maxHeight, size.height)
            x += size.width + spacing
        }
        return rows
    }

    private class Row {
        var items: [LayoutSubviews.Element] = []
        var maxHeight: CGFloat = 0
    }
}
