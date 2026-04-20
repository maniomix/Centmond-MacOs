import Foundation

enum GoalContributionKind: String, Codable, CaseIterable {
    case manual
    case fromIncome
    case fromTransfer
    case autoRule
}
