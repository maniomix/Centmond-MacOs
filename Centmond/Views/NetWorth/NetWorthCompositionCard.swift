import SwiftUI
import Charts

// ============================================================
// MARK: - Net Worth Composition (P4)
// ============================================================
//
// Side-by-side donuts: assets-by-type and liabilities-by-type.
// Each donut owns its `chartAngleSelection` state inside its own
// nested struct (Dashboard Donut Hover memory rule) so 60 Hz
// hover updates don't invalidate the parent NetWorthView and
// re-render the trend chart / breakdown columns.
// ============================================================

struct NetWorthCompositionCard: View {
    let assetSlices: [TypeSlice]
    let liabilitySlices: [TypeSlice]
    let totalAssets: Decimal
    let totalLiabilities: Decimal

    var body: some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.xxl) {
            DonutCard(
                title: "Asset Mix",
                slices: assetSlices,
                total: totalAssets,
                accent: CentmondTheme.Colors.positive,
                emptyMessage: "No asset accounts yet"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            DonutCard(
                title: "Liability Mix",
                slices: liabilitySlices,
                total: totalLiabilities,
                accent: CentmondTheme.Colors.negative,
                emptyMessage: "No liabilities — nothing to show."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Slice model

    struct TypeSlice: Identifiable, Hashable {
        let id: String       // raw type
        let label: String
        let amount: Decimal
        let color: Color
    }

    // MARK: - Donut card (state-isolated sub-view)

    private struct DonutCard: View {
        let title: String
        let slices: [TypeSlice]
        let total: Decimal
        let accent: Color
        let emptyMessage: String

        @State private var hoveredAngle: Double?

        private var selected: TypeSlice? {
            guard let angle = hoveredAngle, !slices.isEmpty else { return nil }
            var cumulative: Double = 0
            for slice in slices {
                cumulative += Double(truncating: slice.amount as NSDecimalNumber)
                if angle <= cumulative { return slice }
            }
            return slices.last
        }

        var body: some View {
            CardContainer {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    HStack {
                        Text(title)
                            .font(CentmondTheme.Typography.heading3)
                            .foregroundStyle(accent)
                        Spacer()
                        Text(CurrencyFormat.standard(total))
                            .font(CentmondTheme.Typography.monoLarge)
                            .foregroundStyle(accent)
                            .monospacedDigit()
                    }

                    if slices.isEmpty {
                        emptyState
                    } else {
                        donutBody
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }

        private var emptyState: some View {
            VStack(spacing: 8) {
                Image(systemName: "chart.pie")
                    .font(.system(size: 22))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                Text(emptyMessage)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        }

        private var donutBody: some View {
            VStack(spacing: CentmondTheme.Spacing.md) {
                ZStack {
                    donut
                        .frame(width: 140, height: 140)
                    centerLabel
                }
                .frame(maxWidth: .infinity)

                legend
            }
        }

        private var donut: some View {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value(slice.label, slice.amount),
                    innerRadius: .ratio(0.78),
                    angularInset: 1.2
                )
                .foregroundStyle(slice.color)
                .cornerRadius(3)
                .opacity(selected == nil || selected?.id == slice.id ? 1.0 : 0.28)
            }
            .chartLegend(.hidden)
            .chartAngleSelection(value: $hoveredAngle)
            .onChange(of: selected) { _, _ in Haptics.tick() }
            .animation(CentmondTheme.Motion.default, value: selected)
        }

        @ViewBuilder
        private var centerLabel: some View {
            if let s = selected {
                let pct = total > 0
                    ? Double(truncating: (s.amount / total) as NSDecimalNumber) * 100
                    : 0
                VStack(spacing: 2) {
                    Text(s.label)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    Text(CurrencyFormat.compact(s.amount))
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                    Text(String(format: "%.0f%%", pct))
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .monospacedDigit()
                }
            } else {
                VStack(spacing: 2) {
                    Text("\(slices.count) types")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Text(CurrencyFormat.compact(total))
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()
                }
            }
        }

        private var legend: some View {
            VStack(spacing: 0) {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(slice.color)
                            .frame(width: 10, height: 10)

                        Text(slice.label)
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(
                                selected?.id == slice.id
                                    ? CentmondTheme.Colors.textPrimary
                                    : CentmondTheme.Colors.textSecondary
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(CurrencyFormat.compact(slice.amount))
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, CentmondTheme.Spacing.xs)

                    if index < slices.count - 1 {
                        Divider().background(CentmondTheme.Colors.strokeSubtle)
                    }
                }
            }
        }
    }
}

// MARK: - Slice helpers

extension NetWorthCompositionCard {
    /// Aggregates accounts by `AccountType`, summing `currentBalance`
    /// (assets) or `abs(currentBalance)` (liabilities). Returns the
    /// non-zero slices only, largest-first.
    static func slices(from accounts: [Account], liabilities: Bool) -> [TypeSlice] {
        var totals: [AccountType: Decimal] = [:]
        for account in accounts {
            let value = liabilities ? abs(account.currentBalance) : account.currentBalance
            guard value > 0 else { continue }
            totals[account.type, default: 0] += value
        }
        return totals
            .filter { $0.value > 0 }
            .map { type, amount in
                TypeSlice(
                    id: type.rawValue,
                    label: type.displayName,
                    amount: amount,
                    color: typeColor(type)
                )
            }
            .sorted { $0.amount > $1.amount }
    }

    private static func typeColor(_ type: AccountType) -> Color {
        switch type {
        case .checking:   return Color(hex: "3B82F6")  // blue
        case .savings:    return Color(hex: "22C55E")  // green
        case .investment: return Color(hex: "8B5CF6")  // purple
        case .cash:       return Color(hex: "F59E0B")  // amber
        case .creditCard: return Color(hex: "EF4444")  // red
        case .other:      return Color(hex: "64748B")  // slate
        }
    }
}
