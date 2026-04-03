import Foundation

enum RecurrenceFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly
    case biweekly
    case monthly
    case quarterly
    case annual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Biweekly"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .annual: "Annually"
        }
    }

    /// Returns the projected occurrence date within [monthStart, monthEnd), or nil if none.
    func projectedDate(anchorDate: Date, monthStart: Date, monthEnd: Date) -> Date? {
        let cal = Calendar.current
        var date = anchorDate
        while date >= monthEnd {
            date = step(date, by: -1, calendar: cal)
        }
        while date < monthStart {
            date = step(date, by: 1, calendar: cal)
        }
        return (date >= monthStart && date < monthEnd) ? date : nil
    }

    func occursInMonth(anchorDate: Date, monthStart: Date, monthEnd: Date) -> Bool {
        projectedDate(anchorDate: anchorDate, monthStart: monthStart, monthEnd: monthEnd) != nil
    }

    private func step(_ date: Date, by n: Int, calendar: Calendar) -> Date {
        switch self {
        case .weekly:    return calendar.date(byAdding: .weekOfYear, value: n,      to: date)!
        case .biweekly:  return calendar.date(byAdding: .weekOfYear, value: 2 * n,  to: date)!
        case .monthly:   return calendar.date(byAdding: .month,      value: n,      to: date)!
        case .quarterly: return calendar.date(byAdding: .month,      value: 3 * n,  to: date)!
        case .annual:    return calendar.date(byAdding: .year,        value: n,      to: date)!
        }
    }
}
