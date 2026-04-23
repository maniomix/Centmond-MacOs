import SwiftUI

/// Modern calendar-only picker. Replaces `DatePicker(.graphical)` in our
/// entry-sheet popovers because the native graphical style renders an
/// analog clock for the time component (dated) and its calendar grid
/// doesn't honor the app's dark-theme typography / accent colors.
///
/// Shape:
///   ┌─────────────────────────────────┐
///   │  April 2026              ◀ Today ▶│
///   │  Mo  Tu  We  Th  Fr  Sa  Su      │
///   │   30  31   1   2   3   4   5    │  ← leading days from prev month
///   │    6   7   8   9  10  11  12    │
///   │   13  14  15  16  17 [18] 19    │  ← 18 = selected (accent circle)
///   │   20  21  22  23  24  25  26    │
///   │   27  28  29  30   1   2   3    │  ← trailing days from next month
///   └─────────────────────────────────┘
///
/// Binds to a `Date`. Only the year/month/day portion is modified —
/// the hour/minute remain untouched so callers can combine this with a
/// separate time picker and both feed the same `Date`.
struct ModernCalendarPicker: View {
    @Binding var date: Date

    /// Month currently displayed. Defaults to the bound date's month;
    /// changes only when the user navigates prev/next, so paging
    /// doesn't require mutating the selected date.
    @State private var displayedMonth: Date

    private let calendar: Calendar

    init(date: Binding<Date>, calendar: Calendar? = nil) {
        self._date = date
        // Pull the user's "Start of Week" preference (1 = Sunday,
        // 2 = Monday) and apply it to the calendar's firstWeekday.
        // Without this the picker always starts on whatever the
        // system default is regardless of the Settings choice.
        let systemCalendar = calendar ?? .current
        var customized = systemCalendar
        let startPref = UserDefaults.standard.object(forKey: "startOfWeek") as? Int ?? 1
        customized.firstWeekday = startPref
        self.calendar = customized
        _displayedMonth = State(initialValue: date.wrappedValue.startOfMonth(using: customized))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            weekdayHeader
            dayGrid
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header (month label + navigation)

    private var header: some View {
        HStack(spacing: 8) {
            Text(monthYearLabel)
                .font(CentmondTheme.Typography.bodyLarge.weight(.semibold))
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .contentTransition(.opacity)

            Spacer()

            Button { navigateMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(CentmondTheme.Typography.captionSmallSemibold)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Previous month")

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    displayedMonth = Date().startOfMonth(using: calendar)
                }
            } label: {
                Text("Today")
                    .font(CentmondTheme.Typography.captionSmallSemibold)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(CentmondTheme.Colors.accent.opacity(0.14))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Jump to today")

            Button { navigateMonth(1) } label: {
                Image(systemName: "chevron.right")
                    .font(CentmondTheme.Typography.captionSmallSemibold)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Next month")
        }
    }

    private func navigateMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                displayedMonth = next
            }
        }
    }

    // MARK: - Weekday header row

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(CentmondTheme.Typography.overlineSemibold)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Day grid (6 rows × 7 columns)

    private var dayGrid: some View {
        VStack(spacing: 4) {
            ForEach(0..<6, id: \.self) { weekIndex in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { dayIndex in
                        let cellDate = dateForCell(week: weekIndex, day: dayIndex)
                        dayCell(for: cellDate)
                    }
                }
            }
        }
    }

    private func dayCell(for cellDate: Date) -> some View {
        let inDisplayedMonth = calendar.isDate(cellDate, equalTo: displayedMonth, toGranularity: .month)
        let isSelected = calendar.isDate(cellDate, inSameDayAs: date)
        let isToday = calendar.isDateInToday(cellDate)
        let dayNumber = calendar.component(.day, from: cellDate)

        let fg: Color = {
            if isSelected { return .white }
            if !inDisplayedMonth { return CentmondTheme.Colors.textQuaternary.opacity(0.6) }
            if isToday { return CentmondTheme.Colors.accent }
            return CentmondTheme.Colors.textPrimary
        }()

        return Button {
            selectDate(cellDate)
        } label: {
            ZStack {
                // Selected background — filled accent circle
                if isSelected {
                    Circle()
                        .fill(CentmondTheme.Colors.accent)
                }
                // Today indicator — ring (only when NOT selected to avoid double-stroke)
                else if isToday {
                    Circle()
                        .stroke(CentmondTheme.Colors.accent.opacity(0.5), lineWidth: 1)
                }

                Text("\(dayNumber)")
                    .font(.system(size: 12, weight: isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(fg)
                    .monospacedDigit()
            }
            .frame(width: 32, height: 32)
            .frame(maxWidth: .infinity)  // stretch so the Button fills its grid cell
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(cellDate.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
    }

    // MARK: - Date math

    /// Grid anchor = the first-weekday-of-week on or before the 1st of
    /// the displayed month. Computed from `calendar.firstWeekday` so
    /// Monday-first and Sunday-first both work. Before: hardcoded to
    /// Monday-first, ignoring the Settings → Start of Week picker.
    private var gridAnchor: Date {
        let firstOfMonth = displayedMonth.startOfMonth(using: calendar)
        let weekday = calendar.component(.weekday, from: firstOfMonth)  // 1...7
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: firstOfMonth) ?? firstOfMonth
    }

    private func dateForCell(week: Int, day: Int) -> Date {
        let offset = week * 7 + day
        return calendar.date(byAdding: .day, value: offset, to: gridAnchor) ?? gridAnchor
    }

    /// Commit the user's selection while preserving the hour/minute
    /// portion of the currently-bound date. The caller pairs this with
    /// a separate time picker; both writes go to the same `$date`.
    private func selectDate(_ newDate: Date) {
        let timeParts = calendar.dateComponents([.hour, .minute, .second], from: date)
        var combined = calendar.dateComponents([.year, .month, .day], from: newDate)
        combined.hour = timeParts.hour ?? 0
        combined.minute = timeParts.minute ?? 0
        combined.second = timeParts.second ?? 0
        combined.timeZone = .current

        if let merged = calendar.date(from: combined) {
            withAnimation(.easeInOut(duration: 0.15)) {
                date = merged
            }
        }
    }

    // MARK: - Labels

    private var monthYearLabel: String {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        f.locale = Locale.current
        return f.string(from: displayedMonth).capitalized
    }

    /// Weekday symbols ordered to match `calendar.firstWeekday`. Uses
    /// `shortStandaloneWeekdaySymbols` for locale-correct abbreviations.
    /// firstWeekday = 1 (Sun) keeps the natural Sun..Sat order; = 2
    /// (Mon) rotates to Mon..Sun; and so on.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols  // [Sun, Mon, ..., Sat]
        let rotate = calendar.firstWeekday - 1  // 0 = no rotation
        let rotated = Array(symbols[rotate...] + symbols[..<rotate])
        return rotated.map { String($0.prefix(2)) }
    }
}

private extension Date {
    func startOfMonth(using calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: self)
        return calendar.date(from: components) ?? self
    }
}
