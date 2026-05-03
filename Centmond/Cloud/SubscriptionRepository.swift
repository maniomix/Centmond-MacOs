import Foundation
import SwiftData
import Supabase

// ============================================================
// MARK: - SubscriptionRepository (macOS)
// ============================================================
// Bidirectional sync against the iOS-shaped `subscription_state`
// JSONB row: `{owner_id, snapshot, updated_at}` where `snapshot`
// is `{version, records, hiddenKeys, legacyStatusOverridesByKey}`.
// iOS (SubscriptionStoreSnapshot) owns the structure; macOS reads
// + writes the `records` array, leaving every other envelope key
// untouched so iOS's hide-state, schema version, and any future
// fields survive.
//
// Push flow (race-safe round trip):
//   1. Re-fetch the current cloud envelope as raw JSON dict.
//   2. Rebuild `records` from local Subscriptions, translating
//      Subscription → DetectedSubscription with safe defaults
//      for iOS-only fields.
//   3. Replace `records` in the envelope, keep everything else.
//   4. Upsert the merged envelope by owner_id.
//
// Pull flow:
//   1. Fetch envelope.
//   2. Translate `records` array → local Subscription rows.
//   3. Reconcile by id, prune locals missing from cloud
//      (createdAt < cutoff guard) inside runWhilePruning.
//
// macOS-specific status mapping:
//   - macOS `.trial` does not exist on iOS — encode as
//     `status: "active"` + `isTrial: true` so iOS still treats it
//     as an active sub flagged trial.
//   - iOS `.suspectedUnused` (raw "suspected_unused") has no
//     macOS equivalent → falls through, leaves model.status as-is.
// ============================================================

@MainActor
final class SubscriptionRepository {

    static let shared = SubscriptionRepository()
    private init() {}

    private var client: SupabaseClient { CloudClient.shared.client }

    // MARK: - Wire DTOs

    /// One DetectedSubscription on the wire. Full field surface so
    /// iOS doesn't lose data on a macOS round trip — we fill iOS-only
    /// metadata with safe defaults rather than dropping the keys.
    private struct EncodedRecord: Encodable {
        let id: String
        let merchantName: String
        let merchantKey: String
        let category: CategoryWire
        let expectedAmount: Int
        let lastAmount: Int
        let billingCycle: String
        let customCadenceDays: Int?
        let nextRenewalDate: Date?
        let lastChargeDate: Date?
        let status: String
        let source: String
        let linkedTransactionIds: [String]
        let notes: String
        let createdAt: Date
        let updatedAt: Date
        let isTrial: Bool
        let trialEndsAt: Date?
        let userEditedStatus: Bool
        let dismissedSuspectedUnused: Bool
        let isAutoDetected: Bool
        let confidenceScore: Double
        let chargeHistory: [String]   // empty for macOS-pushed records
        let detectedIntervalDays: Int
    }

    /// Mirrors iOS Category Codable shape:
    /// `{ "type": "system"|"custom", "value": "<name>" }`
    private struct CategoryWire: Encodable {
        let type: String
        let value: String
    }

    private struct DetectedSubscriptionDTO: Decodable {
        let id: String
        let merchantName: String
        let merchantKey: String?
        let expectedAmount: Int?
        let lastAmount: Int?
        let billingCycle: String?
        let customCadenceDays: Int?
        let nextRenewalDate: Date?
        let lastChargeDate: Date?
        let status: String?
        let source: String?
        let notes: String?
        let createdAt: Date?
        let updatedAt: Date?
        let isTrial: Bool?
        let trialEndsAt: Date?
    }

    private struct StoreSnapshotDTO: Decodable {
        let records: [DetectedSubscriptionDTO]?
    }

    private struct PullRow: Decodable {
        let snapshot: StoreSnapshotDTO
    }

    /// Raw envelope used during push so we round-trip iOS fields we
    /// don't model (hiddenKeys, version, legacyStatusOverridesByKey).
    private struct EnvelopeRow: Decodable {
        let snapshot: AnyJSON
    }

    private struct EnvelopePushRow: Encodable {
        let owner_id: String
        let snapshot: AnyJSON
    }

    // MARK: - Pull

