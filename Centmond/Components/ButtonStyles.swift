import SwiftUI

// MARK: - Plain Hover (universal — works on any button regardless of its own background)

struct PlainHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlainHoverBody(configuration: configuration)
    }

    private struct PlainHoverBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .brightness(isHovered && !configuration.isPressed ? 0.06 : 0)
                .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                .opacity(configuration.isPressed ? 0.85 : 1.0)
                .animation(CentmondTheme.Motion.micro, value: isHovered)
                .animation(CentmondTheme.Motion.micro, value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

extension ButtonStyle where Self == PlainHoverButtonStyle {
    static var plainHover: PlainHoverButtonStyle { PlainHoverButtonStyle() }
}

// MARK: - Primary

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    CentmondTheme.Colors.accent.opacity(1.0),
                                    CentmondTheme.Colors.accent.opacity(0.85)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .fill(.white.opacity(isHovered ? 0.12 : 0))
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.25),
                                            .white.opacity(0.06)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        }
                }
                .shadow(
                    color: CentmondTheme.Colors.accent.opacity(isHovered ? 0.35 : 0.2),
                    radius: isHovered ? 8 : 3,
                    y: isHovered ? 2 : 1
                )
                .shadow(
                    color: .black.opacity(0.2),
                    radius: 1,
                    y: 1
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .opacity(configuration.isPressed ? 0.88 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Secondary

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }

    private struct SecondaryButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    isHovered
                    ? CentmondTheme.Colors.textPrimary
                    : CentmondTheme.Colors.textSecondary
                )
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isHovered ? 0.09 : 0.06),
                                    Color.white.opacity(isHovered ? 0.05 : 0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(isHovered ? 0.18 : 0.10),
                                            Color.white.opacity(isHovered ? 0.08 : 0.04)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        }
                }
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .opacity(configuration.isPressed ? 0.8 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Ghost

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration)
    }

    private struct GhostButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    isHovered
                    ? CentmondTheme.Colors.textPrimary
                    : CentmondTheme.Colors.textSecondary
                )
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(
                            configuration.isPressed ? 0.08 : isHovered ? 0.05 : 0
                        ))
                }
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Accent Chip (small toolbar "Add" buttons)

struct AccentChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentChipBody(configuration: configuration)
    }

    private struct AccentChipBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    isHovered
                    ? CentmondTheme.Colors.accentHover
                    : CentmondTheme.Colors.accent
                )
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            CentmondTheme.Colors.accent.opacity(isHovered ? 0.18 : 0.1)
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    CentmondTheme.Colors.accent.opacity(isHovered ? 0.3 : 0.15),
                                    lineWidth: 0.5
                                )
                        }
                }
                .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                .opacity(configuration.isPressed ? 0.85 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Muted Chip (small date preset / filter buttons)

struct MutedChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MutedChipBody(configuration: configuration)
    }

    private struct MutedChipBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    isHovered
                    ? CentmondTheme.Colors.textPrimary
                    : CentmondTheme.Colors.textSecondary
                )
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.08 : 0.04))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    Color.white.opacity(isHovered ? 0.12 : 0.06),
                                    lineWidth: 0.5
                                )
                        }
                }
                .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                .opacity(configuration.isPressed ? 0.8 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Destructive

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DestructiveButtonBody(configuration: configuration)
    }

    private struct DestructiveButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    CentmondTheme.Colors.negative.opacity(1.0),
                                    CentmondTheme.Colors.negative.opacity(0.85)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .fill(.white.opacity(isHovered ? 0.12 : 0))
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.25),
                                            .white.opacity(0.06)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        }
                }
                .shadow(
                    color: CentmondTheme.Colors.negative.opacity(isHovered ? 0.35 : 0.2),
                    radius: isHovered ? 8 : 3,
                    y: isHovered ? 2 : 1
                )
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .opacity(configuration.isPressed ? 0.88 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}
