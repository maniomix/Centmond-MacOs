import SwiftUI

enum CentmondTheme {

    // MARK: - Colors

    enum Colors {
        // Background hierarchy (darkest to lightest)
        static let bgPrimary = Color(hex: "09090B")
        static let bgSecondary = Color(hex: "111114")
        static let bgTertiary = Color(hex: "18181B")
        static let bgQuaternary = Color(hex: "1C1C1F")
        static let bgInput = Color(hex: "0D0D0F")

        // Text hierarchy
        static let textPrimary = Color(hex: "F5F5F7")
        static let textSecondary = Color(hex: "A1A1AA")
        static let textTertiary = Color(hex: "71717A")
        static let textQuaternary = Color(hex: "52525B")

        // Accent (brand blue)
        static let accent = Color(hex: "3B82F6")
        static let accentHover = Color(hex: "60A5FA")
        static let accentMuted = Color(hex: "1E3A5F")
        static let accentSubtle = Color(hex: "172554")

        // Semantic
        static let positive = Color(hex: "22C55E")
        static let positiveMuted = Color(hex: "14532D")
        static let negative = Color(hex: "EF4444")
        static let negativeMuted = Color(hex: "450A0A")
        static let warning = Color(hex: "F59E0B")
        static let warningMuted = Color(hex: "451A03")
        static let info = Color(hex: "3B82F6")
        // Forecast / projection hue — violet, distinct from accent/warning/negative
        static let projected = Color(hex: "8B5CF6")
        static let projectedMuted = Color(hex: "2E1065")

        // Strokes and borders
        static let strokeSubtle = Color(hex: "1C1C1F")
        static let strokeDefault = Color(hex: "27272A")
        static let strokeStrong = Color(hex: "3F3F46")

        // Chart palette (8 distinct, accessible on dark backgrounds)
        static let chartPalette: [Color] = [
            Color(hex: "3B82F6"), // Blue
            Color(hex: "8B5CF6"), // Purple
            Color(hex: "EC4899"), // Pink
            Color(hex: "F97316"), // Orange
            Color(hex: "22C55E"), // Green
            Color(hex: "06B6D4"), // Cyan
            Color(hex: "EAB308"), // Yellow
            Color(hex: "64748B"), // Slate
        ]
    }

    // MARK: - Typography

    enum Typography {
        static let display = Font.system(size: 32, weight: .bold)
        static let heading1 = Font.system(size: 24, weight: .semibold)
        static let heading2 = Font.system(size: 18, weight: .semibold)
        static let heading3 = Font.system(size: 15, weight: .medium)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let caption = Font.system(size: 12, weight: .regular)
        static let captionMedium = Font.system(size: 12, weight: .medium)
        static let overline = Font.system(size: 10, weight: .medium)
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
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let full: CGFloat = 9999
    }

    // MARK: - Elevation / Shadow

    enum Elevation {
        static func shadow(level: Int) -> (color: Color, radius: CGFloat, y: CGFloat) {
            switch level {
            case 1: return (Color.black.opacity(0.2), 2, 1)
            case 2: return (Color.black.opacity(0.3), 12, 4)
            case 3: return (Color.black.opacity(0.4), 24, 8)
            case 4: return (Color.black.opacity(0.5), 48, 16)
            default: return (.clear, 0, 0)
            }
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