    func pullAll(into context: ModelContext, cutoff: Date) async throws {
        let rows: [PullRow] = try await client
            .from("subscription_state")
            .select("snapshot")
            .limit(1)
            .execute()
            .value

        guard let dtos = rows.first?.snapshot.records else {
            SecureLogger.info("No subscription records in cloud snapshot")
            return
        }
        SecureLogger.info("Pulled \(dtos.count) subscription record(s) from cloud snapshot")

        let existing = (try? context.fetch(FetchDescriptor<Subscription>())) ?? []
        var byId: [UUID: Subscription] = CloudHelpers.indexById(existing) { $0.id }

        var seenIds = Set<UUID>()
        for dto in dtos {
            guard let id = CloudHelpers.uuid(dto.id) else { continue }
            seenIds.insert(id)
            if let model = byId[id] {
                apply(dto, to: model)
            } else if let new = make(from: dto, id: id) {
                context.insert(new)
                byId[id] = new
            }
        }

        let toPrune = existing.filter { sub in
            !seenIds.contains(sub.id) && sub.createdAt < cutoff
        }
        if !toPrune.isEmpty {
            CloudSyncCoordinator.shared.runWhilePruning {
                for sub in toPrune { context.delete(sub) }
            }
            SecureLogger.info("Pruned \(toPrune.count) subscription(s) absent from cloud snapshot")
        }

        try? context.save()
    }

    // MARK: - Push (race-safe envelope merge)

    /// Push local Subscriptions into the cloud envelope without
    /// clobbering iOS's hidden-keys / version / legacy fields, and
    /// without resurrecting records another device just deleted.
    ///
    /// Strategy: re-fetch the envelope, take the union of IDs in
    /// cloud's current `records` and local subs whose `createdAt`
    /// is newer than `cutoff`. Anything else (in local but not in
    /// cloud, AND old) was deleted on another device — skip it.
    /// Then replace only `records` in the envelope and upsert.
    /// One extra GET per push cycle (cheap; single jsonb row).
    func pushSnapshot(from context: ModelContext, cutoff: Date) async throws {
        guard let ownerId = AuthManager.shared.currentUser?.id.uuidString else {
            SecureLogger.warning("SubscriptionRepository.pushSnapshot skipped — no authenticated user")
            return
        }

        let subs = (try? context.fetch(FetchDescriptor<Subscription>())) ?? []

        // 1. Re-fetch the live envelope so iOS-owned keys survive AND
        //    we know which records cloud currently has.
        let envelopeRows: [EnvelopeRow] = try await client
            .from("subscription_state")
            .select("snapshot")
            .limit(1)
            .execute()
            .value

        // Extract cloud-known record IDs for resurrection guard.
        let cloudIds: Set<UUID> = {
            guard let env = envelopeRows.first?.snapshot,
                  case .object(let dict) = env,
                  let records = dict["records"],
                  case .array(let recs) = records else {
                return []
            }
            var ids = Set<UUID>()
            for rec in recs {
                guard case .object(let r) = rec,
                      case .string(let idStr) = r["id"] ?? .null,
                      let uuid = UUID(uuidString: idStr) else { continue }
                ids.insert(uuid)
            }
            return ids
        }()

        // 2. Filter local subs: keep if cloud-known OR fresh local.
        //    Drop records that are old AND missing from cloud — those
        //    were deleted on another device; pushing them would
        //    resurrect them.
        let safe = subs.filter { sub in
            cloudIds.contains(sub.id) || sub.createdAt > cutoff
        }
        let dropped = subs.count - safe.count
        if dropped > 0 {
            SecureLogger.info("Skipped \(dropped) subscription(s) deleted on another device")
        }

        // 3. Build new `records` payload from filtered subs.
        let encodedRecords = safe.map(makeEncodedRecord(from:))
        // Round-trip through JSONEncoder/JSONDecoder to convert
        // [EncodedRecord] → AnyJSON — keeps date encoding strategy
        // consistent with the rest of the envelope and avoids
        // hand-building AnyJSON case-by-case.
        let encoder = Self.iosEncoder
        let recordsData = try encoder.encode(encodedRecords)
        let recordsJSON = try JSONDecoder().decode(AnyJSON.self, from: recordsData)

        // 3. Merge into existing envelope (or build a fresh one).
        let mergedEnvelope: AnyJSON
        if let existing = envelopeRows.first?.snapshot,
           case .object(var dict) = existing {
            dict["records"] = recordsJSON
            // Stamp version if iOS hasn't (pre-rebuild rows). Default
            // to the schema version iOS uses today.
            if dict["version"] == nil {
                dict["version"] = .integer(1)
            }
            mergedEnvelope = .object(dict)
        } else {
            // No envelope yet (fresh user) — minimal schema-1 shape.
            mergedEnvelope = .object([
                "version": .integer(1),
                "records": recordsJSON,
                "hiddenKeys": .array([]),
                "legacyStatusOverridesByKey": .object([:])
            ])
        }

        // 4. Upsert the merged envelope.
        let row = EnvelopePushRow(owner_id: ownerId, snapshot: mergedEnvelope)
        try await client
            .from("subscription_state")
            .upsert(row, onConflict: "owner_id")
            .execute()
        SecureLogger.info("Pushed subscription envelope (\(safe.count) records, \(dropped) skipped)")
    }

