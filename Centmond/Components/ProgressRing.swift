import SwiftUI

struct ProgressRing: View {
    let progress: Double
    var size: CGFloat = 48
    var lineWidth: CGFloat = 4
    var trackColor: Color = CentmondTheme.Colors.strokeSubtle
    var fillColor: Color = CentmondTheme.Colors.accent
    var showPercentage: Bool = true

    @State private var animatedProgress: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(fillColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            if showPercentage {
                Text("\(Int(progress * 100))%")
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(CentmondTheme.Motion.chart) {
                animatedProgress = min(progress, 1.0)
            }
        }
        .onChange(of: progress) { _, newValue in
            withAnimation(CentmondTheme.Motion.default) {
                animatedProgress = min(newValue, 1.0)
            }
        }
    }
}
