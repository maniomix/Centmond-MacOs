import SwiftUI
import SwiftData
import Charts

// ============================================================
// MARK: - Net Worth Trend Chart (P3)
// ============================================================
//
// Interactive line chart of `NetWorthSnapshot` history with a
// range picker (1M / 3M / 6M / 1Y / ALL) and a delta chip vs the
// range start. Hover state lives in a nested `HoverSurface`
// sub-view so 60 Hz `onContinuousHover` updates don't invalidate
// the parent (Hover State Scope memory rule), and the overlay
// applies the three guards: plot-bounds check, change-detection
// on state writes, and clear-on-leave (Chart Hover Three Guards).
// ============================================================

struct NetWorthTrendChart: View {
    let snapshots: [NetWorthSnapshot]

    @State private var range: TrendRange = .threeMonths

    private var filtered: [NetWorthSnapshot] {
        let cutoff = range.cutoff(from: .now)
        let sorted = snapshots.sorted { $0.date < $1.date }
        guard let cutoff else { return sorted }
        return sorted.filter { $0.date >= cutoff }
    }

    private var delta: Decimal {
        guard let first = filtered.first, let last = filtered.last else { return 0 }
        return last.netWorth - first.netWorth
    }

    private var deltaPercent: Double {
        guard let first = filtered.first,
              let last = filtered.last,
              first.netWorth != 0 else { return 0 }
        let d = (last.netWorth - first.netWorth) / abs(first.netWorth)
        return Double(truncating: d as NSDecimalNumber)
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                header
                chart
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TREND")
                    .font(CentmondTheme.Typography.overline)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .tracking(1)
                deltaChip
            }
            Spacer()
            rangePicker
        }
    }

    private var deltaChip: some View {
        let isUp = delta >= 0
        let color: Color = isUp ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative
        let arrow = isUp ? "arrow.up.right" : "arrow.down.right"
        let sign = isUp ? "+" : "−"
        let pct = abs(deltaPercent) * 100
        return HStack(spacing: 6) {
            Image(systemName: arrow)
                .font(CentmondTheme.Typography.captionSmallSemibold)
            Text("\(sign)\(CurrencyFormat.standard(abs(delta)))")
                .font(CentmondTheme.Typography.bodyMedium)
                .monospacedDigit()
            Text(String(format: "(%.1f%%)", pct))
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .monospacedDigit()
            Text("vs \(range.startLabel)")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
        }
        .foregroundStyle(color)
    }

    private var rangePicker: some View {
        HStack(spacing: 4) {
            ForEach(TrendRange.allCases, id: \.self) { r in
                Button {
                    range = r
                } label: {
                    Text(r.label)
                        .font(CentmondTheme.Typography.caption)
                        .fontWeight(range == r ? .semibold : .regular)
                        .foregroundStyle(range == r ? CentmondTheme.Colors.textPrimary : CentmondTheme.Colors.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                                .fill(range == r ? CentmondTheme.Colors.accentMuted : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        if filtered.count < 2 {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(CentmondTheme.Typography.heading1.weight(.regular))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    Text("Not enough history yet")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    Text("Come back tomorrow — a snapshot is taken daily.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
                Spacer()
            }
            .frame(height: 240)
        } else {
            HoverSurface(points: filtered)
                .frame(height: 240)
        }
    }

    // MARK: - Hover Surface (isolated state per memory rule)

    private struct HoverSurface: View {
        let points: [NetWorthSnapshot]

        @State private var hoveredIndex: Int?
        @State private var hoverLocation: CGPoint = .zero

        private var minValue: Double {
            let v = points.map { Double(truncating: $0.netWorth as NSDecimalNumber) }
            return v.min() ?? 0
        }
        private var maxValue: Double {
            let v = points.map { Double(truncating: $0.netWorth as NSDecimalNumber) }
            return v.max() ?? 0
        }
        private var yDomain: ClosedRange<Double> {
            let pad = max((maxValue - minValue) * 0.1, 1)
            return (minValue - pad)...(maxValue + pad)
        }

        var body: some View {
            Chart {
                ForEach(Array(points.enumerated()), id: \.element.id) { _, p in
                    let value = Double(truncating: p.netWorth as NSDecimalNumber)
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Net Worth", value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    AreaMark(
                        x: .value("Date", p.date),
                        y: .value("Net Worth", value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                CentmondTheme.Colors.accent.opacity(0.25),
                                CentmondTheme.Colors.accent.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                if let i = hoveredIndex, i < points.count {
                    let p = points[i]
                    let value = Double(truncating: p.netWorth as NSDecimalNumber)
                    RuleMark(x: .value("Hover", p.date))
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(
                        x: .value("Date", p.date),
                        y: .value("Net Worth", value)
                    )
                    .symbolSize(80)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                }
            }
            .chartYScale(domain: yDomain)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.4))
                    AxisValueLabel {
                        if let d = value.as(Double.self) {
                            Text(CurrencyFormat.compact(Decimal(d)))
                                .font(CentmondTheme.Typography.caption)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(CentmondTheme.Colors.strokeSubtle.opacity(0.3))
                    AxisValueLabel()
                }
            }
            .modifier(TrendHoverModifier(points: points, hoveredIndex: $hoveredIndex, hoverLocation: $hoverLocation))
            .overlay(alignment: .topLeading) {
                if let i = hoveredIndex, i < points.count {
                    tooltip(for: points[i])
                        .offset(x: min(hoverLocation.x + 12, 260), y: max(hoverLocation.y - 44, 0))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }

        private func tooltip(for p: NetWorthSnapshot) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                Text(CurrencyFormat.standard(p.netWorth))
                    .font(CentmondTheme.Typography.monoLarge)
                    .foregroundStyle(p.netWorth >= 0 ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Text("Assets \(CurrencyFormat.compact(p.totalAssets))")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.positive)
                    Text("·").foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    Text("Liab \(CurrencyFormat.compact(p.totalLiabilities))")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                    .fill(CentmondTheme.Colors.bgSecondary)
                    .centmondShadow(2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                    .strokeBorder(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
        }
    }

    // MARK: - Hover modifier (three-guards pattern)

    private struct TrendHoverModifier: ViewModifier {
        let points: [NetWorthSnapshot]
        @Binding var hoveredIndex: Int?
        @Binding var hoverLocation: CGPoint

        func body(content: Content) -> some View {
            content
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    // Guard 1: plot bounds.
                                    guard let plotFrameKey = proxy.plotFrame else {
                                        clear()
                                        return
                                    }
                                    let plot = geometry[plotFrameKey]
                                    let xInPlot = location.x - plot.origin.x
                                    guard xInPlot >= 0, xInPlot <= plot.width else {
                                        clear()
                                        return
                                    }
                                    // Resolve the nearest snapshot by date.
                                    guard let date: Date = proxy.value(atX: xInPlot) else { return }
                                    guard let idx = nearestIndex(to: date) else { return }
                                    // Guard 2: change-detection — only write on index change.
                                    if hoveredIndex != idx {
                                        hoveredIndex = idx
                                    }
                                    hoverLocation = location
                                case .ended:
                                    clear()
                                }
                            }
                    }
                }
        }

        private func clear() {
            // Guard 3: clear-on-leave.
            if hoveredIndex != nil {
                withAnimation(CentmondTheme.Motion.micro) { hoveredIndex = nil }
            }
        }

        private func nearestIndex(to date: Date) -> Int? {
            guard !points.isEmpty else { return nil }
            var best = 0
            var bestDiff = abs(points[0].date.timeIntervalSince(date))
            for (i, p) in points.enumerated() {
                let d = abs(p.date.timeIntervalSince(date))
                if d < bestDiff {
                    bestDiff = d
                    best = i
                }
            }
            return best
        }
    }
}

// MARK: - Range

enum TrendRange: String, CaseIterable {
    case oneMonth, threeMonths, sixMonths, oneYear, all

    var label: String {
        switch self {
        case .oneMonth: return "1M"
        case .threeMonths: return "3M"
        case .sixMonths: return "6M"
        case .oneYear: return "1Y"
        case .all: return "ALL"
        }
    }

    var startLabel: String {
        switch self {
        case .oneMonth: return "1 month ago"
        case .threeMonths: return "3 months ago"
        case .sixMonths: return "6 months ago"
        case .oneYear: return "1 year ago"
        case .all: return "start"
        }
    }

    func cutoff(from date: Date) -> Date? {
        let cal = Calendar.current
        switch self {
        case .oneMonth:    return cal.date(byAdding: .month, value: -1, to: date)
        case .threeMonths: return cal.date(byAdding: .month, value: -3, to: date)
        case .sixMonths:   return cal.date(byAdding: .month, value: -6, to: date)
        case .oneYear:     return cal.date(byAdding: .year, value: -1, to: date)
        case .all:         return nil
        }
    }
}
