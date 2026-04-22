import SwiftUI

struct BudgetHeatmapBodyView: View {
    let heatmap: Heatmap

    private var maxValue: Double {
        heatmap.cells.map { Double(truncating: $0.value as NSDecimalNumber) }.max() ?? 1
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    Text("Budget performance")
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Spacer()
                    legend
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        headerRow
                        ForEach(heatmap.rowLabels.indices, id: \.self) { rIdx in
                            HStack(spacing: 4) {
                                Text(heatmap.rowLabels[rIdx])
                                    .font(CentmondTheme.Typography.caption)
                                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                                    .frame(width: 150, alignment: .leading)
                                    .lineLimit(1)

                                ForEach(cells(for: rIdx)) { indexed in
                                    heatCell(indexed.cell)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 4) {
            Text("").frame(width: 150)
            ForEach(heatmap.columnLabels.indices, id: \.self) { cIdx in
                Text(heatmap.columnLabels[cIdx])
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 72, alignment: .center)
                    .lineLimit(1)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendSwatch(color: CentmondTheme.Colors.accent, label: "Spend")
            legendSwatch(color: CentmondTheme.Colors.negative, label: "Over budget")
        }
    }

    private func legendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.6)).frame(width: 12, height: 12)
            Text(label).font(CentmondTheme.Typography.caption).foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
    }

    private func cells(for row: Int) -> [IndexedCell] {
        heatmap.cells
            .filter { $0.row == row }
            .sorted { $0.column < $1.column }
            .map { IndexedCell(id: "\($0.row)-\($0.column)", cell: $0) }
    }

    private func heatCell(_ cell: Heatmap.Cell) -> some View {
        let v = Double(truncating: cell.value as NSDecimalNumber)
        let intensity = maxValue > 0 ? min(1, v / maxValue) : 0
        let base = cell.overBudget ? CentmondTheme.Colors.negative : CentmondTheme.Colors.accent
        let fill = base.opacity(0.10 + 0.65 * intensity)
        return ZStack {
            RoundedRectangle(cornerRadius: 4).fill(fill)
            if v > 0 {
                Text(CurrencyFormat.abbreviated(v))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
            }
        }
        .frame(width: 72, height: 28)
        .help(cellHelp(cell))
    }

    private func cellHelp(_ cell: Heatmap.Cell) -> String {
        let row = cell.row < heatmap.rowLabels.count ? heatmap.rowLabels[cell.row] : ""
        let col = cell.column < heatmap.columnLabels.count ? heatmap.columnLabels[cell.column] : ""
        let actual = CurrencyFormat.compact(cell.value)
        let budget = cell.baseline.map(CurrencyFormat.compact) ?? "no budget"
        return "\(row) · \(col)\nActual \(actual) · Budget \(budget)"
    }

    private struct IndexedCell: Identifiable {
        let id: String
        let cell: Heatmap.Cell
    }
}
