import Foundation
import SwiftData
import Supabase

// ============================================================
// MARK: - AccountRepository (macOS)
// ============================================================
// Thin adapter between SwiftData `Account` @Model and the cloud
// `accounts` table.
//
// Field mapping:
//   id                ↔ id
//   name              ↔ name
//   type (enum)       ↔ type (text — see typeMap below)
//   currentBalance    ↔ current_balance (numeric — Double on the wire)
//   currency          ↔ currency
//   colorHex          ↔ color_tag
//   isArchived        ↔ is_archived (bool)
//   sortOrder         ↔ display_order
//   updatedAt         ↔ updated_at (server-managed)
//
// IMPORTANT: balances are NOT cents. The DB column is `numeric`,
// matching iOS's Double. Earlier versions of this adapter used the
// `initial_balance` column with Int-cents semantics, which silently
// truncated fractional cents on push and divided by 100 on pull —
// a balance of 1234.56 would round-trip to 12.34. Fixed 2026-05-01.
// `initial_balance` is left to the DB default; it represents the
// starting balance at account creation, not the live balance.
//
// macOS-only fields (NOT synced for now):
//   institutionName, lastFourDigits, openingBalance,
//   openingBalanceDate, notes, includeInNetWorth,
//   includeInBudgeting, isClosed, closedAt, creditLimit,
//   interestRatePercent, minimumPaymentMonthly, ownerMember
// ============================================================

@MainActor
final class AccountRepository {

    static let shared = AccountRepository()
    private init() {}

    private var client: SupabaseClient { CloudClient.shared.client }

    // MARK: - Type mapping

    /// Map macOS AccountType ↔ cloud `accounts.type` text. The DB has a
    /// CHECK constraint that only allows: `cash | bank | credit_card |
    /// savings | investment | loan`. macOS's enum doesn't 1:1 match —
    /// we collapse `.checking` → `bank` (closest), `.other` → `cash`
    /// (the constraint has no "other" slot). On pull, iOS's `bank` maps
    /// back to `.checking` and `loan` to `.other` (best fit on macOS).
    private static func toCloudType(_ t: AccountType) -> String {
        switch t {
        case .checking:   return "bank"
        case .savings:    return "savings"
        case .creditCard: return "credit_card"
        case .investment: return "investment"
        case .cash:       return "cash"
        case .other:      return "cash"
        }
    }

    private static func fromCloudType(_ s: String) -> AccountType {
        switch s {
        case "bank":        return .checking
        case "checking":    return .checking      // legacy rows pre-fix
        case "savings":     return .savings
        case "credit_card": return .creditCard
        case "credit":      return .creditCard    // legacy rows pre-fix
        case "investment":  return .investment
        case "cash":        return .cash
        case "loan":        return .other         // no macOS equivalent
        default:            return .other
        }
    }

    // MARK: - Wire DTO

    private struct Row: Codable {
        let id: String
        let name: String
        let type: String
        let currency: String
        let current_balance: Double
        let color_tag: String?
        let display_order: Int
        let is_archived: Bool
        let updated_at: String?
    }

    // MARK: - Pull

    /// Pull all rows and reconcile by id. Locals missing from cloud
    /// are pruned IFF their `createdAt < cutoff` (i.e. the row had
    /// already been seen by cloud at least once — otherwise it might
    /// be a brand-new local pending its first push).
    ///
    /// `cutoff` is the coordinator's `lastSyncedAt`. Pass `.distantPast`
    /// to disable pruning entirely (e.g. for very first pull on a
    /// fresh device — there's nothing local to protect anyway, but
    /// also nothing to prune).
    func pullAll(into context: ModelContext, cutoff: Date) async throws {
        let rows: [Row] = try await client
            .from("accounts")
            .select()
            .order("display_order", ascending: true)
            .execute()
            .value
        SecureLogger.info("Pulled \(rows.count) accounts")

        let existing = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var byId: [UUID: Account] = CloudHelpers.indexById(existing) { $0.id }

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

        // Prune cloud-deleted locals. createdAt < cutoff means "this
        // row predates our last successful sync, so it must have been
        // known to cloud at some point — its absence now means another
        // device deleted it." Brand-new locals (createdAt > cutoff)
        // are pending their first push and must NOT be pruned.
        let toPrune = existing.filter { acct in
            !seenIds.contains(acct.id) && acct.createdAt < cutoff
        }
        if !toPrune.isEmpty {
            CloudSyncCoordinator.shared.runWhilePruning {
                for acct in toPrune { context.delete(acct) }
            }
            SecureLogger.info("Pruned \(toPrune.count) account(s) absent from cloud")
        }

        try? context.save()
    }

