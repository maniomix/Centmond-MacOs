import Foundation
import SwiftData
import Supabase

// ============================================================
// MARK: - BudgetCategoryRepository (macOS)
// ============================================================
// Adapter between SwiftData `BudgetCategory` @Model and the
// cloud `categories` table.
//
// All BudgetCategory rows are treated as **custom categories**
// from the cloud's perspective (`is_custom = true`). iOS's
// built-in Category enum (groceries, rent, …) lives separately
// in iOS-only code; macOS users always see their own
// BudgetCategory entries.
//
// Field mapping:
//   id           ↔ id
//   name         ↔ name
//   icon         ↔ icon
//   colorHex     ↔ color_hex
//   sortOrder    ↔ sort_order
//   updatedAt    ↔ updated_at (server-managed)
//
// macOS-only fields kept local:
//   budgetAmount, isExpenseCategory, parentCategory,
//   subcategories, transactions, recurrings, splits
// ============================================================

@MainActor
final class BudgetCategoryRepository {

    static let shared = BudgetCategoryRepository()
    private init() {}

    private var client: SupabaseClient { CloudClient.shared.client }

    // MARK: - Wire DTO

    private struct Row: Codable {
        let id: String
        let name: String
        let icon: String?
        let color_hex: String?
        let sort_order: Int
        let kind: String
        let is_custom: Bool
        let updated_at: String?
    }

    private struct UpsertRow: Encodable {
        let id: String
        let name: String
        let icon: String?
        let color_hex: String
        let sort_order: Int
        let kind: String
        let is_custom: Bool
    }

    // MARK: - Pull

    /// Pull all custom categories and reconcile by id. Locals missing
    /// from cloud are pruned IFF their `updatedAt < cutoff`. macOS
    /// treats every local BudgetCategory as `is_custom = true`, so
    /// the prune set covers all locals — no built-in/custom split.
    func pullAll(into context: ModelContext, cutoff: Date) async throws {
        let rows: [Row] = try await client
            .from("categories")
            .select("id, name, icon, color_hex, sort_order, kind, is_custom, updated_at")
            .eq("is_custom", value: true)
            .order("sort_order", ascending: true)
            .execute()
            .value
        SecureLogger.info("Pulled \(rows.count) categories")

        let existing = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
        var byId: [UUID: BudgetCategory] = CloudHelpers.indexById(existing) { $0.id }

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

        // Built-ins live local-only; cloud has no copy of them, so the
        // "missing from cloud" predicate would always be true and the
        // prune would wipe them every cycle. Exclude them explicitly.
        let toPrune = existing.filter { cat in
            !cat.isBuiltIn && !seenIds.contains(cat.id) && cat.updatedAt < cutoff
        }
        if !toPrune.isEmpty {
            CloudSyncCoordinator.shared.runWhilePruning {
                for cat in toPrune { context.delete(cat) }
            }
            SecureLogger.info("Pruned \(toPrune.count) categor(y/ies) absent from cloud")
        }

        try? context.save()
    }

    // MARK: - Push

    func upsert(_ cat: BudgetCategory) async throws {
        // Built-ins (Groceries, Rent, …) are seeded locally and iOS has
        // its own hardcoded copy. Skip them so we don't double-up.
        if cat.isBuiltIn { return }
        try await client
            .from("categories")
            .upsert(makeRow(from: cat), onConflict: "id")
            .execute()
        SecureLogger.debug("Upserted category")
    }

    func upsertMany(_ cats: [BudgetCategory]) async throws {
        let syncable = cats.filter { !$0.isBuiltIn }
        guard !syncable.isEmpty else { return }
        let rows = syncable.map(makeRow(from:))
        try await client
            .from("categories")
            .upsert(rows, onConflict: "id")
            .execute()
        SecureLogger.info("Upserted \(rows.count) categories (\(cats.count - syncable.count) built-in skipped)")
    }

    // MARK: - Delete

    func delete(id: UUID) async throws {
        struct DeletedRow: Codable { let id: String }
        let deleted: [DeletedRow] = try await client
            .from("categories")
            .delete()
            .eq("id", value: id.uuidString)
            .select("id")
            .execute()
            .value
        SecureLogger.info("Deleted category (\(deleted.count) row(s) removed)")
    }

    // MARK: - Mapping

    private func makeRow(from cat: BudgetCategory) -> UpsertRow {
        UpsertRow(
            id: cat.id.uuidString,
            name: cat.name,
            icon: cat.icon,
            color_hex: cat.colorHex,
            sort_order: cat.sortOrder,
            kind: cat.isExpenseCategory ? "expense" : "income",
            is_custom: true
        )
    }

    private func make(from row: Row) -> BudgetCategory? {
        guard let id = CloudHelpers.uuid(row.id) else { return nil }
        let cat = BudgetCategory(
            name: row.name,
            icon: row.icon ?? "folder.fill",
            colorHex: row.color_hex ?? "3B82F6",
            isExpenseCategory: row.kind != "income",
            sortOrder: row.sort_order
        )
        cat.id = id
        return cat
    }

    private func apply(_ row: Row, to model: BudgetCategory) {
        model.name = row.name
        if let icon = row.icon { model.icon = icon }
        if let color = row.color_hex { model.colorHex = color }
        model.sortOrder = row.sort_order
        model.isExpenseCategory = row.kind != "income"
    }
}
