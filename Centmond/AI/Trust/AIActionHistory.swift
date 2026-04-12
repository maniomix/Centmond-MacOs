import Foundation
import SwiftData

// ============================================================
// MARK: - AI Action History
// ============================================================
//
// Records every AI action with:
//   - what was proposed and executed
//   - trust decision (level, reason, risk)
//   - explanation of why the AI did it
//   - action grouping for multi-action requests
//
// Persisted to UserDefaults.
//
// macOS Centmond: @Observable instead of ObservableObject,
// amounts in dollars (Double) instead of cents (Int),
// no _LegacyUndoData — simplified snapshot system,
// undo via ModelContext instead of inout Store.
//
// ============================================================

// MARK: - Action Record

struct AIActionRecord: Identifiable, Codable {
    let id: UUID
    let action: CodableAction
    let executedAt: Date

    let summary: String
    let explanation: String
    let trustLevel: String
    let trustReason: String
    let riskScore: Double
    let riskLevel: String
    let intentType: String
    let confidence: Double

    let outcome: ActionOutcome
    let isUndoable: Bool
    var isUndone: Bool = false
    var undoneAt: Date? = nil

    let groupId: UUID?
    let groupLabel: String?

    struct CodableAction: Codable {
        let id: UUID
        let type: String
        let amount: Double?
        let category: String?
        let note: String?
        let targetId: String?

        init(from action: AIAction) {
            self.id = action.id
            self.type = action.type.rawValue
            self.amount = action.params.amount ?? action.params.budgetAmount ??
                          action.params.goalTarget ?? action.params.subscriptionAmount ??
                          action.params.contributionAmount
            self.category = action.params.category ?? action.params.budgetCategory
            self.note = action.params.note ?? action.params.goalName ??
                        action.params.subscriptionName ?? action.params.recurringName
            self.targetId = action.params.transactionId
        }
    }
}

// MARK: - Action Outcome

enum ActionOutcome: String, Codable {
    case executed
    case failed
    case blocked
    case pending
    case confirmed
    case rejected
    case undone
}

// MARK: - Action Group

struct AIActionRecordGroup: Identifiable {
    let id: UUID
    let label: String
    let timestamp: Date
    let records: [AIActionRecord]

    var count: Int { records.count }
    var hasUndoable: Bool { records.contains { $0.isUndoable && !$0.isUndone } }
}

// MARK: - Explanation Builder

enum AIExplanationBuilder {

    static func explain(
        action: AIAction,
        trustDecision: TrustDecision?,
        intentType: String,
        isAutoExecuted: Bool
    ) -> String {
        let actionLabel = action.type.rawValue.replacingOccurrences(of: "_", with: " ")

        if let decision = trustDecision, decision.level == .neverAuto {
            return decision.blockMessage ?? "Blocked by trust policy"
        }

        if let decision = trustDecision {
            if decision.preferenceInfluenced {
                switch decision.level {
                case .auto:
                    return "User preference allows auto-execution for this low-risk \(actionLabel)"
                case .confirm:
                    return "User preference requires confirmation for \(actionLabel)"
                case .neverAuto:
                    return decision.blockMessage ?? "Blocked by user trust preferences"
                }
            }
            if decision.riskScore.level >= .high {
                return "High risk (\(decision.riskScore.level.rawValue)) — requires careful review"
            }
        }

        if isAutoExecuted {
            switch action.type {
            case .analyze, .compare, .forecast, .advice:
                return "Read-only analysis — no data changed"
            case .editTransaction:
                let p = action.params
                if p.category != nil && p.amount == nil && p.date == nil {
                    return "Matched your usual merchant-to-category pattern"
                }
                if p.note != nil && p.amount == nil && p.category == nil {
                    return "Low-risk note/tag edit auto-applied"
                }
                return "Auto-applied based on mode and risk level"
            default:
                return "Auto-applied based on mode and risk level"
            }
        }

        return "Executed after user confirmation"
    }
}

// MARK: - Action History Manager

@MainActor @Observable
final class AIActionHistory {
    static let shared = AIActionHistory()

    private(set) var records: [AIActionRecord] = []

    private let maxRecords = 200
    private let storageKey = "ai.actionHistory.v2"

    private init() {
        load()
    }

    // MARK: - Recording

