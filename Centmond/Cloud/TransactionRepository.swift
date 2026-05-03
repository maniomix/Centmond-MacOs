import Foundation
import SwiftData
import Supabase

// ============================================================
// MARK: - TransactionRepository (macOS)
// ============================================================
// Thin adapter between SwiftData `Transaction` @Model and the
// shared Supabase `transactions` table.
//
// Field mapping (macOS @Model ↔ cloud column):
//   id                  ↔ id
//   date                ↔ occurred_at
//   payee               ↔ merchant
//   amount (Decimal)    ↔ amount (bigint cents)        ← rounding done in CloudHelpers
//   notes               ↔ note
//   isIncome (Bool)     ↔ type ('income'|'expense')
//   transferGroupID     ↔ transfer_group_id
//   account.id          ↔ account_id
//   category.id         ↔ category_key (UUID-as-string)
//   updatedAt           ↔ updated_at (server-managed via moddatetime trigger)
//
// Macro-only fields kept locally (NOT synced):
//   status, isReviewed, recurringTemplateID, receiptImageData,
//   tags, splits, shares, householdMember
// These are macOS-specific richer features. iOS users won't see
// them — and that's fine for v1.
// ============================================================

@MainActor
final class TransactionRepository {

    static let shared = TransactionRepository()
    private init() {}

    private var client: SupabaseClient { CloudClient.shared.client }

    // MARK: - Wire DTO

    /// Snake-case to match PostgREST column names.
    /// `owner_id` is filled by the `fill_owner_id` trigger on insert,
    /// so we don't send it.
    private struct Row: Codable {
        let id: String
        let account_id: String?
        let category_key: String?
        let amount: Int
        let occurred_at: String
        let note: String?
        let merchant: String?
        let type: String                  // "income" | "expense"
        let transfer_group_id: String?
        let updated_at: String?
    }

    // MARK: - Pull

    /// Fetch all rows the user owns and reconcile into the local
    /// SwiftData store. Existing models with matching `id` are updated;
    /// Pull all rows and reconcile by id. Locals missing from cloud
    /// are pruned IFF their `updatedAt < cutoff` — i.e. the row hasn't
    /// been edited locally since the last successful sync, so its
    /// absence in cloud means another device deleted it. Locals
    /// edited after cutoff are protected (they're pending push).
    func pullAll(into context: ModelContext, cutoff: Date) async throws {
        // PostgREST caps default response sizes (Supabase's default is
        // 1000 rows). After a heavy CSV import a single bare select()
        // would silently truncate — the user'd see "Pulled 1000
        // transactions" while 358 stayed cloud-only. Paginate via
        // `.range()` until a short page comes back, then stop.
        //
        // IMPORTANT: requesting a range past the end of the table can
        // throw a decoding error (PostgREST returns 416 / empty body
        // and the SDK fails to deserialize). Guard with a per-page
        // try/catch so the realtime cycle doesn't bail mid-pull on a
        // "data couldn't be read" error after the last full page.
        let pageSize = 1000
        let maxPages = 50    // 50,000 rows hard ceiling — anything
                             // beyond is a data-leak/bug, fail loud.
        var rows: [Row] = []
        var offset = 0
        for _ in 0 ..< maxPages {
            let page: [Row]
            do {
                page = try await client
                    .from("transactions")
                    .select()
                    .order("occurred_at", ascending: false)
                    .range(from: offset, to: offset + pageSize - 1)
                    .execute()
                    .value
            } catch {
                // Range-past-end usually surfaces as a decoding
                // error. If we already pulled at least one page
                // treat it as "we're done"; otherwise rethrow so
                // a real failure isn't silently swallowed.
                if !rows.isEmpty { break }
                throw error
            }
            if page.isEmpty { break }
            rows.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
            await Task.yield()
        }
        SecureLogger.info("Pulled \(rows.count) transactions")

        // Index existing local models by id for O(n) merge.
        let existing = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        var byId: [UUID: Transaction] = CloudHelpers.indexById(existing) { $0.id }
        // Detect & clean up duplicate-id rows. After a large CSV
        // import a stray dupe here would have crashed the old
        // `uniqueKeysWithValues` builder; now we keep the last
        // occurrence and prune the extras locally.
        let duplicateCount = existing.count - byId.count
        if duplicateCount > 0 {
            let keepers = Set(byId.values.map { ObjectIdentifier($0) })
            let dupes = existing.filter { !keepers.contains(ObjectIdentifier($0)) }
            CloudSyncCoordinator.shared.runWhilePruning {
                for dupe in dupes { context.delete(dupe) }
            }
            SecureLogger.warning("Pruned \(dupes.count) duplicate-id transaction row(s) from local store")
        }

        // Ghost-resurrection guard. When the user deletes a transaction
        // locally, three things happen in this order:
        //   1. willSave hook queues the id into CloudDeletionQueue.
        //   2. Local row vanishes immediately.
        //   3. push debounce (2s) fires later and pushes the DELETE.
        // If a realtime postgres_changes event (or any unrelated pull
        // trigger) arrives during step-2→3 window, this pullAll sees
        // the row STILL in cloud and re-inserts it locally — the row
        // visibly reappears for ~1 second until the next push drains
        // the deletion queue. Filter out any id that's already been
        // queued for deletion so resurrection can never happen.
        let pendingDeletionIds = Set(CloudDeletionQueue.shared.pending(.transactions))

        var seenIds = Set<UUID>()
        for row in rows {
            guard let id = CloudHelpers.uuid(row.id) else { continue }
            // A pending-delete row IS still in cloud (we haven't pushed
            // yet), but we know the user just deleted it. Treat as if
            // we've already seen it so it isn't pruned, and DON'T touch
            // any local copy — there shouldn't be one.
            if pendingDeletionIds.contains(id) {
                seenIds.insert(id)
                continue
            }
            seenIds.insert(id)
            if let model = byId[id] {
                apply(row, to: model, in: context)
            } else if let new = make(from: row, in: context) {
                context.insert(new)
                byId[id] = new
            }
        }

        let toPrune = existing.filter { tx in
            !seenIds.contains(tx.id) && tx.updatedAt < cutoff
        }
        if !toPrune.isEmpty {
            CloudSyncCoordinator.shared.runWhilePruning {
                for tx in toPrune { context.delete(tx) }
            }
            SecureLogger.info("Pruned \(toPrune.count) transaction(s) absent from cloud")
        }

        try? context.save()
    }

