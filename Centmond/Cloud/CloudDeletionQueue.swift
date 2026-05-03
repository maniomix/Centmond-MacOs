import Foundation

// ============================================================
// MARK: - CloudDeletionQueue (macOS)
// ============================================================
// SwiftData doesn't keep tombstones — once you `context.delete(x)`,
// the row is gone with no record that it ever existed. The cloud
// still has the row, though, so we need a separate queue of
// pending deletions to push.
//
// Pattern (call from any UI delete site):
//
//   CloudDeletionQueue.shared.mark(.transactions, id: tx.id)
//   context.delete(tx)
//   try? context.save()
//
// The sync coordinator drains the queue on the next push:
//   - On success → call `clear(.transactions, ids: [...])`
//   - On failure → leave the entries in place (next push retries)
//
// Persisted to UserDefaults so a crash mid-sync doesn't lose
// the deletion intent. Same role as iOS's
// `Store.deletedTransactionIds`.
// ============================================================

enum CloudTable: String, Codable, CaseIterable {
    case transactions
    case accounts
    case categories
    case goals
    case goalContributions = "goal_contributions"
    case subscriptions
    case monthlyBudgets = "monthly_budgets"
    case monthlyCategoryBudgets = "monthly_category_budgets"
    /// AI chat sessions. Cloud FK cascade handles child messages, so
    /// `ChatMessageRecord` deletions intentionally do NOT map to a
    /// CloudTable case — the willSave hook skips them.
    case aiChatSessions = "ai_chat_sessions"
}

@MainActor
final class CloudDeletionQueue {

    static let shared = CloudDeletionQueue()

    private let key = "centmond.cloudDeletionQueue.v1"
    private var entries: [Entry]

    private struct Entry: Codable, Hashable {
        let table: String        // CloudTable.rawValue
        let id: String           // UUID string
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    // MARK: - Mutate

    /// Mark a row for cloud deletion. Idempotent — no-op if already
    /// queued. Persists immediately so a crash before the next push
    /// doesn't lose the intent.
    func mark(_ table: CloudTable, id: UUID) {
        let entry = Entry(table: table.rawValue, id: id.uuidString)
        guard !entries.contains(entry) else { return }
        entries.append(entry)
        persist()
    }

    /// Remove successfully-deleted ids for a given table. Called by
    /// the sync coordinator after the cloud DELETE completes.
    func clear(_ table: CloudTable, ids: [UUID]) {
        let removed = Set(ids.map(\.uuidString))
        entries.removeAll { $0.table == table.rawValue && removed.contains($0.id) }
        persist()
    }

    // MARK: - Drain

    /// Returns the pending UUIDs for a single table.
    func pending(_ table: CloudTable) -> [UUID] {
        entries
            .filter { $0.table == table.rawValue }
            .compactMap { UUID(uuidString: $0.id) }
    }

    /// All pending entries, grouped by table. Useful for the sync
    /// coordinator's drain loop.
    func grouped() -> [CloudTable: [UUID]] {
        var out: [CloudTable: [UUID]] = [:]
        for entry in entries {
            guard let table = CloudTable(rawValue: entry.table),
                  let id = UUID(uuidString: entry.id) else { continue }
            out[table, default: []].append(id)
        }
        return out
    }

    var isEmpty: Bool { entries.isEmpty }

    // MARK: - Persist

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
