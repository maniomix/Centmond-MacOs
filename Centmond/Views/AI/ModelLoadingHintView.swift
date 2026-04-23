import SwiftUI

/// Rotating hint messages shown during AI model loading.
/// Appears after a short delay, then cycles through tips with a smooth transition.
struct ModelLoadingHintView: View {
    @State private var visible = false
    @State private var hintIndex = 0

    private let initialDelay: TimeInterval = 3.0
    private let rotationInterval: TimeInterval = 4.5

    private static let hints: [String] = [
        "This might take a moment…",
        "First load takes longer — next time will be faster",
        "The AI runs entirely on your Mac",
        "No data leaves your device",
        "Optimized for Apple Silicon",
        "Preparing neural networks…",
        "Almost ready…",
    ]

    var body: some View {
        Group {
            if visible {
                Text(Self.hints[hintIndex])
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(DS.Colors.subtext)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.4), value: hintIndex)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(height: 18)
        .onAppear {
            // Show first hint after initial delay
            DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) {
                withAnimation(.easeIn(duration: 0.3)) {
                    visible = true
                }
                // Start rotating hints
                startRotation()
            }
        }
    }

    private func startRotation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + rotationInterval) {
            guard visible else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                hintIndex = (hintIndex + 1) % Self.hints.count
            }
            startRotation()
        }
    }
}
