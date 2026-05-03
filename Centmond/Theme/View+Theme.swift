import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    func cardStyle() -> some View {
        self
            .padding(CentmondTheme.Spacing.lg)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
    }

    func screenBackground() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CentmondTheme.Colors.bgPrimary)
    }

    /// Apply one of the canonical elevation shadows from `CentmondTheme.Elevation`.
    /// Level 1 = subtle lift, 2 = default card, 3 = floating panel, 4 = modal/scrim.
    /// Use this instead of hand-rolled `.shadow(color: .black.opacity(x), ...)` calls
    /// so the app maintains a consistent depth hierarchy.
    func centmondShadow(_ level: Int) -> some View {
        let s = CentmondTheme.Elevation.shadow(level: level)
        return self.shadow(color: s.color, radius: s.radius, y: s.y)
    }

    /// Wire the macOS system Esc key to the view's `@Environment(\.dismiss)`.
    ///
    /// Installs an invisible `.keyboardShortcut(.cancelAction)` button behind
    /// the view. `.cancelAction` on macOS binds Esc system-wide and marks the
    /// button as the cancel action for screen-reader semantics. Safe to apply
    /// to any dismissable sheet root — if `dismiss` is unbound (no presenting
    /// context), the button is a no-op.
    ///
    /// Phase 3 polish (2026-04-23): before this modifier, only 2 of the 26
    /// sheets honored Esc. Adding it to `SheetRouter` covers all 20 routed
    /// sheets at once. Stand-alone sheets apply it to their root directly.
    func dismissOnEscape() -> some View {
        modifier(DismissOnEscapeModifier())
    }
}

private struct DismissOnEscapeModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content.background(
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

// MARK: - Accessibility helpers (Phase 9 polish, 2026-04-24)

extension CentmondTheme {

    /// Read the user's Reduce Motion system preference. Non-views can't
    /// read `@Environment(\.accessibilityReduceMotion)`, so views should
    /// prefer that. This fallback is for callers outside the SwiftUI env.
    static var prefersReducedMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// Read Reduce Transparency system preference from outside a view.
    static var prefersReducedTransparency: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        #else
        UIAccessibility.isReduceTransparencyEnabled
        #endif
    }
}

extension View {
    /// Apply an animation only when the user has NOT requested Reduce
    /// Motion. Essential for decorative transitions (shimmer, ambient
    /// gradients, card-expand springs). Keeps layout-critical motion
    /// intact while silencing motion that exists purely for flair.
    ///
    /// Use on any `.animation(_:value:)` site that users with vestibular
    /// sensitivity would find distracting.
    func motionRespectingAnimation<V: Equatable>(
        _ animation: Animation?,
        value: V
    ) -> some View {
        modifier(MotionRespectingAnimationModifier(animation: animation, value: value))
    }

    /// Opt a `.background(.ultraThinMaterial, ...)` surface into a solid
    /// fallback when the user has Reduce Transparency enabled. Pass the
    /// solid color the surface should degrade to; defaults to
    /// `CentmondTheme.Colors.bgSecondary` which matches existing elevated
    /// panel backgrounds.
    func glassBackground<S: Shape>(
        in shape: S,
        fallback solid: Color = CentmondTheme.Colors.bgSecondary
    ) -> some View {
        modifier(GlassBackgroundModifier(shape: AnyShape(shape), solid: solid))
    }
}

private struct MotionRespectingAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct GlassBackgroundModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: AnyShape
    let solid: Color

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(solid, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}
