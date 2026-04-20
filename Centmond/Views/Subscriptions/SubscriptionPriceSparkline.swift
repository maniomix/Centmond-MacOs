import SwiftUI

/// Inline sparkline of a subscription's historical amounts. Reads from
/// `Subscription.priceHistory` + `Subscription.charges` to build a points
/// series. Kept as a tiny plain SwiftUI Path — no Charts framework — so
/// it renders at grid-card scale without Charts' min-height / padding
/// overhead. When there's not enough data (< 2 points) it shows nothing,
/// letting the card collapse the slot cleanly.
struct SubscriptionPriceSparkline: View {
    let amounts: [Double]
    var tint: Color = CentmondTheme.Colors.accent

    var body: some View {
        GeometryReader { geo in
            if amounts.count >= 2 {
                let (minV, maxV) = range
                let path = buildPath(in: geo.size, minV: minV, maxV: maxV)
                ZStack {
                    path.stroke(tint.opacity(0.7), lineWidth: 1.25)
                    if let last = lastPoint(in: geo.size, minV: minV, maxV: maxV) {
                        Circle()
                            .fill(tint)
                            .frame(width: 4, height: 4)
                            .position(last)
                    }
                }
            }
        }
        .frame(height: 18)
    }

    private var range: (Double, Double) {
        let lo = amounts.min() ?? 0
        let hi = amounts.max() ?? 1
        if abs(hi - lo) < 0.001 { return (lo - 1, hi + 1) }
        return (lo, hi)
    }

    private func buildPath(in size: CGSize, minV: Double, maxV: Double) -> Path {
        var path = Path()
        let step = amounts.count > 1 ? size.width / CGFloat(amounts.count - 1) : 0
        let span = maxV - minV
        for (i, amt) in amounts.enumerated() {
            let x = CGFloat(i) * step
            let norm = (amt - minV) / span
            let y = size.height - (CGFloat(norm) * size.height)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    private func lastPoint(in size: CGSize, minV: Double, maxV: Double) -> CGPoint? {
        guard let last = amounts.last else { return nil }
        let span = maxV - minV
        let norm = (last - minV) / span
        return CGPoint(x: size.width, y: size.height - CGFloat(norm) * size.height)
    }
}
