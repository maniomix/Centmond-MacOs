import SwiftUI

/// Canonical way to display a `BudgetCategory` inline. Use anywhere the
/// category appears as metadata next to other content (transaction rows,
/// review chips, prediction lists, AI insights). Don't use for full-row
/// category items where the row IS the category (budget management,
/// pickers, alert text) — those already have richer treatment.
///
/// Cross-platform (no AppKit/UIKit) so the same chip ships on Mac + iOS.
struct CategoryPill: View {

    let name: String
    let icon: String
    let colorHex: String

    /// Visual density. `.compact` for caption-row metadata, `.regular`
    /// for stand-alone tag chips, `.large` for hero/header treatments.
    var size: Size = .compact

    /// Show the SF Symbol icon alongside the name. Defaults true; set
    /// false in dense lists where the row already has a category icon
    /// at the leading edge.
    var showsIcon: Bool = true

    enum Size {
        case compact, regular, large

        var font: Font {
            switch self {
            case .compact: return .caption2.weight(.semibold)
            case .regular: return .caption.weight(.semibold)
            case .large:   return .footnote.weight(.semibold)
            }
        }
        var iconFont: Font {
            switch self {
            case .compact: return .system(size: 9, weight: .semibold)
            case .regular: return .system(size: 11, weight: .semibold)
            case .large:   return .system(size: 12, weight: .semibold)
            }
        }
        var hPad: CGFloat {
            switch self {
            case .compact: return 7
            case .regular: return 9
            case .large:   return 11
            }
        }
        var vPad: CGFloat {
            switch self {
            case .compact: return 3
            case .regular: return 4
            case .large:   return 6
            }
        }
    }

    init(category: BudgetCategory, size: Size = .compact, showsIcon: Bool = true) {
        self.name = category.name
        self.icon = category.icon
        self.colorHex = category.colorHex
        self.size = size
        self.showsIcon = showsIcon
    }

    /// Stand-alone init for callers that have name/icon/color but not the
    /// model — e.g. precomputed snapshots, AI predictions, fallback rows.
    init(name: String, icon: String, colorHex: String, size: Size = .compact, showsIcon: Bool = true) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.size = size
        self.showsIcon = showsIcon
    }

    var body: some View {
        let tint = Color(hex: colorHex)
        HStack(spacing: 4) {
            if showsIcon {
                Image(systemName: icon).font(size.iconFont)
            }
            Text(name).font(size.font)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, size.hPad)
        .padding(.vertical, size.vPad)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
        )
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Convenience for the common "tx.category, falling back to a muted
/// 'Uncategorized' chip" caption row pattern.
struct OptionalCategoryPill: View {
    let category: BudgetCategory?
    var size: CategoryPill.Size = .compact
    var showsIcon: Bool = true
    var fallback: String = "Uncategorized"

    var body: some View {
        if let category {
            CategoryPill(category: category, size: size, showsIcon: showsIcon)
        } else {
            // Muted gray chip for missing-category rows so they still
            // look "tagged" but read as needs-attention.
            HStack(spacing: 4) {
                if showsIcon {
                    Image(systemName: "questionmark.circle").font(size.iconFont)
                }
                Text(fallback).font(size.font)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

