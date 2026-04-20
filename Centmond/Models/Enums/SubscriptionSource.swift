import Foundation

/// Where a Subscription record originated. Drives UI badges ("Auto-detected"),
/// filter tabs in the Detected queue, and keeps the review-and-confirm flow
/// from re-prompting on rows the user has already manually entered.
enum SubscriptionSource: String, Codable, CaseIterable, Identifiable {
    case manual
    case detected
    case imported

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: "Manual"
        case .detected: "Auto-detected"
        case .imported: "Imported"
        }
    }
}
