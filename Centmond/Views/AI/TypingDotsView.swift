import Combine
import SwiftUI

/// Animated thinking indicator with phase labels and shimmer skeleton.
struct TypingDotsView: View {
    var streamingPhase: StreamingPhase = .thinking

    @State private var dotPhase: Int = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Phase label with icon
            HStack(spacing: 8) {
                Image(systemName: streamingPhase.icon)
                    .font(CentmondTheme.Typography.bodyLarge.weight(.medium))
                    .foregroundStyle(DS.Colors.accent)
                    .symbolEffect(.pulse.wholeSymbol, options: .repeating.speed(0.6))

                Text(streamingPhase.label)
                    .font(CentmondTheme.Typography.bodyMedium.weight(.semibold))
                    .foregroundStyle(DS.Colors.subtext)

                // Bouncing dots inline
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(DS.Colors.accent.opacity(0.6))
                            .frame(width: 5, height: 5)
                            .scaleEffect(dotPhase == index ? 1.3 : 0.6)
                            .opacity(dotPhase == index ? 1.0 : 0.3)
                            .offset(y: dotPhase == index ? -3 : 0)
                            .animation(
                                .spring(response: 0.3, dampingFraction: 0.45),
                                value: dotPhase
                            )
                    }
                }
            }
            .onReceive(timer) { _ in
                dotPhase = (dotPhase + 1) % 3
            }

            // Shimmer skeleton lines — 12 fps; was 60 fps which alone burned
            // measurable CPU while the model was generating.
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let offset = CGFloat((time.truncatingRemainder(dividingBy: 1.8)) / 1.8)

                VStack(alignment: .leading, spacing: 8) {
                    shimmerLine(width: 240, offset: offset)
                    shimmerLine(width: 190, offset: offset)
                    shimmerLine(width: 140, offset: offset)
                }
            }
        }
    }

    private func shimmerLine(width: CGFloat, offset: CGFloat) -> some View {
        let shimmerX = -width + (width * 2.5 * offset)

        return RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
            .fill(DS.Colors.subtext.opacity(0.08))
            .frame(width: width, height: 10)
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                DS.Colors.subtext.opacity(0.18),
                                DS.Colors.accent.opacity(0.10),
                                DS.Colors.subtext.opacity(0.18),
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 0.5)
                    .offset(x: shimmerX)
            )
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
    }
}

// MARK: - Streaming Phase

enum StreamingPhase: String, CaseIterable {
    case thinking
    case analyzing
    case composing
    case buildingInsights
    case buildingActions
    case reviewing

    var label: String {
        switch self {
        case .thinking:         return "Thinking"
        case .analyzing:        return "Analyzing data"
        case .composing:        return "Writing response"
        case .buildingInsights: return "Building insights"
        case .buildingActions:  return "Preparing actions"
        case .reviewing:        return "Reviewing"
        }
    }

    var icon: String {
        switch self {
        case .thinking:         return "brain.head.profile"
        case .analyzing:        return "chart.bar.xaxis"
        case .composing:        return "text.cursor"
        case .buildingInsights: return "chart.bar.fill"
        case .buildingActions:  return "hammer.fill"
        case .reviewing:        return "checkmark.shield.fill"
        }
    }
}