    func record(
        action: AIAction,
        result: AIActionExecutor.ExecutionResult,
        trustDecision: TrustDecision?,
        classification: IntentClassification?,
        groupId: UUID?,
        groupLabel: String?,
        isAutoExecuted: Bool
    ) {
        let explanation = AIExplanationBuilder.explain(
            action: action,
            trustDecision: trustDecision,
            intentType: classification?.intentType.rawValue ?? "unknown",
            isAutoExecuted: isAutoExecuted
        )

        let entry = AIActionRecord(
            id: UUID(),
            action: AIActionRecord.CodableAction(from: action),
            executedAt: Date(),
            summary: result.summary,
            explanation: explanation,
            trustLevel: trustDecision?.level.rawValue ?? "confirm",
            trustReason: trustDecision?.reason ?? "",
            riskScore: trustDecision?.riskScore.value ?? 0,
            riskLevel: trustDecision?.riskScore.level.rawValue ?? "none",
            intentType: classification?.intentType.rawValue ?? "unknown",
            confidence: classification?.confidence ?? 0,
            outcome: result.success ? (isAutoExecuted ? .executed : .confirmed) : .failed,
            isUndoable: result.success,
            groupId: groupId,
            groupLabel: groupLabel
        )

        records.insert(entry, at: 0)
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        save()
    }

    func recordBlocked(
        action: AIAction,
        trustDecision: TrustDecision,
        classification: IntentClassification?,
        groupId: UUID?,
        groupLabel: String?
    ) {
        let explanation = AIExplanationBuilder.explain(
            action: action,
            trustDecision: trustDecision,
            intentType: classification?.intentType.rawValue ?? "unknown",
            isAutoExecuted: false
        )

        let entry = AIActionRecord(
            id: UUID(),
            action: AIActionRecord.CodableAction(from: action),
            executedAt: Date(),
            summary: trustDecision.blockMessage ?? "Action blocked",
            explanation: explanation,
            trustLevel: trustDecision.level.rawValue,
            trustReason: trustDecision.reason,
            riskScore: trustDecision.riskScore.value,
            riskLevel: trustDecision.riskScore.level.rawValue,
            intentType: classification?.intentType.rawValue ?? "unknown",
            confidence: classification?.confidence ?? 0,
            outcome: .blocked,
            isUndoable: false,
            groupId: groupId,
            groupLabel: groupLabel
        )

        records.insert(entry, at: 0)
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        save()
    }

    // MARK: - Queries

    func recent(_ count: Int = 20) -> [AIActionRecord] {
        Array(records.prefix(count))
    }

    func groupedRecords() -> [AIActionRecordGroup] {
        var groups: [UUID: [AIActionRecord]] = [:]
        var ungrouped: [AIActionRecord] = []
        var groupLabels: [UUID: String] = [:]
        var groupTimestamps: [UUID: Date] = [:]

        for record in records {
            if let gid = record.groupId {
                groups[gid, default: []].append(record)
                if let label = record.groupLabel { groupLabels[gid] = label }
                if groupTimestamps[gid] == nil { groupTimestamps[gid] = record.executedAt }
            } else {
                ungrouped.append(record)
            }
        }

        var result: [AIActionRecordGroup] = []
        for (gid, recs) in groups {
            result.append(AIActionRecordGroup(
                id: gid,
                label: groupLabels[gid] ?? "Grouped actions",
                timestamp: groupTimestamps[gid] ?? Date(),
                records: recs
            ))
        }
        for record in ungrouped {
            result.append(AIActionRecordGroup(
                id: record.id,
                label: record.summary,
                timestamp: record.executedAt,
                records: [record]
            ))
        }

        return result.sorted { $0.timestamp > $1.timestamp }
    }

    var todayCount: Int {
        records.filter { Calendar.current.isDateInToday($0.executedAt) }.count
    }

    var topActionType: String {
        var counts: [String: Int] = [:]
        for record in records {
            counts[record.action.type, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
            .replacingOccurrences(of: "_", with: " ")
            .capitalized ?? "—"
    }

    var undoneCount: Int {
        records.filter(\.isUndone).count
    }

    var blockedCount: Int {
        records.filter { $0.outcome == .blocked }.count
    }

    // MARK: - Management

    func clear() {
        records.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([AIActionRecord].self, from: data) {
            records = saved
        }
    }
}
