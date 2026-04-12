import Foundation

// ============================================================
// MARK: - AI Memory
// ============================================================
//
// Unified memory layer that learns from user behavior to make
// the AI more personal and less generic.
//
// Builds on top of (but does NOT replace) existing systems:
//   - AIMerchantMemory -- merchant->category (stays primary)
//   - AIUserPreferences -- language, spending patterns
//   - AICategorySuggester -- keyword + learned suggestions
//
// Adds new capabilities:
//   - Merchant -> tag associations
//   - Approval pattern tracking
//   - Clarification style preference
//   - Assistant tone/verbosity preference
//   - Automation comfort level
//   - Explainable memory usage
//   - Unified retrieval layer
//
// macOS Centmond: @Observable instead of ObservableObject,
// category names (String) instead of Category storageKeys.
//
// ============================================================

// MARK: - Memory Model

enum AIMemoryType: String, Codable, CaseIterable {
    case merchantCategory          = "merchant_category"
    case merchantTag               = "merchant_tag"
    case approvalPattern           = "approval_pattern"
    case clarificationStyle        = "clarification_style"
    case assistantTone             = "assistant_tone"
    case automationLevel           = "automation_level"
    case correctionPattern         = "correction_pattern"
    case budgetHandling            = "budget_handling"

    var displayName: String {
        switch self {
        case .merchantCategory:   return "Merchant Category"
        case .merchantTag:        return "Merchant Tag"
        case .approvalPattern:    return "Approval Pattern"
        case .clarificationStyle: return "Clarification Style"
        case .assistantTone:      return "Assistant Tone"
        case .automationLevel:    return "Automation Level"
        case .correctionPattern:  return "Correction Pattern"
        case .budgetHandling:     return "Budget Handling"
        }
    }

    var icon: String {
        switch self {
        case .merchantCategory:   return "tag.fill"
        case .merchantTag:        return "number"
        case .approvalPattern:    return "checkmark.shield.fill"
        case .clarificationStyle: return "questionmark.bubble.fill"
        case .assistantTone:      return "text.bubble.fill"
        case .automationLevel:    return "gearshape.fill"
        case .correctionPattern:  return "arrow.trianglehead.2.counterclockwise"
        case .budgetHandling:     return "chart.bar.fill"
        }
    }
}

enum AIMemorySource: String, Codable {
    case userCorrection           = "user_correction"
    case repeatedBehavior         = "repeated_behavior"
    case explicitPreference       = "explicit_preference"
    case approvalHistory          = "approval_history"
    case ingestionFeedback        = "ingestion_feedback"

    var displayName: String {
        switch self {
        case .userCorrection:     return "Your correction"
        case .repeatedBehavior:   return "Learned from patterns"
        case .explicitPreference: return "Your preference"
        case .approvalHistory:    return "From approval history"
        case .ingestionFeedback:  return "From import review"
        }
    }
}

struct AIMemoryEntry: Codable, Identifiable {
    let id: UUID
    let type: AIMemoryType
    var key: String
    var value: String
    var confidence: Double
    var strength: Int
    var source: AIMemorySource
    var merchantRef: String?
    var categoryRef: String?
    var tagRef: String?
    let createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var metadata: [String: String]

    var explanation: String {
        switch type {
        case .merchantCategory:
            return "\"\(displayKey)\" -> \(value)"
        case .merchantTag:
            return "\"\(displayKey)\" is tagged \"\(value)\""
        case .approvalPattern:
            let pct = metadata["approveRate"].flatMap(Double.init).map { Int($0 * 100) } ?? 0
            return "\(displayKey): \(pct)% approval rate"
        case .clarificationStyle:
            return "Prefers \(value) clarifications"
        case .assistantTone:
            return "Prefers \(value) responses"
        case .automationLevel:
            return "Automation comfort: \(value)"
        case .correctionPattern:
            let from = metadata["fromCategory"] ?? "?"
            return "\"\(displayKey)\": corrected from \(from) -> \(value)"
        case .budgetHandling:
            return "Budget preference: \(value)"
        }
    }

