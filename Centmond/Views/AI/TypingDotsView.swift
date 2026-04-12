import SwiftUI
import Combine

/// Lightweight three-dot typing animation.
struct TypingDotsView: View {
    @State private var phase: Int = 0

    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            dot(index: 0)
            dot(index: 1)
            dot(index: 2)
        }
        .frame(width: 22)
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                phase = (phase + 1) % 3
            }
        }
    }

    private func dot(index: Int) -> some View {
        Circle()
            .fill(DS.Colors.accent)
            .frame(width: 5, height: 5)
            .scaleEffect(phase == index ? 1.3 : 0.7)
            .opacity(phase == index ? 1.0 : 0.35)
    }
}
