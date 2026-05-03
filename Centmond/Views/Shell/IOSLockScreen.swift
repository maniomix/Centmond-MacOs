#if os(iOS)
import SwiftUI
import LocalAuthentication

/// Locked-state cover. Shows a single Face ID/Touch ID/passcode unlock
/// button and the LAContext error from the previous attempt (if any).
/// Auto-fires unlock as soon as the scene is `.active` — NOT on
/// onAppear, because onAppear can fire before the app's window/scene
/// is fully presented at cold launch, in which case iOS suppresses the
/// biometric UI silently and the screen looks frozen.
struct IOSLockScreen: View {
    @Bindable var controller: IOSAppLockController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color.accentColor.opacity(0.18), Color.black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()
                Image(systemName: biometricIcon)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: controller.isAuthenticating)
                Text("Centmond is locked")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Authenticate to continue")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()

                if let err = controller.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    controller.unlock()
                } label: {
                    HStack(spacing: 8) {
                        if controller.isAuthenticating {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: biometricIcon)
                        }
                        Text(controller.isAuthenticating ? "Authenticating…" : "Unlock")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
                }
                .disabled(controller.isAuthenticating)
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        .task(id: scenePhase) {
            // Auto-fire the unlock prompt when:
            //   • the view first appears AND scene is .active (cold launch
            //     after auth has resolved + lock screen mounts), or
            //   • the scene transitions to .active (return from background
            //     after the grace-period lock fired).
            // The 100 ms sleep gives SwiftUI a chance to commit the view
            // to the window before LAContext.evaluatePolicy runs — without
            // it, iOS occasionally suppresses the system biometric UI on
            // cold launch because the scene isn't fully presented yet,
            // and the lock screen sits idle waiting for a tap.
            guard scenePhase == .active else { return }
            guard !controller.isUnlocked, !controller.isAuthenticating else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            controller.unlock()
        }
    }

    private var biometricIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default:       return "lock.fill"
        }
    }
}
#endif
