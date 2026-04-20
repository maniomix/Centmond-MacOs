import SwiftUI

// MARK: - CentmondDropdown — custom popover select control
//
// Replaces `Menu { ... } label: { ... }` usages inside entry-sheet
// fieldRows. The native `Menu` renders with macOS system chrome that
// clashes with our dark theme (light-ish popup background, small
// chevron, native row highlight). This one:
//   - Trigger is a plain Button rendering whatever label the caller
//     passes (so the row can still say "Uncategorized" + chevron).
//   - Popover content is a dark-themed scrollable VStack of rows.
//   - Each row: optional colored icon dot, name, checkmark if selected.
//   - Tapping a row updates the binding and closes the popover.
//
// Used by NewTransactionSheet / NewTransferSheet for every picker row.

/// Option spec passed to CentmondDropdown. Caller builds one of these
/// per item. `id` is the equality key; `iconSystem` + `iconColor` draw
/// a colored circle to the left of the name. A `nil` item represents
/// the "reset / unset" choice (e.g. "Uncategorized", "No account") and
/// gets rendered with a muted style so it reads as the default.
struct CentmondDropdownOption: Identifiable, Equatable {
    let id: String
    let name: String
    let iconSystem: String?
    let iconColor: Color?
    let isResetOption: Bool

    init(id: String, name: String, iconSystem: String? = nil, iconColor: Color? = nil, isResetOption: Bool = false) {
        self.id = id
        self.name = name
        self.iconSystem = iconSystem
        self.iconColor = iconColor
        self.isResetOption = isResetOption
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct CentmondDropdown<Label: View>: View {
    let options: [CentmondDropdownOption]
    let selectedID: String?
    let onSelect: (String?) -> Void
    @ViewBuilder let label: () -> Label

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            dropdownList
        }
    }

    private var dropdownList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(options) { option in
                    CentmondDropdownRow(
                        option: option,
                        isSelected: option.id == selectedID
                    ) {
                        Haptics.tap()
                        onSelect(option.isResetOption ? nil : option.id)
                        isOpen = false
                    }
                    if option != options.last {
                        Rectangle()
                            .fill(CentmondTheme.Colors.strokeSubtle.opacity(0.4))
                            .frame(height: 0.5)
                            .padding(.leading, 40)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 240)
        .frame(maxHeight: 320)
        .background(CentmondTheme.Colors.bgSecondary)
    }
}

/// Row inside a CentmondDropdown popover. Handles its own hover state
/// so the whole row highlights on mouse-over — a touch that native
/// Menu rows have and custom popovers need to replicate or they feel
/// dead.
private struct CentmondDropdownRow: View {
    let option: CentmondDropdownOption
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Icon dot — skipped for reset options so "Uncategorized"
                // reads as a neutral row.
                if let sys = option.iconSystem, !option.isResetOption {
                    ZStack {
                        Circle()
                            .fill((option.iconColor ?? CentmondTheme.Colors.textTertiary).opacity(0.18))
                            .frame(width: 22, height: 22)
                        Image(systemName: sys)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(option.iconColor ?? CentmondTheme.Colors.textTertiary)
                    }
                } else {
                    // Placeholder width so text aligns across rows with/without icons.
                    Color.clear.frame(width: 22, height: 22)
                }

                Text(option.name)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(option.isResetOption ? CentmondTheme.Colors.textTertiary : CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background(isHovered ? CentmondTheme.Colors.bgTertiary : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - CentmondTimePicker — custom hour + minute select
//
// Replaces `DatePicker(.hourAndMinute).datePickerStyle(.field)` which
// renders the native stepper ("08:14 ⇅") that looks dated. This one
// is two CentmondDropdowns side by side — hour (00-23) and minute
// (00-59) — with a ":" separator and consistent dark-theme styling.

struct CentmondTimePicker: View {
    @Binding var date: Date

    private let calendar = Calendar.current

    private var hour: Int { calendar.component(.hour, from: date) }
    private var minute: Int { calendar.component(.minute, from: date) }

    private static let hourOptions: [CentmondDropdownOption] = (0..<24).map {
        CentmondDropdownOption(id: String($0), name: String(format: "%02d", $0))
    }
    private static let minuteOptions: [CentmondDropdownOption] = (0..<60).map {
        CentmondDropdownOption(id: String($0), name: String(format: "%02d", $0))
    }

    var body: some View {
        HStack(spacing: 4) {
            CentmondDropdown(
                options: Self.hourOptions,
                selectedID: String(hour),
                onSelect: { idStr in
                    if let idStr, let h = Int(idStr) { setHour(h) }
                }
            ) {
                pillLabel(String(format: "%02d", hour))
            }

            Text(":")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(CentmondTheme.Colors.textSecondary)

            CentmondDropdown(
                options: Self.minuteOptions,
                selectedID: String(minute),
                onSelect: { idStr in
                    if let idStr, let m = Int(idStr) { setMinute(m) }
                }
            ) {
                pillLabel(String(format: "%02d", minute))
            }
        }
    }

    private func pillLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(CentmondTheme.Colors.textPrimary)
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(CentmondTheme.Colors.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
            )
    }

    private func setHour(_ h: Int) {
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        comps.hour = h
        if let newDate = calendar.date(from: comps) {
            date = newDate
        }
    }

    private func setMinute(_ m: Int) {
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        comps.minute = m
        if let newDate = calendar.date(from: comps) {
            date = newDate
        }
    }
}