    var displayKey: String {
        if let m = merchantRef, !m.isEmpty { return m }
        return key
    }

    var isActionable: Bool {
        switch type {
        case .merchantCategory, .merchantTag, .correctionPattern:
            return confidence >= 0.6 && strength >= 2
        case .approvalPattern:
            return strength >= 5
        case .clarificationStyle, .assistantTone, .automationLevel, .budgetHandling:
            return true
        }
    }
}

// MARK: - Preference Value Types

enum ClarificationStyle: String, Codable, CaseIterable {
    case concise     = "concise"
    case balanced    = "balanced"
    case detailed    = "detailed"

    var displayName: String {
        switch self {
        case .concise:  return "Concise"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }
}

enum AssistantTone: String, Codable, CaseIterable {
    case brief      = "brief"
    case friendly   = "friendly"
    case thorough   = "thorough"

    var displayName: String {
        switch self {
        case .brief:    return "Brief"
        case .friendly: return "Friendly"
        case .thorough: return "Thorough"
        }
    }
}

enum AutomationComfort: String, Codable, CaseIterable {
    case conservative = "conservative"
    case moderate     = "moderate"
    case comfortable  = "comfortable"

    var displayName: String {
        switch self {
        case .conservative: return "Always Review"
        case .moderate:     return "Moderate"
        case .comfortable:  return "Trust AI"
        }
    }
}

struct ApprovalTendency {
    let actionType: String
    let approveCount: Int
    let rejectCount: Int
    let total: Int
    var approveRate: Double { total > 0 ? Double(approveCount) / Double(total) : 0.5 }
    var isStrongApprover: Bool { approveRate >= 0.8 && total >= 5 }
    var isStrongRejecter: Bool { approveRate <= 0.2 && total >= 5 }
}

// MARK: - Memory Store

@MainActor @Observable
final class AIMemoryStore {
    static let shared = AIMemoryStore()

    private(set) var entries: [AIMemoryEntry] = []

    private let storageKey = "ai.memoryStore"

    private init() {
        load()
    }

    // MARK: - Merchant Tag Learning

    func learnMerchantTag(merchant: String, tag: String, source: AIMemorySource = .repeatedBehavior) {
        let normalized = normalizeMerchant(merchant)
        let lookupKey = "tag:\(normalized):\(tag.lowercased())"

        if let idx = entries.firstIndex(where: { $0.key == lookupKey && $0.type == .merchantTag }) {
            entries[idx].strength += 1
            entries[idx].updatedAt = Date()
            entries[idx].confidence = computeTagConfidence(entries[idx].strength, source: source)
        } else {
            let entry = AIMemoryEntry(
                id: UUID(),
                type: .merchantTag,
                key: lookupKey,
                value: tag.lowercased(),
                confidence: source == .explicitPreference ? 0.9 : 0.4,
                strength: 1,
                source: source,
                merchantRef: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
                categoryRef: nil,
                tagRef: tag.lowercased(),
                createdAt: Date(),
                updatedAt: Date(),
                lastUsedAt: nil,
                metadata: [:]
            )
            entries.append(entry)
        }
        save()
    }

    func merchantTags(for merchant: String) -> [(tag: String, confidence: Double)] {
        let normalized = normalizeMerchant(merchant)
        let prefix = "tag:\(normalized):"

        return entries
            .filter { $0.type == .merchantTag && $0.key.hasPrefix(prefix) && $0.isActionable }
            .sorted { $0.confidence > $1.confidence }
            .map { ($0.value, $0.confidence) }
    }

    // MARK: - Approval Pattern Tracking

