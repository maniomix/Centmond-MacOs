import SwiftUI

/// A horizontal progress bar that works reliably inside LazyVGrid/HStack layouts.
/// Uses overlay-based sizing instead of GeometryReader to avoid grid layout issues.
struct ProgressBarView: View {
    let progress: Double
    var color: Color = CentmondTheme.Colors.accent
    var trackColor: Color = CentmondTheme.Colors.bgQuaternary
    var height: CGFloat = 6
    var cornerRadius: CGFloat = 3

    @State private var animatedProgress: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(trackColor)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * animatedProgress), height: height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
