import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Launch animation: dark cosmic backdrop, orbital glow rings, and
/// letter-by-letter reveal of the "CENTMOND" wordmark with a
/// shimmering gradient sweep. Calls `onFinished` after the sequence
/// completes so `RootView` can swap to the real shell.
struct SplashView: View {
    var onFinished: () -> Void

    private let word: [Character] = Array("CENTMOND")

    @State private var letterProgress: Int = -1
    @State private var showTagline: Bool = false
    @State private var ringsIn: Bool = false
    @State private var shimmerX: CGFloat = -1.2
    @State private var pulse: CGFloat = 0.6
    @State private var fadeOut: Bool = false

    var body: some View {
        ZStack {
            backdrop
            orbitalRings
            VStack(spacing: 28) {
                logo
                wordmark
            }
            tagline
        }
        .opacity(fadeOut ? 0 : 1)
        .onAppear(perform: run)
    }

    // MARK: - Logo

    private var logoImage: Image {
        guard let url = Bundle.main.url(forResource: "Logo@1440p", withExtension: "png") else {
            return Image(systemName: "sparkles")
        }
        #if os(macOS)
        if let ns = NSImage(contentsOf: url) {
            return Image(nsImage: ns)
        }
        #else
        if let data = try? Data(contentsOf: url),
           let ui = UIImage(data: data) {
            return Image(uiImage: ui)
        }
        #endif
        return Image(systemName: "sparkles")
    }

    private var logo: some View {
        logoImage
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 132, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.55), radius: 28)
            .opacity(ringsIn ? 1 : 0)
            .scaleEffect(ringsIn ? 1 : 0.8)
            .blur(radius: ringsIn ? 0 : 12)
            .animation(.spring(response: 0.7, dampingFraction: 0.7), value: ringsIn)
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            // Pure black base
            Color.black
                .ignoresSafeArea()

            // Faint blue shadow behind the wordmark
            RadialGradient(
                colors: [
                    Color(red: 0.20, green: 0.40, blue: 0.95).opacity(0.22),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 340
            )
            .scaleEffect(pulse)
            .blur(radius: 30)
            .opacity(ringsIn ? 1 : 0)
            .ignoresSafeArea()
        }
    }

    // MARK: - Orbital rings

    private var orbitalRings: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let size: CGFloat = 260 + CGFloat(i) * 110
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                Color.white.opacity(0.0),
                                Color(red: 0.45, green: 0.65, blue: 1.0).opacity(0.55),
                                Color.white.opacity(0.0),
                                Color(red: 0.70, green: 0.45, blue: 1.0).opacity(0.45),
                                Color.white.opacity(0.0)
                            ],
                            center: .center
                        ),
                        lineWidth: 1
                    )
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(ringsIn ? Double(i).truncatingRemainder(dividingBy: 2) == 0 ? 180 : -180 : 0))
                    .opacity(ringsIn ? 1 : 0)
                    .scaleEffect(ringsIn ? 1 : 0.8)
                    .blur(radius: CGFloat(i) * 0.4)
                    .animation(
                        .easeInOut(duration: 2.2 + Double(i) * 0.4),
                        value: ringsIn
                    )
            }
        }
    }

    // MARK: - Wordmark

    private var wordmark: some View {
        HStack(spacing: 2) {
            ForEach(Array(word.enumerated()), id: \.offset) { index, ch in
                let shown = index <= letterProgress
                Text(String(ch))
                    .font(.system(size: 68, weight: .heavy, design: .rounded))
                    .kerning(8)
                    .foregroundStyle(letterFill)
                    .shadow(color: Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.55), radius: shown ? 18 : 0)
                    .opacity(shown ? 1 : 0)
                    .blur(radius: shown ? 0 : 14)
                    .scaleEffect(shown ? 1 : 0.6)
                    .offset(y: shown ? 0 : 14)
                    .animation(
                        .spring(response: 0.55, dampingFraction: 0.62).delay(Double(index) * 0.05),
                        value: letterProgress
                    )
            }
        }
        .overlay(shimmerOverlay.mask(wordmarkMask))
    }

    private var letterFill: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white,
                Color(red: 0.82, green: 0.88, blue: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var wordmarkMask: some View {
        HStack(spacing: 2) {
            ForEach(Array(word.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 68, weight: .heavy, design: .rounded))
                    .kerning(8)
            }
        }
    }

    private var shimmerOverlay: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Color.white.opacity(0.0), location: 0.35),
                    .init(color: Color.white.opacity(0.95), location: 0.5),
                    .init(color: Color.white.opacity(0.0), location: 0.65),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: w * 1.6)
            .offset(x: shimmerX * w)
            .blendMode(.screen)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Tagline

    private var tagline: some View {
        VStack {
            Spacer()
            Text("Your money, beautifully clear.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .tracking(4)
                .foregroundStyle(Color.white.opacity(0.55))
                .opacity(showTagline ? 1 : 0)
                .offset(y: showTagline ? 0 : 8)
                .padding(.bottom, 64)
        }
    }

    // MARK: - Sequencing

    private func run() {
        // Reduce Motion accessibility: skip the 3-second orbital-ring +
        // letter-reveal + shimmer choreography. Users with vestibular
        // sensitivity still see the brand, just not the motion. Snap to
        // final state, hold briefly, then hand off. (Phase 9 polish,
        // 2026-04-24)
        if CentmondTheme.prefersReducedMotion {
            ringsIn = true
            pulse = 1.0
            letterProgress = word.count - 1
            shimmerX = 1.2
            showTagline = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                fadeOut = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    onFinished()
                }
            }
            return
        }

        withAnimation(.easeOut(duration: 1.4)) {
            ringsIn = true
            pulse = 1.0
        }

        // Reveal letters one by one.
        for i in 0..<word.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(i) * 0.09) {
                letterProgress = i
            }
        }

        // Shimmer sweep after the word is assembled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            withAnimation(.easeInOut(duration: 1.2)) {
                shimmerX = 1.2
            }
        }

        // Tagline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.6)) {
                showTagline = true
            }
        }

        // Fade out & hand off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.55) {
            withAnimation(.easeInOut(duration: 0.5)) {
                fadeOut = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) {
            onFinished()
        }
    }
}

#Preview {
    SplashView {}
        .frame(width: 1280, height: 800)
}