    // MARK: - Push

    func upsert(_ acct: Account) async throws {
        let row = makeRow(from: acct)
        try await client
            .from("accounts")
            .upsert(row, onConflict: "id")
            .execute()
        SecureLogger.debug("Upserted account")
    }

    func upsertMany(_ accts: [Account]) async throws {
        guard !accts.isEmpty else { return }
        let rows = accts.map(makeRow(from:))
        try await client
            .from("accounts")
            .upsert(rows, onConflict: "id")
            .execute()
        SecureLogger.info("Upserted \(rows.count) accounts")
    }

    /// Resurrection-safe push for "push all" tables. Account has no
    /// `updatedAt`, so we can't dirty-filter; instead we ask the cloud
    /// which IDs still exist and push only those (plus locals younger
    /// than `cutoff` — i.e. brand-new accounts pending their first
    /// upload). Locals whose ID isn't in cloud and whose createdAt
    /// predates cutoff = "another device deleted it; don't resurrect."
    ///
    /// Pruning of those resurrection candidates is intentionally NOT
    /// done here — `pullAll(into:cutoff:)` handles cloud→local removal
    /// in a single sweep using the same gate.
    func pushAllResurrectionSafe(_ accts: [Account], cutoff: Date) async throws {
        guard !accts.isEmpty else { return }
        let cloudIds = try await CloudSyncCoordinator.shared.fetchCloudIds(table: "accounts")
        let safe = accts.filter { acct in
            cloudIds.contains(acct.id) || acct.createdAt > cutoff
        }
        let skipped = accts.count - safe.count
        if skipped > 0 {
            SecureLogger.info("Skipped \(skipped) account(s) deleted on another device")
        }
        if !safe.isEmpty {
            try await upsertMany(safe)
        }
    }

    // MARK: - Delete

    func delete(id: UUID) async throws {
        struct DeletedRow: Codable { let id: String }
        let deleted: [DeletedRow] = try await client
            .from("accounts")
            .delete()
            .eq("id", value: id.uuidString)
            .select("id")
            .execute()
            .value
        SecureLogger.info("Deleted account (\(deleted.count) row(s) removed)")
    }

    func deleteMany(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        struct DeletedRow: Codable { let id: String }
        // Chunk by 100 to keep URL length under ~8 KB. See
        // TransactionRepository.deleteMany for the full rationale.
        let chunkSize = 100
        var totalDeleted = 0
        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let batch = Array(ids[start ..< min(start + chunkSize, ids.count)])
            let deleted: [DeletedRow] = try await client
                .from("accounts")
                .delete()
                .in("id", values: batch.map(\.uuidString))
                .select("id")
                .execute()
                .value
            totalDeleted += deleted.count
            await Task.yield()
        }
        SecureLogger.info("Deleted \(totalDeleted) of \(ids.count) requested account(s)")
    }

    // MARK: - Mapping

    private func makeRow(from a: Account) -> Row {
        Row(
            id: a.id.uuidString,
            name: a.name,
            type: Self.toCloudType(a.type),
            currency: a.currency,
            current_balance: CloudHelpers.numericDouble(a.currentBalance),
            color_tag: a.colorHex,
            display_order: a.sortOrder,
            is_archived: a.isArchived,
            updated_at: nil
        )
    }

    private func make(from row: Row) -> Account? {
        guard let id = CloudHelpers.uuid(row.id) else { return nil }
        let acct = Account(
            name: row.name,
            type: Self.fromCloudType(row.type),
            currentBalance: CloudHelpers.numericDecimal(row.current_balance),
            currency: row.currency,
            colorHex: row.color_tag,
            sortOrder: row.display_order
        )
        acct.id = id
        acct.isArchived = row.is_archived
        return acct
    }

    private func apply(_ row: Row, to model: Account) {
        model.name = row.name
        model.type = Self.fromCloudType(row.type)
        model.currency = row.currency
        model.currentBalance = CloudHelpers.numericDecimal(row.current_balance)
        model.colorHex = row.color_tag
        model.sortOrder = row.display_order
        model.isArchived = row.is_archived
    }
}
