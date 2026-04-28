import SwiftUI

// MARK: - ThemeMode

/// Three explicit appearance modes. No "system follow" today — Centmond's
/// dark/black palettes diverge enough from a stock dark appearance that an
/// implicit follow would feel arbitrary. The picker lives in Workspace
/// settings; the AppStorage key is read by `Theme.current` and by any view
/// that gates `.preferredColorScheme(_:)`.
enum ThemeMode: String, CaseIterable, Identifiable {
    case light
    case dark
    case black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark:  return "Dark"
        case .black: return "Black"
        }
    }

    var subtitle: String {
        switch self {
        case .light: return "Soft, warm canvas with crisp surfaces."
        case .dark:  return "The signature off-black workspace."
        case .black: return "Pure #000 — friendly to OLED panels."
        }
    }

    var systemImage: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark:  return "moon.fill"
        case .black: return "circle.fill"
        }
    }

    /// What `.preferredColorScheme(_:)` should pin a window to so system
    /// chrome (NSToolbar buttons, sheet vibrancy, vibrant scrollbars) lines
    /// up with the palette we draw on top of it.
    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }
}

/// AppStorage key that drives the live theme. Centralized so tests, the
/// Theme accessor below, and the settings picker all reference the same
/// string.
enum ThemeStorage {
    static let key = "appearance.themeMode"
    static var current: ThemeMode {
        let raw = UserDefaults.standard.string(forKey: key) ?? ThemeMode.dark.rawValue
        return ThemeMode(rawValue: raw) ?? .dark
    }
}

// MARK: - ThemePalette

/// Concrete color values for one mode. `CentmondTheme.Colors` resolves each
/// of its tokens through `Theme.palette`, which returns the palette that
/// matches the current `ThemeMode`. Adding a new color: add it here, add
/// values for all three modes in the static palettes below, then expose a
/// computed forward in `CentmondTheme.Colors`.
struct ThemePalette {
    // Background hierarchy (ambient → most-elevated)
    let bgPrimary: Color
    let bgSecondary: Color
    let bgTertiary: Color
    let bgQuaternary: Color
    let bgInput: Color

    // Text hierarchy
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textQuaternary: Color

    // Accent (brand blue)
    let accent: Color
    let accentHover: Color
    let accentMuted: Color
    let accentSubtle: Color

    // Semantic
    let positive: Color
    let positiveMuted: Color
    let negative: Color
    let negativeMuted: Color
    let warning: Color
    let warningMuted: Color
    let info: Color
    let projected: Color
    let projectedMuted: Color

    // Strokes
    let strokeSubtle: Color
    let strokeDefault: Color
    let strokeStrong: Color

    // Charts
    let chartPalette: [Color]

    // Shadow tuning — light mode wants a soft cool-gray cast; dark/black
    // want black. Stored as opacity multiplier per elevation level so the
    // legacy `Elevation.shadow(level:)` API still returns one color/r/y.
    let shadowColor: Color
    let shadowOpacities: [Double] // 4 entries, indexed 1...4
}

// MARK: - Concrete palettes

extension ThemePalette {

    static let dark: ThemePalette = .init(
        bgPrimary:      Color(hex: "09090B"),
        bgSecondary:    Color(hex: "111114"),
        bgTertiary:     Color(hex: "18181B"),
        bgQuaternary:   Color(hex: "1C1C1F"),
        bgInput:        Color(hex: "0D0D0F"),

        textPrimary:    Color(hex: "F5F5F7"),
        textSecondary:  Color(hex: "A1A1AA"),
        textTertiary:   Color(hex: "71717A"),
        textQuaternary: Color(hex: "52525B"),

        accent:         Color(hex: "3B82F6"),
        accentHover:    Color(hex: "60A5FA"),
        accentMuted:    Color(hex: "1E3A5F"),
        accentSubtle:   Color(hex: "172554"),

        positive:       Color(hex: "22C55E"),
        positiveMuted:  Color(hex: "14532D"),
        negative:       Color(hex: "EF4444"),
        negativeMuted:  Color(hex: "450A0A"),
        warning:        Color(hex: "F59E0B"),
        warningMuted:   Color(hex: "451A03"),
        info:           Color(hex: "3B82F6"),
        projected:      Color(hex: "8B5CF6"),
        projectedMuted: Color(hex: "2E1065"),

        strokeSubtle:   Color(hex: "1C1C1F"),
        strokeDefault:  Color(hex: "27272A"),
        strokeStrong:   Color(hex: "3F3F46"),

        chartPalette: [
            Color(hex: "3B82F6"),
            Color(hex: "8B5CF6"),
            Color(hex: "EC4899"),
            Color(hex: "F97316"),
            Color(hex: "22C55E"),
            Color(hex: "06B6D4"),
            Color(hex: "EAB308"),
            Color(hex: "64748B"),
        ],

        shadowColor: .black,
        shadowOpacities: [0.20, 0.30, 0.40, 0.50]
    )

