import SwiftUI

/// State for the 6-step first-run onboarding. Created fresh each time
/// the overlay mounts. Holds only transient drafts — persistent
/// completion state lives on AppRouter / UserDefaults.
@Observable
final class OnboardingStore {
    var currentStep: Int = 0

    /// Set to true when step 2 has produced transactions (CSV import,
    /// manual add, or sample data seed). Step 5 uses this to decide
    /// whether there's anything to scan.
    var hasImported: Bool = false

    /// Step 6 toggles into the keyboard-cheatsheet view via its
    /// secondary action; primary CTA label mirrors the change.
    var step6ShowingShortcuts: Bool = false

    static let stepCount = 6
    var isFirstStep: Bool { currentStep == 0 }
    var isLastStep: Bool { currentStep == Self.stepCount - 1 }

    func advance() {
        guard currentStep < Self.stepCount - 1 else { return }
        currentStep += 1
    }
    func back() {
        guard currentStep > 0 else { return }
        currentStep -= 1
    }
}
