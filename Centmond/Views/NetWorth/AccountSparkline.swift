import SwiftUI

// ============================================================
// MARK: - Account Sparkline (P5)
// ============================================================
//
// Tiny inline trend line for the per-account rows in the
// Net Worth breakdown. Path-based (not Swift Charts) so each
// row stays cheap — a 200-account list would otherwise spin up
// 200 Chart instances.
//
// Data: `AccountBalancePoint`s already produced by
// NetWorthHistoryService (P2). Renders nothing if there are
// fewer than two points in the window.
// ============================================================

struct AccountSparkline: View {
    let points: [AccountBalancePoint]
    var color: Color = CentmondTheme.Colors.accent
    var fillOpacity: Double = 0.12

    var body: some View {
        Canvas { ctx, size in
            guard points.count >= 2 else { return }

            let values = points.map { Double(truncating: $0.balance as NSDecimalNumber) }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 0
            let range = max(hi - lo, 1)

            func project(_ i: Int) -> CGPoint {
                let x = size.width * CGFloat(i) / CGFloat(points.count - 1)
                let normalized = (values[i] - lo) / range
                let y = size.height - (size.height - 2) * CGFloat(normalized) - 1
                return CGPoint(x: x, y: y)
            }

            // Fill path
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: size.height))
            for i in 0..<points.count { fill.addLine(to: project(i)) }
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(fillOpacity)))

            // Line path
            var line = Path()
            line.move(to: project(0))
            for i in 1..<points.count { line.addLine(to: project(i)) }
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Change Chip

struct AccountChangeChip: View {
    let delta: Decimal
    let isLiability: Bool

    /// For liabilities, "going up" is bad — invert the color but keep
    /// the directional arrow honest (debt grew → ↑).
    private var isFavorable: Bool {
        isLiability ? delta <= 0 : delta >= 0
    }

    private var color: Color {
        isFavorable ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative
    }

    private var arrow: String {
        delta >= 0 ? "arrow.up.right" : "arrow.down.right"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 8, weight: .semibold))
            Text(CurrencyFormat.compact(abs(delta)))
                .font(CentmondTheme.Typography.caption)
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            Capsule().fill(color.opacity(0.12))
        )
    }
}

// MARK: - Utilization Ring (credit cards)

struct UtilizationRing: View {
    let utilization: Double  // 0..1, may exceed 1 if over limit
    var size: CGFloat = 22

    private var color: Color {
        switch utilization {
        case ..<0.30: return CentmondTheme.Colors.positive
        case ..<0.70: return CentmondTheme.Colors.warning
        default:      return CentmondTheme.Colors.negative
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(utilization, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(min(utilization, 1.0) * 100))")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .help("\(Int(utilization * 100))% utilization")
    }
}
