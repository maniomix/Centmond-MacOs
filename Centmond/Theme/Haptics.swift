#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Lightweight haptic feedback helper. Force Touch trackpads on macOS,
/// Taptic Engine on iOS. All calls are no-ops on hardware without haptic
/// support. Respects the user's "hapticsEnabled" preference (defaults to on).
enum Haptics {

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    /// Subtle tick — chart hover, color swatch, hover enter
    static func tick() {
        guard isEnabled else { return }
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer
            .perform(.alignment, performanceTime: .now)
        #else
        let g = UISelectionFeedbackGenerator()
        g.selectionChanged()
        #endif
    }

    /// Medium bump — toggle, tab switch, type change, selection
    static func tap() {
        guard isEnabled else { return }
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer
            .perform(.levelChange, performanceTime: .now)
        #else
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()
        #endif
    }

    /// Generic feedback — form submit, create, save
    static func impact() {
        guard isEnabled else { return }
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer
            .perform(.generic, performanceTime: .now)
        #else
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.impactOccurred()
        #endif
    }
}
