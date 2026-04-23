import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Phase 2 — global shortcut that summons the Quick Add floating
    /// panel. Default ⌃⌘A; user-rebindable later via Settings.
    ///
    /// Name suffixed with `.v3` so changing the default actually takes
    /// effect — KeyboardShortcuts persists user values under the Name
    /// key, so a fresh key is the cleanest way to retire previous
    /// defaults (⌥⌘Space, then ⌥⌘A) that may have been registered in
    /// earlier dev builds.
    static let quickAddTransaction = Self(
        "quickAddTransaction.v3",
        default: .init(.a, modifiers: [.command, .control])
    )
}

/// Phase 2 — registers the global ⌥⌘Space listener and posts the
/// shared `.quickAddRequested` notification that Phase 3's panel
/// coordinator will consume.
@MainActor
final class QuickAddHotkeyService {
    static let shared = QuickAddHotkeyService()

    private init() {}

    func start() {
        // Use the keyDown-only callback API. `events(for:)` emits both
        // keyDown and keyUp, so a normal tap fired twice (open → close)
        // and only holding the keys felt like it worked.
        KeyboardShortcuts.onKeyDown(for: .quickAddTransaction) {
            NotificationCenter.default.post(name: .quickAddRequested, object: nil)
        }
    }
}
