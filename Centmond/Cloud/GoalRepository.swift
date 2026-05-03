import Foundation
import SwiftData
import Supabase

// ============================================================
// MARK: - GoalRepository (macOS)
// ============================================================
// SwiftData `Goal` ↔ cloud `goals` table.
//
// Status mapping (macOS enum ↔ cloud bool flags):
//   .active     → is_archived=false, is_completed=false, paused_at=nil
//   .paused     → is_archived=false, is_completed=false, paused_at=now
//   .completed  → is_archived=false, is_completed=true,  paused_at=nil
//   .archived   → is_archived=true,  is_completed=false, paused_at=nil
//
// Decimal amounts ↔ bigint cents via CloudHelpers.
// macOS-only fields stay local: contributions, householdMember,
// monthlyContribution.
// Cloud-only fields default on push: type='custom', currency='EUR',
// original_target_amount = current target at push time.
// ============================================================

@MainActor
final class GoalRepository {

    static let shared = GoalRepository()
    private init() {}

    private var client: SupabaseClient { CloudClient.shared.client }

    // MARK: - Wire DTOs

    private struct Row: Codable {
        let id: String
        let name: String
        let icon: String?
        let target_amount: Int
        let current_amount: Int
        let target_date: String?     // ISO date YYYY-MM-DD
        let priority: Int
        let is_archived: Bool
        let is_completed: Bool
        let paused_at: String?
        let updated_at: String?
    }

    private struct UpsertRow: Encodable {
        let id: String
        let name: String
        let icon: String
        let target_amount: Int
        let current_amount: Int
        let original_target_amount: Int
        let target_date: String?
        let priority: Int
        let is_archived: Bool
        let is_completed: Bool
        let paused_at: String?
        let type: String           // 'custom' for now; macOS has no type enum
        let currency: String       // 'EUR' default
    }

    // MARK: - Pull

    /// Pull all rows and reconcile by id. Locals missing from cloud
    /// are pruned IFF their `updatedAt < cutoff`. Goal is dirty-only
    /// on push, so a freshly-edited local has `updatedAt > cutoff`
    /// and is protected from prune until its push lands.
    func pullAll(into context: ModelContext, cutoff: Date) async throws {
        let rows: [Row] = try await client
            .from("goals")
            .select("id, name, icon, target_amount, current_amount, target_date, priority, is_archived, is_completed, paused_at, updated_at")
            .order("priority", ascending: false)
            .execute()
            .value
        SecureLogger.info("Pulled \(rows.count) goals")

        let existing = (try? context.fetch(FetchDescriptor<Goal>())) ?? []
        var byId: [UUID: Goal] = CloudHelpers.indexById(existing) { $0.id }

        var seenIds = Set<UUID>()
        for row in rows {
            guard let id = CloudHelpers.uuid(row.id) else { continue }
            seenIds.insert(id)
            if let model = byId[id] {
                apply(row, to: model)
            } else if let new = make(from: row) {
                context.insert(new)
                byId[id] = new
            }
        }

        let toPrune = existing.filter { goal in
            !seenIds.contains(goal.id) && goal.updatedAt < cutoff
        }
        if !toPrune.isEmpty {
            CloudSyncCoordinator.shared.runWhilePruning {
                for goal in toPrune { context.delete(goal) }
            }
            SecureLogger.info("Pruned \(toPrune.count) goal(s) absent from cloud")
        }

        try? context.save()
    }

    // MARK: - Push

    func upsert(_ goal: Goal) async throws {
        try await client
            .from("goals")
            .upsert(makeRow(from: goal), onConflict: "id")
            .execute()
        SecureLogger.debug("Upserted goal")
    }

    func upsertMany(_ goals: [Goal]) async throws {
        guard !goals.isEmpty else { return }
        let rows = goals.map(makeRow(from:))
        try await client
            .from("goals")
            .upsert(rows, onConflict: "id")
            .execute()
        SecureLogger.info("Upserted \(rows.count) goals")
    }

    // MARK: - Delete

    func delete(id: UUID) async throws {
        struct DR: Codable { let id: String }
        let _: [DR] = try await client
            .from("goals")
            .delete()
            .eq("id", value: id.uuidString)
            .select("id")
            .execute()
            .value
    }

    func deleteMany(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        struct DR: Codable { let id: String }
        // Chunk by 100 — see TransactionRepository.deleteMany.
        let chunkSize = 100
        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let batch = Array(ids[start ..< min(start + chunkSize, ids.count)])
            let _: [DR] = try await client
                .from("goals")
                .delete()
                .in("id", values: batch.map(\.uuidString))
                .select("id")
                .execute()
                .value
            await Task.yield()
        }
    }

    // MARK: - Mapping

    private static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private func makeRow(from g: Goal) -> UpsertRow {
        let (archived, completed, paused) = encodeStatus(g.status)
        return UpsertRow(
            id: g.id.uuidString,
            name: g.name,
            icon: g.icon,
            target_amount: CloudHelpers.toCents(g.targetAmount),
            current_amount: CloudHelpers.toCents(g.currentAmount),
            original_target_amount: CloudHelpers.toCents(g.targetAmount),
            target_date: g.targetDate.map { Self.dateOnly.string(from: $0) },
            priority: g.priority,
            is_archived: archived,
            is_completed: completed,
            paused_at: paused ? CloudHelpers.isoString(.now) : nil,
            type: "custom",
            currency: "EUR"
        )
    }

    private func make(from row: Row) -> Goal? {
        guard let id = CloudHelpers.uuid(row.id) else { return nil }
        let g = Goal(
            name: row.name,
            icon: row.icon ?? "target",
            targetAmount: CloudHelpers.toDecimal(cents: row.target_amount),
            currentAmount: CloudHelpers.toDecimal(cents: row.current_amount),
            targetDate: row.target_date.flatMap(Self.dateOnly.date(from:)),
            status: decodeStatus(archived: row.is_archived, completed: row.is_completed, pausedAt: row.paused_at),
            priority: row.priority
        )
        g.id = id
        if let last = CloudHelpers.parseDate(row.updated_at) { g.updatedAt = last }
        return g
    }

    private func apply(_ row: Row, to model: Goal) {
        model.name = row.name
        if let icon = row.icon { model.icon = icon }
        model.targetAmount = CloudHelpers.toDecimal(cents: row.target_amount)
        model.currentAmount = CloudHelpers.toDecimal(cents: row.current_amount)
        model.targetDate = row.target_date.flatMap(Self.dateOnly.date(from:))
        model.priority = row.priority
        model.status = decodeStatus(archived: row.is_archived, completed: row.is_completed, pausedAt: row.paused_at)
        if let last = CloudHelpers.parseDate(row.updated_at) { model.updatedAt = last }
    }

    // MARK: - Status flag mapping

    private func encodeStatus(_ status: GoalStatus) -> (archived: Bool, completed: Bool, paused: Bool) {
        switch status {
        case .active:    return (false, false, false)
        case .paused:    return (false, false, true)
        case .completed: return (false, true,  false)
        case .archived:  return (true,  false, false)
        }
    }

    private func decodeStatus(archived: Bool, completed: Bool, pausedAt: String?) -> GoalStatus {
        if archived { return .archived }
        if completed { return .completed }
        if pausedAt != nil { return .paused }
        return .active
    }
}
