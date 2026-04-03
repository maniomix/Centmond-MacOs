import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentStep = 0

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            icon: "dollarsign.circle.fill",
            title: "Welcome to Centmond",
            subtitle: "Your personal finance command center",
            description: "Track spending, manage budgets, and understand where your money goes — all in one place.",
            accentColor: CentmondTheme.Colors.accent
        ),
        OnboardingStep(
            icon: "building.columns.fill",
            title: "Add Your Accounts",
            subtitle: "Start with what you have",
            description: "Add your checking, savings, and credit card accounts. You can always add more later.",
            accentColor: CentmondTheme.Colors.positive
        ),
        OnboardingStep(
            icon: "chart.pie.fill",
            title: "Categorize & Review",
            subtitle: "Stay on top of your spending",
            description: "Centmond surfaces transactions that need attention. A quick daily review keeps everything clean.",
            accentColor: Color(hex: "8B5CF6")
        ),
        OnboardingStep(
            icon: "command",
            title: "Built for Keyboard",
            subtitle: "Fast navigation at your fingertips",
            description: "Press \u{2318}K for the command palette, \u{2318}N for a new transaction, and \u{2318}1-9 to jump between screens.",
            accentColor: CentmondTheme.Colors.warning
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Step content
            stepContent
                .frame(maxWidth: 520)

            Spacer()

            // Navigation
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CentmondTheme.Colors.bgPrimary)
        .preferredColorScheme(.dark)
        .onKeyPress(.return) {
            advanceOrFinish()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if currentStep < steps.count - 1 {
                withAnimation(CentmondTheme.Motion.default) { currentStep += 1 }
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if currentStep > 0 {
                withAnimation(CentmondTheme.Motion.default) { currentStep -= 1 }
            }
            return .handled
        }
    }

    // MARK: - Step Content

    private var stepContent: some View {
        let step = steps[currentStep]

        return VStack(spacing: CentmondTheme.Spacing.xxl) {
            // Icon
            Image(systemName: step.icon)
                .font(.system(size: 64))
                .foregroundStyle(step.accentColor)
                .frame(height: 80)
                .id(currentStep) // force transition on step change
                .transition(.opacity.combined(with: .scale(scale: 0.9)))

            VStack(spacing: CentmondTheme.Spacing.sm) {
                Text(step.title)
                    .font(CentmondTheme.Typography.heading1)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(step.subtitle)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(step.accentColor)
            }

            Text(step.description)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 400)
        }
        .animation(CentmondTheme.Motion.default, value: currentStep)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Skip
            if currentStep < steps.count - 1 {
                Button("Skip") {
                    completeOnboarding()
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                Spacer().frame(width: 80)
            }

            Spacer()

            // Dots
            HStack(spacing: CentmondTheme.Spacing.sm) {
                ForEach(0..<steps.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentStep ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault)
                        .frame(width: index == currentStep ? 10 : 6, height: index == currentStep ? 10 : 6)
                        .animation(CentmondTheme.Motion.micro, value: currentStep)
                }
            }

            Spacer()

            // Next / Get Started
            Button {
                advanceOrFinish()
            } label: {
                Text(currentStep == steps.count - 1 ? "Get Started" : "Continue")
                    .frame(width: 100)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxxl)
        .padding(.bottom, CentmondTheme.Spacing.xxxl)
    }

    // MARK: - Actions

    private func advanceOrFinish() {
        if currentStep < steps.count - 1 {
            withAnimation(CentmondTheme.Motion.default) { currentStep += 1 }
        } else {
            completeOnboarding()
        }
    }

    private func completeOnboarding() {
        withAnimation(CentmondTheme.Motion.default) {
            hasCompletedOnboarding = true
        }
    }
}

// MARK: - Model

private struct OnboardingStep {
    let icon: String
    let title: String
    let subtitle: String
    let description: String
    let accentColor: Color
}
