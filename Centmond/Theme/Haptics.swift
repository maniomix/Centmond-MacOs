import AppKit

/// Lightweight haptic feedback helper for Force Touch trackpads.
/// All calls are no-ops on hardware without haptic support.
/// Respects the user's "hapticsEnabled" preference (defaults to on).
enum Haptics {

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    /// Subtle tick — chart hover, color swatch, hover enter
    static func tick() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer
            .perform(.alignment, performanceTime: .now)
    }

    /// Medium bump — toggle, tab switch, type change, selection
    static func tap() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer
            .perform(.levelChange, performanceTime: .now)
    }

    /// Generic feedback — form submit, create, save
    static func impact() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer
            .perform(.generic, performanceTime: .now)
    }
}
