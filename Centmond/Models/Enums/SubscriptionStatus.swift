import Foundation

enum SubscriptionStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case paused
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .cancelled: "Cancelled"
        }
    }

    var dotColor: String {
        switch self {
        case .active: "22C55E"
        case .paused: "F59E0B"
        case .cancelled: "EF4444"
        }
    }
}
