import Foundation
import SwiftData
import Supabase

// ============================================================
// MARK: - BudgetRepository (macOS)
// ============================================================
// Two related entities, one repo:
//
//   MonthlyTotalBudget  ↔ monthly_budgets       (total per month)
//   MonthlyBudget       ↔ monthly_category_budgets (per-category caps)
//
// Cloud schema uses `month` text as YYYY-MM. macOS models use
// integer (year, month) — convert on the wire.
//
// Cloud `total_amount` / `amount` are bigint cents; macOS uses
// Decimal. Convert via CloudHelpers.
//
// macOS uses UUID `categoryID` to reference BudgetCategory.
// Cloud uses `category_key` text. macOS pushes the UUID-as-string
// (matches the convention TransactionRepository uses).
// ============================================================

@MainActor
final class BudgetRepository {

    static let shared = BudgetRepository()
    private init() {}

    private var client: SupabaseClient { CloudClient.shared.client }

    // MARK: - Wire DTOs

    private struct TotalRow: Codable {
        let id: String
        let month: String
        let total_amount: Int
    }

    private struct CategoryRow: Codable {
        let id: String
        let month: String
        let category_key: String
        let amount: Int
    }

    private struct UpsertTotal: Encodable {
        let id: String
        let month: String
        let total_amount: Int
    }

    private struct UpsertCategory: Encodable {
        let id: String
        let month: String
        let category_key: String
        let amount: Int
    }

    // MARK: - Pull (totals)

    func pullAllTotals(into context: ModelContext) async throws {
        let rows: [TotalRow] = try await client
            .from("monthly_budgets")
            .select("id, month, total_amount")
            .execute()
            .value
        SecureLogger.info("Pulled \(rows.count) monthly total budget rows")

        let existing = (try? context.fetch(FetchDescriptor<MonthlyTotalBudget>())) ?? []
        var byMonthKey: [String: MonthlyTotalBudget] = [:]
        for m in existing {
            byMonthKey[Self.monthKey(year: m.year, month: m.month)] = m
        }

        for row in rows {
            guard let (year, month) = Self.parseMonthKey(row.month) else { continue }
            let key = Self.monthKey(year: year, month: month)
            let amount = CloudHelpers.toDecimal(cents: row.total_amount)
            if let model = byMonthKey[key] {
                model.amount = amount
            } else {
                let new = MonthlyTotalBudget(year: year, month: month, amount: amount)
                if let id = CloudHelpers.uuid(row.id) { new.id = id }
                context.insert(new)
                byMonthKey[key] = new
            }
        }
        try? context.save()
    }

    // MARK: - Pull (per-category)

    func pullAllCategoryBudgets(into context: ModelContext) async throws {
        let rows: [CategoryRow] = try await client
            .from("monthly_category_budgets")
            .select("id, month, category_key, amount")
            .execute()
            .value
        SecureLogger.info("Pulled \(rows.count) monthly category budget rows")

        let existing = (try? context.fetch(FetchDescriptor<MonthlyBudget>())) ?? []
        var byKey: [String: MonthlyBudget] = [:]
        for m in existing {
            byKey[Self.compositeKey(year: m.year, month: m.month, categoryID: m.categoryID)] = m
        }

        // Cloud `category_key` is a storage_key string ("groceries",
        // "custom:Coffee") shared with iOS. Resolve to a local
        // BudgetCategory.id by storageKey lookup. Skip rows whose
        // key doesn't match any local category — that means the
        // category hasn't synced yet locally; the next pull cycle
        // will retry once it lands.
        let allCategories = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
        let categoryByStorageKey: [String: BudgetCategory] = Dictionary(
            allCategories.map { ($0.effectiveStorageKey, $0) },
            uniquingKeysWith: { _, last in last }
        )

        for row in rows {
            guard let (year, month) = Self.parseMonthKey(row.month) else { continue }
            guard let category = categoryByStorageKey[row.category_key] else {
                SecureLogger.debug("Skipping budget row for unknown category storage_key: \(row.category_key)")
                continue
            }
            let categoryID = category.id
            let key = Self.compositeKey(year: year, month: month, categoryID: categoryID)
            let amount = CloudHelpers.toDecimal(cents: row.amount)
            if let model = byKey[key] {
                model.amount = amount
            } else {
                let new = MonthlyBudget(categoryID: categoryID, year: year, month: month, amount: amount)
                if let id = CloudHelpers.uuid(row.id) { new.id = id }
                context.insert(new)
                byKey[key] = new
            }
        }
        try? context.save()
    }

    // MARK: - Push

