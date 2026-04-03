import Foundation

enum GoalStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case paused
    case completed
    case archived

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .completed: "Completed"
        case .archived: "Archived"
        }
    }
}