    func recordApproval(actionType: String, approved: Bool, merchant: String? = nil) {
        let lookupKey = "approval:\(actionType)"

        if let idx = entries.firstIndex(where: { $0.key == lookupKey && $0.type == .approvalPattern }) {
            entries[idx].strength += 1
            entries[idx].updatedAt = Date()

            var approveCount = Int(entries[idx].metadata["approveCount"] ?? "0") ?? 0
            var rejectCount = Int(entries[idx].metadata["rejectCount"] ?? "0") ?? 0
            if approved { approveCount += 1 } else { rejectCount += 1 }

            let total = approveCount + rejectCount
            let rate = total > 0 ? Double(approveCount) / Double(total) : 0.5

            entries[idx].metadata["approveCount"] = "\(approveCount)"
            entries[idx].metadata["rejectCount"] = "\(rejectCount)"
            entries[idx].metadata["approveRate"] = String(format: "%.2f", rate)
            entries[idx].confidence = min(Double(total) / 20.0, 1.0)
            entries[idx].value = rate >= 0.5 ? "tends_to_approve" : "tends_to_reject"
        } else {
            let entry = AIMemoryEntry(
                id: UUID(),
                type: .approvalPattern,
                key: lookupKey,
                value: approved ? "tends_to_approve" : "tends_to_reject",
                confidence: 0.1,
                strength: 1,
                source: .approvalHistory,
                merchantRef: nil,
                categoryRef: nil,
                tagRef: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastUsedAt: nil,
                metadata: [
                    "approveCount": approved ? "1" : "0",
                    "rejectCount": approved ? "0" : "1",
                    "approveRate": approved ? "1.00" : "0.00"
                ]
            )
            entries.append(entry)
        }
        save()
    }

    func approvalTendency(for actionType: String) -> ApprovalTendency? {
        let lookupKey = "approval:\(actionType)"
        guard let entry = entries.first(where: { $0.key == lookupKey && $0.type == .approvalPattern }) else {
            return nil
        }

        let approveCount = Int(entry.metadata["approveCount"] ?? "0") ?? 0
        let rejectCount = Int(entry.metadata["rejectCount"] ?? "0") ?? 0
        return ApprovalTendency(
            actionType: actionType,
            approveCount: approveCount,
            rejectCount: rejectCount,
            total: approveCount + rejectCount
        )
    }

    func allApprovalTendencies() -> [ApprovalTendency] {
        entries.filter { $0.type == .approvalPattern }
            .compactMap { entry in
                let approveCount = Int(entry.metadata["approveCount"] ?? "0") ?? 0
                let rejectCount = Int(entry.metadata["rejectCount"] ?? "0") ?? 0
                let actionType = entry.key.replacingOccurrences(of: "approval:", with: "")
                return ApprovalTendency(
                    actionType: actionType,
                    approveCount: approveCount,
                    rejectCount: rejectCount,
                    total: approveCount + rejectCount
                )
            }
            .filter { $0.total >= 2 }
            .sorted { $0.total > $1.total }
    }

    // MARK: - Correction Pattern Tracking

    func recordCorrection(merchant: String, fromCategory: String, toCategory: String) {
        let normalized = normalizeMerchant(merchant)
        let lookupKey = "correction:\(normalized)"

        if let idx = entries.firstIndex(where: { $0.key == lookupKey && $0.type == .correctionPattern && $0.value == toCategory }) {
            entries[idx].strength += 1
            entries[idx].updatedAt = Date()
            entries[idx].confidence = computeCorrectionConfidence(entries[idx].strength)
        } else {
            let entry = AIMemoryEntry(
                id: UUID(),
                type: .correctionPattern,
                key: lookupKey,
                value: toCategory,
                confidence: 0.5,
                strength: 1,
                source: .userCorrection,
                merchantRef: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
                categoryRef: toCategory,
                tagRef: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastUsedAt: nil,
                metadata: ["fromCategory": fromCategory]
            )
            entries.append(entry)
        }
        save()
    }

    // MARK: - Preference Management

    var clarificationStyle: ClarificationStyle {
        get {
            guard let entry = entries.first(where: { $0.type == .clarificationStyle }) else {
                return .balanced
            }
            return ClarificationStyle(rawValue: entry.value) ?? .balanced
        }
        set {
            setPreference(type: .clarificationStyle, key: "pref:clarification_style", value: newValue.rawValue)
        }
    }

    var assistantTone: AssistantTone {
        get {
            guard let entry = entries.first(where: { $0.type == .assistantTone }) else {
                return .friendly
            }
            return AssistantTone(rawValue: entry.value) ?? .friendly
        }
        set {
            setPreference(type: .assistantTone, key: "pref:assistant_tone", value: newValue.rawValue)
        }
    }