    // MARK: - Push

    func upsert(_ tx: Transaction) async throws {
        let row = makeRow(from: tx)
        try await client
            .from("transactions")
            .upsert(row, onConflict: "id")
            .execute()
        SecureLogger.debug("Upserted transaction")
    }

    func upsertMany(_ txs: [Transaction]) async throws {
        guard !txs.isEmpty else { return }
        let rows = txs.map(makeRow(from:))

        // Chunk to keep each PostgREST request well under the 1 MB
        // body-size limit. After a big CSV import (tested at 1300+
        // rows) a single upsert exceeded the limit and failed the
        // whole batch; chunking lets the import drain steadily even
        // on flaky networks. 500 rows ≈ 200–400 KB depending on
        // payee/notes length — comfortable margin.
        let chunkSize = 500
        var uploaded = 0
        for batchStart in stride(from: 0, to: rows.count, by: chunkSize) {
            let batch = Array(rows[batchStart ..< min(batchStart + chunkSize, rows.count)])
            try await client
                .from("transactions")
                .upsert(batch, onConflict: "id")
                .execute()
            uploaded += batch.count
            // Yield once per chunk so the @MainActor's other tasks
            // (UI render, save observers) don't get starved by a
            // long sequential push during a bulk import.
            await Task.yield()
        }
        SecureLogger.info("Upserted \(uploaded) transactions in \(Int(ceil(Double(rows.count) / Double(chunkSize)))) batch(es)")
    }

    // MARK: - Delete

    func delete(id: UUID) async throws {
        struct DeletedRow: Codable { let id: String }
        let deleted: [DeletedRow] = try await client
            .from("transactions")
            .delete()
            .eq("id", value: id.uuidString)
            .select("id")
            .execute()
            .value
        SecureLogger.info("Deleted transaction (\(deleted.count) row(s) removed)")
    }

    func deleteMany(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        struct DeletedRow: Codable { let id: String }

        // Chunk the IDs so the `?id=in.(uuid1,uuid2,…)` query string
        // never exceeds typical URL length limits (~8 KB). Each UUID
        // serializes to ~38 chars including the comma; 100 IDs ≈ 3.8
        // KB, which gives plenty of margin even with the rest of the
        // URL (host + path + filter prefix). Without chunking, drain
        // of a large deletion queue (e.g. after Wipe All Data on a
        // 1300-row store) crashes with HTTPError "URL too long".
        let chunkSize = 100
        var totalDeleted = 0
        for batchStart in stride(from: 0, to: ids.count, by: chunkSize) {
            let batch = Array(ids[batchStart ..< min(batchStart + chunkSize, ids.count)])
            let deleted: [DeletedRow] = try await client
                .from("transactions")
                .delete()
                .in("id", values: batch.map(\.uuidString))
                .select("id")
                .execute()
                .value
            totalDeleted += deleted.count
            await Task.yield()
        }
        SecureLogger.info("Deleted \(totalDeleted) of \(ids.count) requested transaction(s) in \(Int(ceil(Double(ids.count) / Double(chunkSize)))) batch(es)")
    }

    // MARK: - Mapping

