import Foundation
import SwiftData

/// Centralized rules for tag lookup and creation. Tag names are matched
/// case- and whitespace-insensitively via `TextNormalization.equalsNormalized`,
/// so "Travel", " travel ", and "TRAVEL" all resolve to the same tag — and
/// duplicates can never be created through this entry point.
///
/// Sheets and bulk paths must go through these helpers instead of inserting
/// `Tag(name:)` directly.
enum TagService {

    /// Parse a comma-separated user string into trimmed, non-empty,
    /// case-insensitively-deduped tag names. Order is preserved.
    static func parseInput(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.split(separator: ",", omittingEmptySubsequences: true) {
            let trimmed = TextNormalization.trimmed(String(raw))
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    /// Find an existing tag by normalized name, or create and insert a new
    /// one. Use this everywhere a user-supplied tag name needs to become a
    /// `Tag` instance — it is the single source of truth for uniqueness.
    static func findOrCreate(name: String, in context: ModelContext, existing: [Tag]) -> Tag? {
        let trimmed = TextNormalization.trimmed(name)
        guard !trimmed.isEmpty else { return nil }
        if let match = existing.first(where: { TextNormalization.equalsNormalized($0.name, trimmed) }) {
            return match
        }
        let tag = Tag(name: trimmed)
        context.insert(tag)
        return tag
    }

    /// Resolve a comma-separated input string into a `[Tag]` ready to assign
    /// to `Transaction.tags`. New tags are created in `context` as needed.
    static func resolve(input: String, in context: ModelContext, existing: [Tag]) -> [Tag] {
        var working = existing
        var result: [Tag] = []
        for name in parseInput(input) {
            if let tag = findOrCreate(name: name, in: context, existing: working) {
                if !result.contains(where: { $0.id == tag.id }) {
                    result.append(tag)
                }
                if !working.contains(where: { $0.id == tag.id }) {
                    working.append(tag)
                }
            }
        }
        return result
    }
}
