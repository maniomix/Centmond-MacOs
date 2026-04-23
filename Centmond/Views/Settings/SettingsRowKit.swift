import SwiftUI

// Phase 3 of the Settings redesign — row + group primitive library.
//
// Today every card in InAppSettingsView hand-builds its own row with the
// `settingsRow` helper (fixed 44pt height, no help-text slot) or drops to
// ad-hoc HStacks when the content doesn't fit (Danger Zone card). This file
// replaces that with a small, typed vocabulary so Phases 4-9 can assemble
// each domain's content from the same parts.
//
// Design rules:
//  • Rows size to content. No fixed heights — multi-line help text just
//    expands the row, instead of spilling into an extra card row.
//  • Every row accepts `help:` as the canonical caption slot. Rendered as
//    a 2-line foregroundStyle(.textTertiary) line below the title.
//  • Leading label is always `SettingsRowLabel` (icon + title + help).
//    Trailing content is the row-kind's control — Toggle / Picker / etc.
//  • Groups own the card chrome (background, stroke, header). Rows don't
//    paint backgrounds — they're meant to live inside a group.

// MARK: - Shared leading label

struct SettingsRowLabel: View {
    let title: String
    let systemImage: String?
    let help: String?

    init(_ title: String, systemImage: String? = nil, help: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
    }

    var body: some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 20, alignment: .center)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                if let help, !help.isEmpty {
                    Text(help)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: CentmondTheme.Spacing.md)
        }
    }
}

// MARK: - Row container

