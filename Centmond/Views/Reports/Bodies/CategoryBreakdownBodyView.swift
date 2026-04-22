import SwiftUI
import Charts

struct CategoryBreakdownBodyView: View {
    let breakdown: CategoryBreakdown

    @State private var hoveredSliceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
            DonutCardSurface(breakdown: breakdown, hoveredSliceID: $hoveredSliceID)
            categoryTable
        }
    }

    // MARK: - Table

    private var categoryTable: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                Text("Ranked")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                ForEach(breakdown.slices.indices, id: \.self) { idx in
                    let slice = breakdown.slices[idx]
                    sliceRow(slice: slice, rank: idx + 1, highlighted: slice.id == hoveredSliceID)
                    if idx < breakdown.slices.count - 1 {
                        Divider().background(CentmondTheme.Colors.strokeSubtle)
                    }
                }

                if breakdown.uncategorizedAmount > 0 {
                    Divider().background(CentmondTheme.Colors.strokeSubtle)
                    uncategorizedRow
                }
            }
        }
    }

    private func sliceRow(slice: CategoryBreakdown.Slice, rank: Int, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(rank)")
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 20)

                Circle()
                    .fill(sliceColor(slice))
                    .frame(width: 10, height: 10)

                Text(slice.name)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                if let delta = slice.deltaVsBaseline {
                    deltaChip(delta)
                }

                Text("\(slice.transactionCount) tx")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 60, alignment: .trailing)

                Text("\(Int((slice.percentOfTotal * 100).rounded()))%")
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 50, alignment: .trailing)

                Text(CurrencyFormat.compact(slice.amount))
                    .font(CentmondTheme.Typography.mono).monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .frame(width: 110, alignment: .trailing)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(sliceColor(slice).opacity(0.12))
                        .frame(height: 4)
                    Capsule().fill(sliceColor(slice))
                        .frame(width: max(2, geo.size.width * CGFloat(slice.percentOfTotal)), height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
        .background(highlighted ? CentmondTheme.Colors.accentMuted.opacity(0.5) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .animation(CentmondTheme.Motion.micro, value: highlighted)
    }

    private var uncategorizedRow: some View {
        HStack {
            Text("Uncategorized")
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Spacer()
            Text(CurrencyFormat.compact(breakdown.uncategorizedAmount))
                .font(CentmondTheme.Typography.mono).monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.warning)
        }
        .padding(.vertical, 4)
    }

    private func deltaChip(_ delta: Decimal) -> some View {
        let d = Double(truncating: delta as NSDecimalNumber)
        return HStack(spacing: 2) {
            Image(systemName: d >= 0 ? "arrow.up" : "arrow.down")
                .font(.system(size: 9, weight: .semibold))
            Text(CurrencyFormat.compact(Decimal(abs(d))))
                .font(CentmondTheme.Typography.caption)
                .monospacedDigit()
        }
        .foregroundStyle(d >= 0 ? CentmondTheme.Colors.negative : CentmondTheme.Colors.positive)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background((d >= 0 ? CentmondTheme.Colors.negative : CentmondTheme.Colors.positive).opacity(0.1))
        .clipShape(Capsule())
    }

    private func sliceColor(_ slice: CategoryBreakdown.Slice) -> Color {
        let palette = CentmondTheme.Colors.chartPalette
        if let hex = slice.colorHex, !hex.isEmpty { return Color(hex: hex) }
        let idx = breakdown.slices.firstIndex(where: { $0.id == slice.id }) ?? 0
        return palette[idx % palette.count]
    }
}

private struct DonutCardSurface: View {
    let breakdown: CategoryBreakdown
    @Binding var hoveredSliceID: String?

    @State private var angleSelection: Double?

    var body: some View {
        CardContainer {
            HStack(alignment: .top, spacing: CentmondTheme.Spacing.xxl) {
                ZStack {
                    Chart(breakdown.slices) { slice in
                        SectorMark(
                            angle: .value("Amount", NSDecimalNumber(decimal: slice.amount).doubleValue),
                            innerRadius: .ratio(0.62),
                            outerRadius: hoveredSliceID == slice.id ? .ratio(1.02) : .ratio(0.96),
                            angularInset: 1.5
                        )
                        .foregroundStyle(color(for: slice))
                        .cornerRadius(4)
                    }
                    .chartAngleSelection(value: $angleSelection)
                    .onChange(of: angleSelection) { _, newValue in
                        hoveredSliceID = sliceID(for: newValue)
                    }
                    .frame(width: 280, height: 280)

                    centerLabel
                }

                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                    Text("Categories")
                        .font(CentmondTheme.Typography.captionMedium)
                        .tracking(0.5)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)

                    ForEach(Array(breakdown.slices.prefix(8).enumerated()), id: \.element.id) { idx, slice in
                        legendRow(slice: slice, index: idx)
                    }

                    if breakdown.slices.count > 8 {
                        Text("+ \(breakdown.slices.count - 8) more")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var centerLabel: some View {
        VStack(spacing: 2) {
            if let id = hoveredSliceID, let slice = breakdown.slices.first(where: { $0.id == id }) {
                Text(slice.name)
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .lineLimit(1)
                Text(CurrencyFormat.compact(slice.amount))
                    .font(CentmondTheme.Typography.heading2)
                    .monospacedDigit()
                Text("\(Int((slice.percentOfTotal * 100).rounded()))%")
                    .font(CentmondTheme.Typography.caption).monospacedDigit()
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            } else {
                Text("Total")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                Text(CurrencyFormat.compact(breakdown.totalAmount))
                    .font(CentmondTheme.Typography.heading2)
                    .monospacedDigit()
                Text("\(breakdown.slices.count) categories")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
        }
        .animation(CentmondTheme.Motion.micro, value: hoveredSliceID)
    }

    private func legendRow(slice: CategoryBreakdown.Slice, index: Int) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(for: slice)).frame(width: 8, height: 8)
            Text(slice.name)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .lineLimit(1)
            Spacer()
            Text("\(Int((slice.percentOfTotal * 100).rounded()))%")
                .font(CentmondTheme.Typography.caption).monospacedDigit()
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
        }
        .padding(.vertical, 2)
        .onHover { hovering in
            hoveredSliceID = hovering ? slice.id : nil
        }
    }

    private func color(for slice: CategoryBreakdown.Slice) -> Color {
        let palette = CentmondTheme.Colors.chartPalette
        if let hex = slice.colorHex, !hex.isEmpty { return Color(hex: hex) }
        let idx = breakdown.slices.firstIndex(where: { $0.id == slice.id }) ?? 0
        return palette[idx % palette.count]
    }

    private func sliceID(for angle: Double?) -> String? {
        guard let angle else { return nil }
        let total = breakdown.slices.reduce(Decimal.zero) { $0 + $1.amount }
        guard total > 0 else { return nil }
        let totalD = Double(truncating: total as NSDecimalNumber)
        var cumulative: Double = 0
        for slice in breakdown.slices {
            cumulative += Double(truncating: slice.amount as NSDecimalNumber)
            if angle <= cumulative {
                return slice.id
            }
        }
        return breakdown.slices.last?.id
    }
}