    var automationLevel: AutomationComfort {
        get {
            guard let entry = entries.first(where: { $0.type == .automationLevel }) else {
                return .moderate
            }
            return AutomationComfort(rawValue: entry.value) ?? .moderate
        }
        set {
            setPreference(type: .automationLevel, key: "pref:automation_level", value: newValue.rawValue)
        }
    }

    var budgetHandling: String {
        get {
            entries.first(where: { $0.type == .budgetHandling })?.value ?? "review_first"
        }
        set {
            setPreference(type: .budgetHandling, key: "pref:budget_handling", value: newValue)
        }
    }

    private func setPreference(type: AIMemoryType, key: String, value: String) {
        if let idx = entries.firstIndex(where: { $0.type == type }) {
            entries[idx].value = value
            entries[idx].updatedAt = Date()
            entries[idx].source = .explicitPreference
        } else {
            let entry = AIMemoryEntry(
                id: UUID(),
                type: type,
                key: key,
                value: value,
                confidence: 1.0,
                strength: 1,
                source: .explicitPreference,
                merchantRef: nil,
                categoryRef: nil,
                tagRef: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastUsedAt: nil,
                metadata: [:]
            )
            entries.append(entry)
        }
        save()
    }

    // MARK: - Query / Retrieval

    func entriesByType(_ type: AIMemoryType) -> [AIMemoryEntry] {
        entries.filter { $0.type == type }
            .sorted { $0.confidence > $1.confidence }
    }

    func correctionEntries() -> [AIMemoryEntry] {
        entries.filter { $0.type == .correctionPattern && $0.isActionable }
            .sorted { $0.strength > $1.strength }
    }

    func allMerchantTags(for merchant: String) -> [AIMemoryEntry] {
        let normalized = normalizeMerchant(merchant)
        let prefix = "tag:\(normalized):"
        return entries.filter { $0.type == .merchantTag && $0.key.hasPrefix(prefix) }
            .sorted { $0.confidence > $1.confidence }
    }

    var countsByType: [AIMemoryType: Int] {
        var counts: [AIMemoryType: Int] = [:]
        for entry in entries {
            counts[entry.type, default: 0] += 1
        }
        return counts
    }

    var totalCount: Int { entries.count }

    // MARK: - Management

    func deleteEntry(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearType(_ type: AIMemoryType) {
        entries.removeAll { $0.type == type }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    func markUsed(_ id: UUID) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].lastUsedAt = Date()
        }
    }

    // MARK: - Helpers

    private func normalizeMerchant(_ note: String) -> String {
        note.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .prefix(3)
            .joined(separator: " ")
    }

    private func computeTagConfidence(_ strength: Int, source: AIMemorySource) -> Double {
        if source == .explicitPreference { return 0.95 }
        switch strength {
        case 1:       return 0.4
        case 2:       return 0.65
        case 3...4:   return 0.8
        default:      return 0.9
        }
    }