/// A row is a horizontal layout of `SettingsRowLabel` + trailing control.
/// The container adds vertical padding (10pt top/bottom) so neighboring
/// rows inside a group breathe the same amount regardless of whether the
/// row has a help line or not.
private struct SettingsRowContainer<Trailing: View>: View {
    let label: SettingsRowLabel
    let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: CentmondTheme.Spacing.md) {
            label
            trailing
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Typed row factory

/// Namespace for the typed row kinds. Call sites read like
/// `SettingsRow.toggle("Haptics", systemImage: "waveform.path", help: "…", isOn: $x)`.
enum SettingsRow {

    /// Toggle row (on/off switch).
    static func toggle(
        _ title: String,
        systemImage: String? = nil,
        help: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        SettingsRowContainer(
            label: SettingsRowLabel(title, systemImage: systemImage, help: help),
            trailing: Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        )
    }

    /// Picker row. `options` is an ordered `(value, label)` list so callers
    /// keep full control over order and labels. Renders as a custom rounded
    /// pill + chevron, matching the action/navigation rows — the stock
    /// `Picker` gives an NSPopUpButton that stands out from Centmond's theme.
    static func picker<Value: Hashable>(
        _ title: String,
        systemImage: String? = nil,
        help: String? = nil,
        selection: Binding<Value>,
        options: [(Value, String)],
        width: CGFloat = 160
    ) -> some View {
        SettingsRowContainer(
            label: SettingsRowLabel(title, systemImage: systemImage, help: help),
            trailing: SettingsPickerPill(
                selection: selection,
                options: options,
                width: width
            )
        )
    }

    /// Stepper row. `format` renders the current value on the trailing side
    /// (e.g. `{ "\($0) days" }` or `{ $0 == 0 ? "Off" : "\($0)m" }`).
    static func stepper(
        _ title: String,
        systemImage: String? = nil,
        help: String? = nil,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        format: @escaping (Int) -> String = { "\($0)" }
    ) -> some View {
        SettingsRowContainer(
            label: SettingsRowLabel(title, systemImage: systemImage, help: help),
            trailing: HStack(spacing: 8) {
                Text(format(value.wrappedValue))
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .monospacedDigit()
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
            }
        )
    }

    /// Slider row. Shows the formatted current value above the slider track
    /// so the user never has to drag to see the current state.
    static func slider(
        _ title: String,
        systemImage: String? = nil,
        help: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        format: @escaping (Double) -> String
    ) -> some View {
        // Slider is too wide to fit beside the label; stack vertically and
        // put the current value in the top-right. Still a single row.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: CentmondTheme.Spacing.md) {
                SettingsRowLabel(title, systemImage: systemImage, help: help)
                Text(format(value.wrappedValue))
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .monospacedDigit()
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
        .padding(.vertical, 10)
    }

    /// Action row — a button on the trailing edge. For destructive actions
    /// pass `role: .destructive` and the button tint flips to the negative
    /// theme color.
    static func action(
        _ title: String,
        systemImage: String? = nil,
        help: String? = nil,
        buttonLabel: String,
        buttonSystemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        SettingsRowContainer(
            label: SettingsRowLabel(title, systemImage: systemImage, help: help),
            trailing: Button(role: role, action: action) {
                HStack(spacing: 6) {
                    if let buttonSystemImage {
                        Image(systemName: buttonSystemImage)
                            .font(CentmondTheme.Typography.captionSmallSemibold)
                    }
                    Text(buttonLabel)
                        .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
                }
                .foregroundStyle(role == .destructive ? CentmondTheme.Colors.negative : CentmondTheme.Colors.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    (role == .destructive ? CentmondTheme.Colors.negative : CentmondTheme.Colors.accent)
                        .opacity(0.12),
                    in: RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                        .stroke(
                            (role == .destructive ? CentmondTheme.Colors.negative : CentmondTheme.Colors.accent)
                                .opacity(0.32),
                            lineWidth: 1
                        )
                )
                // Make the whole pill (padding + background) tappable, not
                // just the opaque text glyphs. Without this, .buttonStyle(.plain)
                // hit-tests only on the Text/Image, forcing the user to click
                // the text exactly.
                .contentShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        )
    }

    /// Navigation row — tappable row that drills into a subpane or sheet.
    /// Shows an optional trailing summary (e.g. active model name) and a
    /// chevron.
    static func navigation(
        _ title: String,
        systemImage: String? = nil,
        help: String? = nil,
        trailing: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: CentmondTheme.Spacing.md) {
                SettingsRowLabel(title, systemImage: systemImage, help: help)
                if let trailing {
                    Text(trailing)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(CentmondTheme.Typography.captionSmallSemibold)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Status row — read-only, trailing value. For things like
    /// "Version: 1.2 (345)" or "Model: Ready".
    static func status(
        _ title: String,
        systemImage: String? = nil,
        help: String? = nil,
        value: String,
        valueColor: Color? = nil,
        indicator: Color? = nil
    ) -> some View {
        SettingsRowContainer(
            label: SettingsRowLabel(title, systemImage: systemImage, help: help),
            trailing: HStack(spacing: 6) {
                if let indicator {
                    Circle()
                        .fill(indicator)
                        .frame(width: 7, height: 7)
                }
                Text(value)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(valueColor ?? CentmondTheme.Colors.textTertiary)
            }
        )
    }
}

// MARK: - Shim for bespoke trailing controls

/// Escape hatch for rows whose trailing control isn't one of the typed
/// kinds (e.g. `KeyboardShortcuts.Recorder`, a progress bar with its own
/// Cancel button). Identical padding + alignment as the typed rows.
struct SettingsRowContainerShim<Trailing: View>: View {
    let label: SettingsRowLabel
    let trailing: Trailing

    init(label: SettingsRowLabel, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: CentmondTheme.Spacing.md) {
            label
            trailing
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Picker pill

/// Custom trailing control for `SettingsRow.picker`. Replaces the stock
/// macOS NSPopUpButton with a rounded-rect menu that matches the Centmond
/// theme (same radius, tint, typography as the action/navigation rows).
/// Uses `Menu` so the dropdown still behaves natively (arrow-key nav,
/// checkmark on the selected row, Escape dismisses).
struct SettingsPickerPill<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    let width: CGFloat

    private var currentLabel: String {
        options.first(where: { $0.0 == selection })?.1 ?? "—"
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button {
                    selection = option.0
                } label: {
                    if option.0 == selection {
                        Label(option.1, systemImage: "checkmark")
                    } else {
                        Text(option.1)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(currentLabel)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(width: width, alignment: .leading)
            .background(
                CentmondTheme.Colors.bgTertiary,
                in: RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
            // Whole pill clickable, not just the glyphs — same fix as
            // SettingsRow.action buttons.
            .contentShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Group container

/// Card chrome for a collection of rows. Matches the look of the old
/// `settingsCard` helper but lives in one place so Phase 4+ doesn't
/// re-implement it per domain. Children are stacked with a thin divider
/// between them (stripped when the child is itself a Divider so callers
/// can still force-remove a separator via `EmptyView()`).
struct SettingsRowGroup<Content: View>: View {
    let title: String?
    let icon: String?
    let iconColor: Color
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(
        _ title: String? = nil,
        icon: String? = nil,
        iconColor: Color = CentmondTheme.Colors.accent,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    if let icon {
                        Image(systemName: icon)
                            .font(CentmondTheme.Typography.bodyLarge.weight(.medium))
                            .foregroundStyle(iconColor)
                            .frame(width: 24, height: 24)
                            .background(iconColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
                    }
                    Text(title.uppercased())
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .tracking(0.5)
                }
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .padding(.vertical, CentmondTheme.Spacing.md)

                Divider().background(CentmondTheme.Colors.strokeSubtle)
            }

            VStack(alignment: .leading, spacing: 0) {
                _VariadicView.Tree(GroupLayout()) {
                    content()
                }
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)

            if let footer, !footer.isEmpty {
                Divider().background(CentmondTheme.Colors.strokeSubtle)
                Text(footer)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, CentmondTheme.Spacing.lg)
                    .padding(.vertical, CentmondTheme.Spacing.md)
            }
        }
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    /// Layout that inserts a thin Divider between each child of the group.
    /// Uses `_VariadicView` so callers don't have to manually sprinkle
    /// `Divider()` between every row — a common footgun in the current code.
    private struct GroupLayout: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            let ids = children.map(\.id)
            ForEach(children) { child in
                child
                if child.id != ids.last {
                    Divider().background(CentmondTheme.Colors.strokeSubtle)
                }
            }
        }
    }
}