    /// Pure-black OLED palette. Same accent + text hierarchy as Dark so
    /// content remains readable; only the surfaces drop to #000 and the
    /// elevations / strokes tighten so cards still feel layered against
    /// a true-black canvas.
    static let black: ThemePalette = .init(
        bgPrimary:      Color(hex: "000000"),
        bgSecondary:    Color(hex: "0A0A0A"),
        bgTertiary:     Color(hex: "111111"),
        bgQuaternary:   Color(hex: "161616"),
        bgInput:        Color(hex: "050505"),

        textPrimary:    Color(hex: "F5F5F7"),
        textSecondary:  Color(hex: "A1A1AA"),
        textTertiary:   Color(hex: "71717A"),
        textQuaternary: Color(hex: "52525B"),

        accent:         Color(hex: "3B82F6"),
        accentHover:    Color(hex: "60A5FA"),
        accentMuted:    Color(hex: "0F2547"),
        accentSubtle:   Color(hex: "0A1838"),

        positive:       Color(hex: "22C55E"),
        positiveMuted:  Color(hex: "0E3A1E"),
        negative:       Color(hex: "EF4444"),
        negativeMuted:  Color(hex: "300707"),
        warning:        Color(hex: "F59E0B"),
        warningMuted:   Color(hex: "2E1102"),
        info:           Color(hex: "3B82F6"),
        projected:      Color(hex: "8B5CF6"),
        projectedMuted: Color(hex: "1E0A4A"),

        strokeSubtle:   Color(hex: "141414"),
        strokeDefault:  Color(hex: "1F1F1F"),
        strokeStrong:   Color(hex: "2E2E2E"),

        chartPalette: [
            Color(hex: "60A5FA"),
            Color(hex: "A78BFA"),
            Color(hex: "F472B6"),
            Color(hex: "FB923C"),
            Color(hex: "4ADE80"),
            Color(hex: "22D3EE"),
            Color(hex: "FACC15"),
            Color(hex: "94A3B8"),
        ],

        shadowColor: .black,
        // True-black surfaces swallow shadow contrast — pull opacities up
        // a touch so elevation reads at all.
        shadowOpacities: [0.45, 0.60, 0.72, 0.85]
    )

    /// Light palette — designed to feel calm and premium, not the default
    /// SwiftUI `.light` look. Soft warm canvas, white cards that lift, cool
    /// blue-gray strokes, AA-contrast text. Accent steps a notch deeper so
    /// it stays legible on white and on canvas.
    static let light: ThemePalette = .init(
        bgPrimary:      Color(hex: "F6F6F8"),
        bgSecondary:    Color(hex: "FFFFFF"),
        bgTertiary:     Color(hex: "F1F2F5"),
        bgQuaternary:   Color(hex: "E8EAEF"),
        bgInput:        Color(hex: "FFFFFF"),

        textPrimary:    Color(hex: "0A0B0E"),
        textSecondary:  Color(hex: "44464D"),
        textTertiary:   Color(hex: "70737B"),
        textQuaternary: Color(hex: "9DA0A8"),

        accent:         Color(hex: "2563EB"),
        accentHover:    Color(hex: "1D4ED8"),
        accentMuted:    Color(hex: "DBEAFE"),
        accentSubtle:   Color(hex: "EFF6FF"),

        positive:       Color(hex: "16A34A"),
        positiveMuted:  Color(hex: "DCFCE7"),
        negative:       Color(hex: "DC2626"),
        negativeMuted:  Color(hex: "FEE2E2"),
        warning:        Color(hex: "D97706"),
        warningMuted:   Color(hex: "FEF3C7"),
        info:           Color(hex: "2563EB"),
        projected:      Color(hex: "7C3AED"),
        projectedMuted: Color(hex: "EDE9FE"),

        // Soft, slightly cool strokes — keep cards distinguishable from the
        // canvas without drawing heavy boxes.
        strokeSubtle:   Color(hex: "ECEDEF"),
        strokeDefault:  Color(hex: "DDDEE2"),
        strokeStrong:   Color(hex: "C5C7CD"),

        chartPalette: [
            Color(hex: "2563EB"),
            Color(hex: "7C3AED"),
            Color(hex: "DB2777"),
            Color(hex: "EA580C"),
            Color(hex: "16A34A"),
            Color(hex: "0891B2"),
            Color(hex: "CA8A04"),
            Color(hex: "475569"),
        ],

        // A slate-tinted shadow reads as soft depth, not as a black smudge.
        shadowColor: Color(hex: "0F172A"),
        shadowOpacities: [0.04, 0.07, 0.10, 0.14]
    )

    static func palette(for mode: ThemeMode) -> ThemePalette {
        switch mode {
        case .light: return .light
        case .dark:  return .dark
        case .black: return .black
        }
    }
}

// MARK: - Theme accessor

/// Lightweight, UserDefaults-driven gateway. Color tokens read through
/// `Theme.palette` on every access — palette structs are stored once as
/// static constants, so this is a single dict-style switch per access.
enum AppTheme {
    static var mode: ThemeMode { ThemeStorage.current }
    static var palette: ThemePalette { .palette(for: mode) }
}

// MARK: - View helper

extension View {
    /// Applies the current theme's `ColorScheme` to this view tree. Use this
    /// at every window/sheet root that previously hard-coded
    /// `.preferredColorScheme(.dark)`.
    func themedColorScheme() -> some View {
        modifier(ThemedColorSchemeModifier())
    }
}

private struct ThemedColorSchemeModifier: ViewModifier {
    @AppStorage(ThemeStorage.key) private var rawMode: String = ThemeMode.dark.rawValue

    func body(content: Content) -> some View {
        let mode = ThemeMode(rawValue: rawMode) ?? .dark
        content.preferredColorScheme(mode.colorScheme)
    }
}