    /// JSONEncoder configured to match iOS's default Date strategy
    /// (`.deferredToDate`, i.e. seconds since reference date as
    /// Double) so PostgREST round-trips without skew.
    private static let iosEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .deferredToDate
        return e
    }()

    // MARK: - Mapping (Sub → wire)

    private func makeEncodedRecord(from s: Subscription) -> EncodedRecord {
        // Map macOS `.trial` to iOS `.active` + isTrial=true since
        // iOS has no `.trial` case. Other statuses are 1:1 by raw.
        let (status, isTrialOverride): (String, Bool) = {
            switch s.status {
            case .trial:    return ("active", true)
            default:        return (s.status.rawValue, false)
            }
        }()

        return EncodedRecord(
            id: s.id.uuidString,
            merchantName: s.serviceName,
            merchantKey: s.merchantKey,
            category: CategoryWire(type: "system", value: "bills"),
            expectedAmount: CloudHelpers.toCents(s.amount),
            lastAmount: CloudHelpers.toCents(s.amount),
            billingCycle: s.billingCycle.rawValue,
            customCadenceDays: s.customCadenceDays,
            nextRenewalDate: s.nextPaymentDate,
            lastChargeDate: s.lastChargeDate,
            status: status,
            source: s.source.rawValue,
            linkedTransactionIds: [],
            notes: s.notes ?? "",
            createdAt: s.createdAt,
            updatedAt: s.updatedAt,
            isTrial: s.isTrial || isTrialOverride,
            trialEndsAt: s.trialEndsAt,
            userEditedStatus: true,             // macOS edits always lock status
            dismissedSuspectedUnused: false,
            isAutoDetected: false,              // macOS-pushed = manual
            confidenceScore: 1.0,
            chargeHistory: [],
            detectedIntervalDays: 0
        )
    }

    // MARK: - Mapping (wire → Sub)

    private func make(from dto: DetectedSubscriptionDTO, id: UUID) -> Subscription? {
        guard !dto.merchantName.isEmpty else { return nil }
        let cycle = BillingCycle(rawValue: dto.billingCycle ?? "") ?? .monthly
        let status = SubscriptionStatus(rawValue: dto.status ?? "") ?? .active
        let nextPay = dto.nextRenewalDate ?? .now

        let amount = CloudHelpers.toDecimal(cents: dto.expectedAmount ?? 0)
        let sub = Subscription(
            serviceName: dto.merchantName,
            categoryName: "Subscriptions",
            amount: amount,
            billingCycle: cycle,
            nextPaymentDate: nextPay,
            status: status,
            account: nil
        )
        sub.id = id
        sub.merchantKey = dto.merchantKey ?? Subscription.merchantKey(for: dto.merchantName)
        sub.customCadenceDays = dto.customCadenceDays
        sub.lastChargeDate = dto.lastChargeDate
        sub.isTrial = dto.isTrial ?? false
        sub.trialEndsAt = dto.trialEndsAt
        sub.notes = dto.notes
        if let s = dto.source, let parsed = SubscriptionSource(rawValue: s) {
            sub.source = parsed
        }
        if let created = dto.createdAt { sub.createdAt = created }
        if let updated = dto.updatedAt { sub.updatedAt = updated }
        return sub
    }

    private func apply(_ dto: DetectedSubscriptionDTO, to model: Subscription) {
        model.serviceName = dto.merchantName
        if let key = dto.merchantKey { model.merchantKey = key }
        model.amount = CloudHelpers.toDecimal(cents: dto.expectedAmount ?? 0)
        model.billingCycle = BillingCycle(rawValue: dto.billingCycle ?? "") ?? model.billingCycle
        model.customCadenceDays = dto.customCadenceDays
        if let next = dto.nextRenewalDate { model.nextPaymentDate = next }
        model.lastChargeDate = dto.lastChargeDate
        model.status = SubscriptionStatus(rawValue: dto.status ?? "") ?? model.status
        model.isTrial = dto.isTrial ?? model.isTrial
        model.trialEndsAt = dto.trialEndsAt
        model.notes = dto.notes
        if let s = dto.source, let parsed = SubscriptionSource(rawValue: s) {
            model.source = parsed
        }
        if let updated = dto.updatedAt {
            // Last-writer-wins on updatedAt to prevent stale realtime
            // echoes from clobbering fresher local state.
            if updated > model.updatedAt { model.updatedAt = updated }
        }
    }
}
