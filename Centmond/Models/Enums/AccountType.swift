import Foundation

enum AccountType: String, Codable, CaseIterable, Identifiable {
    case checking
    case savings
    case creditCard
    case investment
    case cash
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .creditCard: "Credit Card"
        case .investment: "Investment"
        case .cash: "Cash"
        case .other: "Other"
        }
    }

    var iconName: String {
        switch self {
        case .checking: "building.columns.fill"
        case .savings: "banknote.fill"
        case .creditCard: "creditcard.fill"
        case .investment: "chart.line.uptrend.xyaxis"
        case .cash: "dollarsign.circle.fill"
        case .other: "ellipsis.circle.fill"
        }
    }
}
