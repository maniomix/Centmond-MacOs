import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv
    case json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .csv: "CSV (.csv)"
        case .json: "JSON (.json)"
        }
    }
}

enum ExportDateRange: String, CaseIterable, Identifiable {
    case thisMonth
    case lastThreeMonths
    case thisYear
    case allTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thisMonth: "This Month"
        case .lastThreeMonths: "Last 3 Months"
        case .thisYear: "This Year"
        case .allTime: "All Time"
        }
    }
}
