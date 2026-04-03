import Foundation

enum TransactionStatus: String, Codable, CaseIterable, Identifiable {
    case cleared
    case pending
    case reconciled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cleared: "Cleared"
        case .pending: "Pending"
        case .reconciled: "Reconciled"
        }
    }

    var dotColor: String {
        switch self {
        case .cleared: "22C55E"
        case .pending: "F59E0B"
        case .reconciled: "71717A"
        }
    }
}
