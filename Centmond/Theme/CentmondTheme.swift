import SwiftUI

enum CentmondTheme {

    // MARK: - Colors
    //
    // Each token forwards into the active `ThemePalette` (see ThemePalette.swift).
    // Callers keep the same `CentmondTheme.Colors.bgPrimary` API — they no
    // longer hold a fixed hex value, they re-resolve against the current
    // mode (Light / Dark / Black). When the user toggles theme, the
    // AppShell-level `.id(themeMode)` (see AppShell.swift) rebuilds the
    // visible content tree so every static-color read picks up the new
    // palette.

    enum Colors {
        // Backgrounds
        static var bgPrimary: Color    { AppTheme.palette.bgPrimary }
        static var bgSecondary: Color  { AppTheme.palette.bgSecondary }
        static var bgTertiary: Color   { AppTheme.palette.bgTertiary }
        static var bgQuaternary: Color { AppTheme.palette.bgQuaternary }
        static var bgInput: Color      { AppTheme.palette.bgInput }

        // Text
        static var textPrimary: Color    { AppTheme.palette.textPrimary }
        static var textSecondary: Color  { AppTheme.palette.textSecondary }
        static var textTertiary: Color   { AppTheme.palette.textTertiary }
        static var textQuaternary: Color { AppTheme.palette.textQuaternary }

        // Accent
        static var accent: Color       { AppTheme.palette.accent }
        static var accentHover: Color  { AppTheme.palette.accentHover }
        static var accentMuted: Color  { AppTheme.palette.accentMuted }
        static var accentSubtle: Color { AppTheme.palette.accentSubtle }

        // Semantic
        static var positive: Color       { AppTheme.palette.positive }
        static var positiveMuted: Color  { AppTheme.palette.positiveMuted }
        static var negative: Color       { AppTheme.palette.negative }
        static var negativeMuted: Color  { AppTheme.palette.negativeMuted }
        static var warning: Color        { AppTheme.palette.warning }
        static var warningMuted: Color   { AppTheme.palette.warningMuted }
        static var info: Color           { AppTheme.palette.info }
        static var projected: Color      { AppTheme.palette.projected }
        static var projectedMuted: Color { AppTheme.palette.projectedMuted }

        // Strokes
        static var strokeSubtle: Color  { AppTheme.palette.strokeSubtle }
        static var strokeDefault: Color { AppTheme.palette.strokeDefault }
        static var strokeStrong: Color  { AppTheme.palette.strokeStrong }

        // Charts
        static var chartPalette: [Color] { AppTheme.palette.chartPalette }
    }

    // MARK: - Typography

    enum Typography {
        static let display = Font.system(size: 32, weight: .bold)
        static let heading1 = Font.system(size: 24, weight: .semibold)
        static let heading2 = Font.system(size: 18, weight: .semibold)
        static let subheading = Font.system(size: 16, weight: .semibold)
        static let heading3 = Font.system(size: 15, weight: .medium)
        static let bodyLarge = Font.system(size: 14, weight: .regular)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let caption = Font.system(size: 12, weight: .regular)
        static let captionMedium = Font.system(size: 12, weight: .medium)
        static let captionSmall = Font.system(size: 11, weight: .regular)
        static let captionSmallSemibold = Font.system(size: 11, weight: .semibold)
        static let overline = Font.system(size: 10, weight: .medium)
        static let overlineRegular = Font.system(size: 10, weight: .regular)
        static let overlineSemibold = Font.system(size: 10, weight: .semibold)
        static let micro = Font.system(size: 9, weight: .regular)
        static let microBold = Font.system(size: 8, weight: .bold)
        static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)
        static let monoLarge = Font.system(size: 20, weight: .semibold, design: .monospaced)
        static let monoDisplay = Font.system(size: 28, weight: .bold, design: .monospaced)
    }

    // MARK: - Spacing (4pt grid)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        static let huge: CGFloat = 40
        static let massive: CGFloat = 48
    }

    // MARK: - Corner Radii

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let mdLoose: CGFloat = 10
        static let lg: CGFloat = 12
        static let xlTight: CGFloat = 14
        static let xl: CGFloat = 16
        static let full: CGFloat = 9999
    }

    // MARK: - Elevation / Shadow

    enum Elevation {
        /// Palette-aware shadow for the four canonical elevation levels.
        /// In Light mode the shadow is a soft slate tint at low opacity so
        /// cards lift without printing a black smudge; in Dark/Black it's
        /// pure black, deeper for OLED.
        static func shadow(level: Int) -> (color: Color, radius: CGFloat, y: CGFloat) {
            let palette = AppTheme.palette
            let geometry: (radius: CGFloat, y: CGFloat)
            switch level {
            case 1: geometry = (2, 1)
            case 2: geometry = (12, 4)
            case 3: geometry = (24, 8)
            case 4: geometry = (48, 16)
            default: return (.clear, 0, 0)
            }
            let opacities = palette.shadowOpacities
            let idx = max(0, min(opacities.count - 1, level - 1))
            return (palette.shadowColor.opacity(opacities[idx]), geometry.radius, geometry.y)
        }
    }

    // MARK: - Animation / Motion

    enum Motion {
        static let micro: Animation = .easeOut(duration: 0.15)
        static let `default`: Animation = .easeInOut(duration: 0.25)
        static let layout: Animation = .spring(response: 0.35, dampingFraction: 0.85)
        static let chart: Animation = .easeOut(duration: 0.5)
        static let sheet: Animation = .easeInOut(duration: 0.3)
        static let page: Animation = .easeInOut(duration: 0.25)
        static let numeric: Animation = .spring(response: 0.4, dampingFraction: 0.7)
    }

    // MARK: - Sizing Constants

    enum Sizing {
        static let sidebarWidth: CGFloat = 220
        static let inspectorWidth: CGFloat = 320
        static let sheetWidth: CGFloat = 480
        static let sheetWide: CGFloat = 640
        static let settingsWidth: CGFloat = 720
        static let commandPaletteWidth: CGFloat = 520
        static let tableRowHeight: CGFloat = 44
        static let tableRowCompact: CGFloat = 36
        static let tableHeaderHeight: CGFloat = 32
        static let sidebarItemHeight: CGFloat = 36
        static let buttonHeight: CGFloat = 32
        static let inputHeight: CGFloat = 32
        static let inputCompact: CGFloat = 28
        static let minWindowWidth: CGFloat = 960
        static let minWindowHeight: CGFloat = 600
    }
}