    private func makeRow(from tx: Transaction) -> Row {
        Row(
            id: tx.id.uuidString,
            account_id: tx.account?.id.uuidString,
            // Cross-platform storage_key, NOT UUID. iOS reads
            // `transactions.category_key` as `Category.storageKey`
            // ("groceries", "custom:Coffee", …); we mirror that
            // convention so tagged transactions round-trip.
            category_key: tx.category?.effectiveStorageKey,
            amount: CloudHelpers.toCents(tx.amount),
            occurred_at: CloudHelpers.isoString(tx.date),
            note: tx.notes,
            merchant: tx.payee.isEmpty ? nil : tx.payee,
            type: tx.isIncome ? "income" : "expense",
            transfer_group_id: CloudHelpers.uuidString(tx.transferGroupID),
            updated_at: nil  // server moddatetime trigger sets this
        )
    }

    /// Build a brand-new SwiftData `Transaction` from a cloud row.
    /// Returns nil if the row is malformed (bad UUID, unparseable date).
    private func make(from row: Row, in context: ModelContext) -> Transaction? {
        guard let id = CloudHelpers.uuid(row.id),
              let date = CloudHelpers.parseDate(row.occurred_at) else { return nil }

        // BudgetCategory and Account are looked up from the local store.
        // If the row references one we don't have locally, leave the
        // relationship nil — the user can re-link manually or a later
        // pull (after the parent is synced) will fill it in.
        let account = lookupAccount(id: CloudHelpers.uuid(row.account_id), in: context)
        let category = lookupCategory(storageKey: row.category_key, in: context)

        let tx = Transaction(
            date: date,
            payee: row.merchant ?? "",
            amount: CloudHelpers.toDecimal(cents: row.amount),
            notes: row.note,
            isIncome: row.type == "income",
            account: account,
            category: category
        )
        // Override auto-assigned id so cross-device sync works.
        tx.id = id
        tx.transferGroupID = CloudHelpers.uuid(row.transfer_group_id)
        tx.isTransfer = tx.transferGroupID != nil
        if let last = CloudHelpers.parseDate(row.updated_at) {
            tx.updatedAt = last
        }
        return tx
    }

    /// Update an existing local model with the cloud row's contents.
    /// macOS-only fields (status, isReviewed, tags, etc.) are NOT touched.
    private func apply(_ row: Row, to model: Transaction, in context: ModelContext) {
        if let date = CloudHelpers.parseDate(row.occurred_at) { model.date = date }
        model.payee = row.merchant ?? model.payee
        model.amount = CloudHelpers.toDecimal(cents: row.amount)
        model.notes = row.note
        model.isIncome = (row.type == "income")
        model.transferGroupID = CloudHelpers.uuid(row.transfer_group_id)
        model.isTransfer = model.transferGroupID != nil

        if let accountId = CloudHelpers.uuid(row.account_id) {
            if model.account?.id != accountId {
                model.account = lookupAccount(id: accountId, in: context)
            }
        } else {
            model.account = nil
        }
        if let key = row.category_key, !key.isEmpty {
            // storage_key lookup — same key macOS writes to cloud now,
            // matches iOS's Category.storageKey convention.
            if model.category?.effectiveStorageKey != key {
                model.category = lookupCategory(storageKey: key, in: context)
            }
        } else {
            model.category = nil
        }
        if let last = CloudHelpers.parseDate(row.updated_at) { model.updatedAt = last }
    }

    // MARK: - Local lookups

    private func lookupAccount(id: UUID?, in context: ModelContext) -> Account? {
        guard let id else { return nil }
        let predicate = #Predicate<Account> { $0.id == id }
        let descriptor = FetchDescriptor<Account>(predicate: predicate)
        return (try? context.fetch(descriptor))?.first
    }

    /// Find a local BudgetCategory matching the cross-platform
    /// `storage_key` written to cloud. Built-ins are matched on the
    /// canonical storageKey ("groceries"); customs on `"custom:Name"`.
    /// Falls back to a name-match for old rows whose `storageKey`
    /// field hasn't been backfilled yet (the seeder backfills on
    /// the next launch, so this is mostly a transition aid).
    private func lookupCategory(storageKey raw: String?, in context: ModelContext) -> BudgetCategory? {
        guard let raw, !raw.isEmpty else { return nil }
        let descriptor = FetchDescriptor<BudgetCategory>()
        guard let all = try? context.fetch(descriptor) else { return nil }

        // Fast path: storageKey field populated and matches.
        if let hit = all.first(where: { $0.storageKey == raw }) {
            return hit
        }
        // Fallback: derive on the fly. Keeps tagged transactions
        // resolvable on a Mac whose store predates the storageKey
        // field — the seeder will populate the field on next launch.
        return all.first(where: { $0.effectiveStorageKey == raw })
    }
}
