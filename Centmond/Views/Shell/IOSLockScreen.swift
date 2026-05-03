#if os(iOS)
import SwiftUI
import LocalAuthentication

/// Locked-state cover. Shows a single Face ID/Touch ID/passcode unlock
/// button and the LAContext error from the previous attempt (if any).
/// Auto-fires unlock on first appear so the prompt comes up immediately.
struct IOSLockScreen: View {
    @Bindable var controller: IOSAppLockController

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
        .onAppear {
            // Fire the prompt as soon as the screen appears so the user
            // doesn't have to tap a button just to get to Face ID.
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
