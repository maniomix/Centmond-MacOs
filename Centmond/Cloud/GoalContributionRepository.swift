import Foundation
import SwiftData
import Supabase

// ============================================================
// MARK: - GoalContributionRepository (macOS)
// ============================================================
// SwiftData `GoalContribution` ↔ cloud `goal_contributions`.
//
// Kind mapping (macOS GoalContributionKind ↔ cloud source CHECK):
//   .manual       → 'manual'
//   .fromIncome   → 'transaction'
//   .fromTransfer → 'transfer'
//   .autoRule     → 'allocation_rule'
//
// macOS GoalContribution.date → cloud `created_at` (server-managed
// on insert; we send a hint and accept the server's value back on
// pull). macOS `createdAt` field is kept in sync with the cloud
// `created_at` so this round-trips cleanly.
// ============================================================

@MainActor
final class GoalContributionRepository {

    static let shared = GoalContributionRepository()
    private init() {}

    private var client: SupabaseClient { CloudClient.shared.client }

    // MARK: - Wire DTOs

    private struct Row: Codable {
        let id: String
        let goal_id: String?
        let amount: Int
        let note: String?
        let source: String
        let linked_transaction_id: String?
        let created_at: String?
    }

    private struct UpsertRow: Encodable {
        let id: String
        let goal_id: String
        let amount: Int
        let note: String?
        let source: String
        let linked_transaction_id: String?
    }

    // MARK: - Pull

    /// Pull all rows and reconcile by id. Locals missing from cloud
    /// are pruned IFF their `createdAt < cutoff`. See AccountRepository
    /// for the gating rationale.
    func pullAll(into context: ModelContext, cutoff: Date) async throws {
        let rows: [Row] = try await client
            .from("goal_contributions")
            .select("id, goal_id, amount, note, source, linked_transaction_id, created_at")
            .order("created_at", ascending: false)
            .execute()
            .value
        SecureLogger.info("Pulled \(rows.count) goal contributions")

        let existing = (try? context.fetch(FetchDescriptor<GoalContribution>())) ?? []
        var byId: [UUID: GoalContribution] = CloudHelpers.indexById(existing) { $0.id }

        var seenIds = Set<UUID>()
        for row in rows {
            guard let id = CloudHelpers.uuid(row.id) else { continue }
            seenIds.insert(id)
            if let model = byId[id] {
                apply(row, to: model, in: context)
            } else if let new = make(from: row, in: context) {
                context.insert(new)
                byId[id] = new
            }
        }

        let toPrune = existing.filter { c in
            !seenIds.contains(c.id) && c.createdAt < cutoff
        }
        if !toPrune.isEmpty {
            CloudSyncCoordinator.shared.runWhilePruning {
                for c in toPrune { context.delete(c) }
            }
            SecureLogger.info("Pruned \(toPrune.count) goal contribution(s) absent from cloud")
        }

        try? context.save()
    }

    // MARK: - Push

    func upsert(_ c: GoalContribution) async throws {
        guard let row = makeRow(from: c) else {
            SecureLogger.warning("Skipping orphan contribution (no goal)")
            return
        }
        try await client
            .from("goal_contributions")
            .upsert(row, onConflict: "id")
            .execute()
        SecureLogger.debug("Upserted goal contribution")
    }

    func upsertMany(_ contributions: [GoalContribution]) async throws {
        let rows = contributions.compactMap(makeRow(from:))
        guard !rows.isEmpty else { return }
        try await client
            .from("goal_contributions")
            .upsert(rows, onConflict: "id")
            .execute()
        SecureLogger.info("Upserted \(rows.count) goal contributions")
    }

    /// Resurrection-safe push. See AccountRepository.pushAllResurrectionSafe
    /// for the design rationale. Contributions have `createdAt` only
    /// (no updatedAt), so we use that as the freshness gate.
    func pushAllResurrectionSafe(_ contributions: [GoalContribution], cutoff: Date) async throws {
        guard !contributions.isEmpty else { return }
        let cloudIds = try await CloudSyncCoordinator.shared.fetchCloudIds(table: "goal_contributions")
        let safe = contributions.filter { c in
            cloudIds.contains(c.id) || c.createdAt > cutoff
        }
        let skipped = contributions.count - safe.count
        if skipped > 0 {
            SecureLogger.info("Skipped \(skipped) goal contribution(s) deleted on another device")
        }
        if !safe.isEmpty {
            try await upsertMany(safe)
        }
    }

    // MARK: - Delete

    func delete(id: UUID) async throws {
        struct DR: Codable { let id: String }
        let _: [DR] = try await client
            .from("goal_contributions")
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
                .from("goal_contributions")
                .delete()
                .in("id", values: batch.map(\.uuidString))
                .select("id")
                .execute()
                .value
            await Task.yield()
        }
    }

    // MARK: - Mapping

    private func makeRow(from c: GoalContribution) -> UpsertRow? {
        guard let goalId = c.goal?.id else { return nil }
        return UpsertRow(
            id: c.id.uuidString,
            goal_id: goalId.uuidString,
            amount: CloudHelpers.toCents(c.amount),
            note: c.note,
            source: encodeKind(c.kind),
            linked_transaction_id: c.sourceTransactionID?.uuidString
        )
    }

    private func make(from row: Row, in context: ModelContext) -> GoalContribution? {
        guard let id = CloudHelpers.uuid(row.id) else { return nil }
        let goal = lookupGoal(id: CloudHelpers.uuid(row.goal_id), in: context)
        guard let goal else { return nil }  // orphan; skip until parent is pulled

        let c = GoalContribution(
            amount: CloudHelpers.toDecimal(cents: row.amount),
            date: CloudHelpers.parseDate(row.created_at) ?? .now,
            kind: decodeKind(row.source),
            note: row.note,
            sourceTransactionID: CloudHelpers.uuid(row.linked_transaction_id),
            goal: goal
        )
        c.id = id
        if let createdAt = CloudHelpers.parseDate(row.created_at) {
            c.createdAt = createdAt
        }
        return c
    }

    private func apply(_ row: Row, to model: GoalContribution, in context: ModelContext) {
        model.amount = CloudHelpers.toDecimal(cents: row.amount)
        model.note = row.note
        model.kind = decodeKind(row.source)
        model.sourceTransactionID = CloudHelpers.uuid(row.linked_transaction_id)
        if let goalId = CloudHelpers.uuid(row.goal_id) {
            if model.goal?.id != goalId {
                model.goal = lookupGoal(id: goalId, in: context)
            }
        }
        if let createdAt = CloudHelpers.parseDate(row.created_at) {
            model.date = createdAt
            model.createdAt = createdAt
        }
    }

    // MARK: - Kind mapping

    private func encodeKind(_ k: GoalContributionKind) -> String {
        switch k {
        case .manual:       return "manual"
        case .fromIncome:   return "transaction"
        case .fromTransfer: return "transfer"
        case .autoRule:     return "allocation_rule"
        }
    }

    private func decodeKind(_ s: String) -> GoalContributionKind {
        switch s {
        case "transaction":      return .fromIncome
        case "transfer":         return .fromTransfer
        case "allocation_rule":  return .autoRule
        default:                 return .manual
        }
    }

    // MARK: - Local lookup

    private func lookupGoal(id: UUID?, in context: ModelContext) -> Goal? {
        guard let id else { return nil }
        let predicate = #Predicate<Goal> { $0.id == id }
        let descriptor = FetchDescriptor<Goal>(predicate: predicate)
        return (try? context.fetch(descriptor))?.first
    }
}