    func upsertTotal(_ b: MonthlyTotalBudget) async throws {
        let row = UpsertTotal(
            id: b.id.uuidString,
            month: Self.monthKey(year: b.year, month: b.month),
            total_amount: CloudHelpers.toCents(b.amount)
        )
        try await client
            .from("monthly_budgets")
            .upsert(row, onConflict: "id")
            .execute()
    }

    func upsertManyTotals(_ totals: [MonthlyTotalBudget]) async throws {
        guard !totals.isEmpty else { return }
        let rows = totals.map { b in
            UpsertTotal(
                id: b.id.uuidString,
                month: Self.monthKey(year: b.year, month: b.month),
                total_amount: CloudHelpers.toCents(b.amount)
            )
        }
        try await client
            .from("monthly_budgets")
            .upsert(rows, onConflict: "id")
            .execute()
        SecureLogger.info("Upserted \(rows.count) monthly total budgets")
    }

    func upsertCategory(_ b: MonthlyBudget, in context: ModelContext) async throws {
        guard let storageKey = lookupStorageKey(for: b.categoryID, in: context) else {
            SecureLogger.warning("Skipping category-budget push — no local category for id \(b.categoryID)")
            return
        }
        let row = UpsertCategory(
            id: b.id.uuidString,
            month: Self.monthKey(year: b.year, month: b.month),
            category_key: storageKey,
            amount: CloudHelpers.toCents(b.amount)
        )
        try await client
            .from("monthly_category_budgets")
            .upsert(row, onConflict: "id")
            .execute()
    }

    func upsertManyCategoryBudgets(_ items: [MonthlyBudget], in context: ModelContext) async throws {
        guard !items.isEmpty else { return }
        // Pre-build a categoryID → storageKey map so we don't hit
        // SwiftData per item. Skip budgets whose category isn't in
        // the local store yet; the push will retry on the next cycle.
        let allCategories = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
        let storageKeyByID: [UUID: String] = Dictionary(
            allCategories.map { ($0.id, $0.effectiveStorageKey) },
            uniquingKeysWith: { _, last in last }
        )
        var skipped = 0
        let rows: [UpsertCategory] = items.compactMap { b in
            guard let storageKey = storageKeyByID[b.categoryID] else {
                skipped += 1
                return nil
            }
            return UpsertCategory(
                id: b.id.uuidString,
                month: Self.monthKey(year: b.year, month: b.month),
                category_key: storageKey,
                amount: CloudHelpers.toCents(b.amount)
            )
        }
        guard !rows.isEmpty else {
            if skipped > 0 {
                SecureLogger.warning("Skipped \(skipped) category-budget(s) — no local category for their id")
            }
            return
        }
        try await client
            .from("monthly_category_budgets")
            .upsert(rows, onConflict: "id")
            .execute()
        SecureLogger.info("Upserted \(rows.count) monthly category budgets" + (skipped > 0 ? " (\(skipped) skipped — unknown category)" : ""))
    }

    /// Resolve a local categoryID to its `effectiveStorageKey` —
    /// the cross-platform string written to cloud.
    private func lookupStorageKey(for categoryID: UUID, in context: ModelContext) -> String? {
        let predicate = #Predicate<BudgetCategory> { $0.id == categoryID }
        let descriptor = FetchDescriptor<BudgetCategory>(predicate: predicate)
        return (try? context.fetch(descriptor))?.first?.effectiveStorageKey
    }

    // MARK: - Delete

    func deleteTotal(id: UUID) async throws {
        struct DR: Codable { let id: String }
        let _: [DR] = try await client
            .from("monthly_budgets")
            .delete()
            .eq("id", value: id.uuidString)
            .select("id")
            .execute()
            .value
    }

    func deleteCategoryBudget(id: UUID) async throws {
        struct DR: Codable { let id: String }
        let _: [DR] = try await client
            .from("monthly_category_budgets")
            .delete()
            .eq("id", value: id.uuidString)
            .select("id")
            .execute()
            .value
    }

    // MARK: - Helpers

    /// Year/month → "YYYY-MM" (UTC-agnostic; just integer formatting).
    static func monthKey(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    /// "YYYY-MM" → (year, month). Returns nil if malformed.
    static func parseMonthKey(_ s: String) -> (year: Int, month: Int)? {
        let parts = s.split(separator: "-")
        guard parts.count == 2,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              (1...12).contains(m) else { return nil }
        return (y, m)
    }

    /// Composite key for the (year, month, categoryID) trio used to find
    /// existing MonthlyBudget rows during pull.
    static func compositeKey(year: Int, month: Int, categoryID: UUID) -> String {
        "\(year)-\(month)-\(categoryID.uuidString)"
    }
}