    private func computeCorrectionConfidence(_ strength: Int) -> Double {
        switch strength {
        case 1:       return 0.5
        case 2:       return 0.75
        case 3...4:   return 0.85
        default:      return 0.95
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([AIMemoryEntry].self, from: data) {
            entries = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Memory Retrieval Layer

@MainActor
enum AIMemoryRetrieval {

    // MARK: - Merchant Category

    static func suggestCategory(for merchantNote: String) -> MemorySuggestion? {
        // 1. AIMerchantMemory corrections (highest priority)
        if let result = AIMerchantMemory.shared.suggestCategory(for: merchantNote) {
            let profile = AIMerchantMemory.shared.lookup(merchantNote)
            let isCorrected = (profile?.correctionCount ?? 0) > 0
            let explanation = isCorrected
                ? "Based on your correction for \(profile?.displayName ?? merchantNote)"
                : "Learned from your transaction history"

            return MemorySuggestion(
                category: result.category,
                confidence: result.confidence,
                explanation: explanation,
                source: isCorrected ? .userCorrection : .repeatedBehavior
            )
        }

        // 2. Correction patterns from AIMemoryStore
        let normalized = merchantNote.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .prefix(3)
            .joined(separator: " ")
        let correctionKey = "correction:\(normalized)"
        if let correction = AIMemoryStore.shared.entries.first(where: {
            $0.key == correctionKey && $0.type == .correctionPattern && $0.isActionable
        }) {
            return MemorySuggestion(
                category: correction.value,
                confidence: correction.confidence,
                explanation: "You've corrected \"\(correction.displayKey)\" to this category \(correction.strength) time(s)",
                source: .userCorrection
            )
        }

        // 3. AICategorySuggester (keywords)
        if let result = AICategorySuggester.shared.suggestWithConfidence(note: merchantNote) {
            return MemorySuggestion(
                category: result.category,
                confidence: result.confidence,
                explanation: "Matched by category keywords",
                source: .repeatedBehavior
            )
        }

        return nil
    }

    static func suggestTags(for merchantNote: String) -> [TagSuggestion] {
        AIMemoryStore.shared.merchantTags(for: merchantNote).map {
            TagSuggestion(tag: $0.tag, confidence: $0.confidence)
        }
    }

    // MARK: - Approval Patterns

    static func userTendsToApprove(actionType: String) -> Bool? {
        guard let tendency = AIMemoryStore.shared.approvalTendency(for: actionType) else {
            return nil
        }
        guard tendency.total >= 5 else { return nil }
        if tendency.isStrongApprover { return true }
        if tendency.isStrongRejecter { return false }
        return nil
    }

    // MARK: - Preferences

    static var clarificationStyle: ClarificationStyle {
        AIMemoryStore.shared.clarificationStyle
    }

    static var assistantTone: AssistantTone {
        AIMemoryStore.shared.assistantTone
    }

    static var automationLevel: AutomationComfort {
        AIMemoryStore.shared.automationLevel
    }

    // MARK: - Context Generation

    static func contextSummary() -> String {
        var lines: [String] = []
        let store = AIMemoryStore.shared

        let corrections = store.correctionEntries()
        if !corrections.isEmpty {
            lines.append("LEARNED CORRECTIONS:")
            for c in corrections.prefix(8) {
                lines.append("  \(c.displayKey) -> \(c.value) (corrected \(c.strength)x)")
            }
        }

        let tagEntries = store.entriesByType(.merchantTag).filter { $0.isActionable }
        if !tagEntries.isEmpty {
            lines.append("MERCHANT TAGS:")
            for t in tagEntries.prefix(8) {
                lines.append("  \(t.displayKey) -> #\(t.value)")
            }
        }

        let style = store.clarificationStyle
        if style != .balanced {
            lines.append("CLARIFICATION STYLE: \(style.displayName)")
        }

        let tone = store.assistantTone
        if tone != .friendly {
            lines.append("RESPONSE TONE: \(tone.displayName)")
        }

        let automation = store.automationLevel
        if automation != .moderate {
            lines.append("AUTOMATION COMFORT: \(automation.displayName)")
        }

        let tendencies = store.allApprovalTendencies().filter { $0.total >= 5 }
        if !tendencies.isEmpty {
            lines.append("APPROVAL PATTERNS:")
            for t in tendencies.prefix(5) {
                let label = t.isStrongApprover ? "usually approves" : (t.isStrongRejecter ? "usually rejects" : "\(Int(t.approveRate * 100))% approve")
                lines.append("  \(t.actionType): \(label) (\(t.total) decisions)")
            }
        }

        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    static func explain(suggestion: MemorySuggestion) -> String {
        switch suggestion.source {
        case .userCorrection:
            return suggestion.explanation
        case .repeatedBehavior:
            return suggestion.explanation
        case .explicitPreference:
            return suggestion.explanation
        case .approvalHistory:
            return suggestion.explanation
        case .ingestionFeedback:
            return suggestion.explanation
        }
    }
}

struct MemorySuggestion {
    let category: String
    let confidence: Double
    let explanation: String
    let source: AIMemorySource
}

struct TagSuggestion {
    let tag: String
    let confidence: Double
}
