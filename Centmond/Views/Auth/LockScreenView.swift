import SwiftUI
import LocalAuthentication

struct LockScreenView: View {
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appPasscode") private var storedPasscode = ""

    @State private var enteredPasscode = ""
    @State private var isUnlocked = false
    @State private var showError = false
    @State private var biometricAvailable = false
    @State private var attempts = 0

    var onUnlock: () -> Void

    private let passcodeLength = 4

    var body: some View {
        if isUnlocked {
            Color.clear.onAppear { onUnlock() }
        } else {
            lockContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CentmondTheme.Colors.bgPrimary)
                .preferredColorScheme(.dark)
                .onAppear { checkBiometrics() }
        }
    }

    private var lockContent: some View {
        VStack(spacing: CentmondTheme.Spacing.xxl) {
            Spacer()

            // App icon
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(CentmondTheme.Colors.accent)

            Text("Centmond")
                .font(CentmondTheme.Typography.heading1)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            Text("Enter your passcode to unlock")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)

            // Passcode dots
            HStack(spacing: CentmondTheme.Spacing.lg) {
                ForEach(0..<passcodeLength, id: \.self) { index in
                    Circle()
                        .fill(index < enteredPasscode.count ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault)
                        .frame(width: 14, height: 14)
                        .animation(CentmondTheme.Motion.micro, value: enteredPasscode.count)
                }
            }
            .modifier(ShakeEffect(shakes: showError ? 2 : 0))
            .animation(CentmondTheme.Motion.default, value: showError)

            // Hidden text field to capture keyboard input
            SecureField("", text: $enteredPasscode)
                .textFieldStyle(.plain)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .focused($isPasscodeFieldFocused)
                .onChange(of: enteredPasscode) { _, newValue in
                    // Only allow digits
                    let filtered = String(newValue.filter(\.isNumber).prefix(passcodeLength))
                    if filtered != newValue {
                        enteredPasscode = filtered
                    }
                    if filtered.count == passcodeLength {
                        validatePasscode()
                    }
                    showError = false
                }

            if showError {
                Text("Incorrect passcode")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.negative)
            }

            // Biometric button
            if biometricAvailable {
                Button {
                    authenticateWithBiometrics()
                } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, CentmondTheme.Spacing.sm)
            }

            Spacer()

            Text("Click anywhere and type your 4-digit passcode")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .padding(.bottom, CentmondTheme.Spacing.xxl)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isPasscodeFieldFocused = true
        }
        .onAppear {
            isPasscodeFieldFocused = true
            if biometricAvailable {
                authenticateWithBiometrics()
            }
        }
    }

    @FocusState private var isPasscodeFieldFocused: Bool

    private func validatePasscode() {
        if enteredPasscode == storedPasscode {
            withAnimation(CentmondTheme.Motion.default) {
                isUnlocked = true
            }
            onUnlock()
        } else {
            attempts += 1
            showError = true
            enteredPasscode = ""
        }
    }

    private func checkBiometrics() {
        let context = LAContext()
        var error: NSError?
        biometricAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private func authenticateWithBiometrics() {
        let context = LAContext()
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock Centmond"
        ) { success, _ in
            DispatchQueue.main.async {
                if success {
                    withAnimation(CentmondTheme.Motion.default) {
                        isUnlocked = true
                    }
                    onUnlock()
                }
            }
        }
    }
}

// MARK: - Shake Effect

struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: 8 * sin(shakes * .pi * 2), y: 0)
        )
    }
}
