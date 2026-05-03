import Foundation
import SwiftData
import Supabase

// ============================================================
// MARK: - HouseholdRepository (macOS)
// ============================================================
//
// ⚠️ Household Rebuild P6.2 status: this file predates the unified DTO
// (schema_version: 2 — see iOS `HouseholdSyncManager` and
// `docs/HOUSEHOLD_REBUILD_P1_SPEC.md`). It still reads/writes the v1 shape:
//   • `splitExpenses: [SplitExpense]` aggregate (no per-share rows)
//   • `Settlement` without `closedShareIds` / `deletedAt`
//   • No `expenseShares` array
//   • No `pendingInvites` array
//
// On pull from a v2 snapshot, the missing fields decode as defaults — no
// crash — but the macOS app sees the legacy shape only. Pushes from this
// file will still write v1, so a v2-aware client (iOS) reading after a
// macOS write will run its v1→v2 expansion path.
//
// Full v2 conformance (and macOS HouseholdEngine implementation) is gated
// on the in-progress macOS Cloud Port — see project_macos_cloud_port —
// because this file also depends on auth context (`AuthManager`) that the
// port is still wiring up. Until that lands, treat this repository as
// read-only-compatible-with-v2 and do not add new push fields here.
//
// Bidirectional sync against `household_state` JSONB row.
//
// Cross-platform shape is iOS-canonical (HouseholdSyncManager):
//   { household: {id, name, createdBy, members:[…], inviteCode,
//                 groups:[…], createdAt, updatedAt},
//     splitExpenses: [SplitExpense], settlements: [Settlement],
//     sharedBudgets: [SharedBudget], sharedGoals: [SharedGoal] }
//
// macOS reads + writes that shape. The two domain models diverge:
//
//   • iOS HouseholdMember is identified by `userId` (auth.uid()
//     string) AND a `displayName`. iOS supports multi-user.
//   • macOS HouseholdMember has no userId — it's a solo-user model
//     where members are virtual entries the user adds locally.
//
// Bridge: when pushing from macOS we synthesize `userId` from
// `HouseholdMember.id.uuidString` (stable across launches, unique
// per member). On pull, the iOS `userId` is stored on macOS only
// implicitly via the same UUID round-trip — macOS doesn't have a
// userId field, but member.id matches iOS member.id, so settlements
// (which reference userId on iOS) can be looked up locally by the
// same UUID.
//
// SCOPE OF SYNC:
//   ✅ household.members           (round-trip)
//   ✅ household.groups            (round-trip)
//   ✅ settlements                 (cents/Decimal + member-id ↔ userId mapping)
//   ⚠️ splitExpenses               (PRESERVED in envelope on push,
//                                  not translated to macOS @Models —
//                                  macOS ExpenseShare has parent-tx
//                                  + percent + method which doesn't
//                                  cleanly map to iOS SplitExpense's
//                                  paidBy + splitRule + customSplits)
//   ⚠️ sharedBudgets / sharedGoals (PRESERVED in envelope; no macOS
//                                  equivalent yet)
//
// Push flow mirrors SubscriptionRepository:
//   1. Re-fetch envelope as raw AnyJSON dict.
//   2. Build a new {household, settlements} sub-payload from local
//      HouseholdMember + HouseholdGroup + HouseholdSettlement.
//   3. Replace the `household` and `settlements` keys in the
//      envelope; LEAVE splitExpenses/sharedBudgets/sharedGoals
//      untouched (iOS owns them).
//   4. Upsert.
//
// Pull translates iOS members + settlements to local macOS
// @Models. Splits stay iOS-only (we don't translate them down,
// since macOS users would lose the percent/method semantics).
// ============================================================

@MainActor
final class HouseholdRepository {

    static let shared = HouseholdRepository()
    private init() {}

    private var client: SupabaseClient { CloudClient.shared.client }

    // MARK: - Wire DTOs (iOS shape)

    /// One iOS HouseholdMember on the wire.
    private struct EncodedMember: Encodable {
        let id: String
        let userId: String
        let displayName: String
        let email: String
        let role: String
        let joinedAt: Date
        let sharedAccountIds: [String]?
        let shareTransactions: Bool
        let isActive: Bool
        let archivedAt: Date?
        let groupIds: [String]
    }

    /// One iOS HouseholdGroup on the wire.
    private struct EncodedGroup: Encodable {
        let id: String
        let name: String
        let colorHex: String
        let memberIds: [String]
        let createdAt: Date
    }

    /// iOS Household envelope (top-level `household` key).
    private struct EncodedHousehold: Encodable {
        let id: String
        let name: String
        let createdBy: String
        let members: [EncodedMember]
        let inviteCode: String
        let groups: [EncodedGroup]
        let createdAt: Date
        let updatedAt: Date
    }

    /// One iOS Settlement on the wire.
    private struct EncodedSettlement: Encodable {
        let id: String
        let householdId: String
        let fromUserId: String
        let toUserId: String
        let amount: Int        // cents
        let note: String
        let date: Date
        let relatedExpenseIds: [String]
        let createdAt: Date
    }

    /// Pull-side iOS DTOs (Decodable, all fields optional for
    /// forward-compat).
    private struct DecodedMember: Decodable {
        let id: String
        let userId: String?
        let displayName: String?
        let email: String?
        let role: String?
        let joinedAt: Date?
        let isActive: Bool?
        let archivedAt: Date?
        let groupIds: [String]?
    }

    private struct DecodedGroup: Decodable {
        let id: String
        let name: String?
        let colorHex: String?
        let memberIds: [String]?
        let createdAt: Date?
    }

    private struct DecodedHousehold: Decodable {
        let id: String?
        let members: [DecodedMember]?
        let groups: [DecodedGroup]?
    }

    private struct DecodedSettlement: Decodable {
        let id: String
        let fromUserId: String?
        let toUserId: String?
        let amount: Int?
        let note: String?
        let date: Date?
        let createdAt: Date?
    }

    private struct PullSnapshot: Decodable {
        let household: DecodedHousehold?
        let settlements: [DecodedSettlement]?
    }

    private struct PullRow: Decodable {
        let snapshot: PullSnapshot
    }

    private struct EnvelopeRow: Decodable {
        let snapshot: AnyJSON
    }

    private struct EnvelopePushRow: Encodable {
        let owner_id: String
        let snapshot: AnyJSON
    }

    // MARK: - Date strategy (iOS-compatible)

    private static let iosEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .deferredToDate
        return e
    }()

    /// Walk an AnyJSON envelope along a key path, expecting the leaf
    /// to be an array of objects each with a string `id` field, and
    /// return the set of those IDs as UUIDs. Used for the
    /// resurrection-guard read of cloud-known entity IDs.
    /// Returns an empty set on any structural mismatch (e.g.
    /// missing key, unexpected type) — callers treat that the same
    /// as "cloud has nothing here yet" which is the correct
    /// semantics for a fresh envelope.
    private static func idSet(in envelope: AnyJSON?, path: [String]) -> Set<UUID> {
        guard let envelope else { return [] }
        var node = envelope
        for key in path {
            guard case .object(let dict) = node, let next = dict[key] else { return [] }
            node = next
        }
        guard case .array(let arr) = node else { return [] }
        var ids = Set<UUID>()
        for item in arr {
            guard case .object(let dict) = item,
                  case .string(let s) = dict["id"] ?? .null,
                  let uuid = UUID(uuidString: s) else { continue }
            ids.insert(uuid)
        }
        return ids
    }

    // MARK: - Pull

    func pullAll(into context: ModelContext, cutoff: Date) async throws {
        let rows: [PullRow] = try await client
            .from("household_state")
            .select("snapshot")
            .limit(1)
            .execute()
            .value

        guard let snap = rows.first?.snapshot else {
            SecureLogger.info("No household snapshot in cloud")
            return
        }

        let memberDTOs     = snap.household?.members ?? []
        let groupDTOs      = snap.household?.groups ?? []
        let settlementDTOs = snap.settlements ?? []

        SecureLogger.info("Pulled household snapshot: \(memberDTOs.count) members, \(groupDTOs.count) groups, \(settlementDTOs.count) settlements")

        let localMembers = (try? context.fetch(FetchDescriptor<HouseholdMember>())) ?? []
        let localGroups  = (try? context.fetch(FetchDescriptor<HouseholdGroup>())) ?? []
        let localSettls  = (try? context.fetch(FetchDescriptor<HouseholdSettlement>())) ?? []

        var memberById: [UUID: HouseholdMember]    = CloudHelpers.indexById(localMembers) { $0.id }
        var groupById: [UUID: HouseholdGroup]      = CloudHelpers.indexById(localGroups)  { $0.id }
        var settlById: [UUID: HouseholdSettlement] = CloudHelpers.indexById(localSettls)  { $0.id }

        // 1) Members
        var seenMemberIds = Set<UUID>()
        for dto in memberDTOs {
            guard let id = CloudHelpers.uuid(dto.id) else { continue }
            seenMemberIds.insert(id)
            if let model = memberById[id] {
                applyMember(dto, to: model)
            } else {
                let new = makeMember(from: dto, id: id)
                context.insert(new)
                memberById[id] = new
            }
        }

        // 2) Groups (after members so memberId resolution works)
        var seenGroupIds = Set<UUID>()
        for dto in groupDTOs {
            guard let id = CloudHelpers.uuid(dto.id) else { continue }
            seenGroupIds.insert(id)
            let resolvedMembers = (dto.memberIds ?? []).compactMap {
                CloudHelpers.uuid($0).flatMap { memberById[$0] }
            }
            if let model = groupById[id] {
                applyGroup(dto, to: model, members: resolvedMembers)
            } else {
                let new = makeGroup(from: dto, id: id, members: resolvedMembers)
                context.insert(new)
                groupById[id] = new
            }
        }

        // 3) Settlements (need members first; iOS userId == macOS
        //    member.id.uuidString thanks to the synthesizing rule).
        var seenSettlementIds = Set<UUID>()
        for dto in settlementDTOs {
            guard let id = CloudHelpers.uuid(dto.id) else { continue }
            seenSettlementIds.insert(id)
            let from = CloudHelpers.uuid(dto.fromUserId).flatMap { memberById[$0] }
            let to   = CloudHelpers.uuid(dto.toUserId).flatMap { memberById[$0] }
            if let model = settlById[id] {
                applySettlement(dto, to: model, from: from, target: to)
            } else {
                let new = makeSettlement(from: dto, id: id, fromMember: from, target: to)
                context.insert(new)
                settlById[id] = new
            }
        }

        // Prune locals missing from cloud (gated by createdAt < cutoff).
        let pruneMembers     = localMembers.filter     { !seenMemberIds.contains($0.id)     && $0.joinedAt < cutoff }
        let pruneGroups      = localGroups.filter      { !seenGroupIds.contains($0.id)      && $0.createdAt < cutoff }
        let pruneSettlements = localSettls.filter      { !seenSettlementIds.contains($0.id) && $0.createdAt < cutoff }

        let totalPrune = pruneMembers.count + pruneGroups.count + pruneSettlements.count
        if totalPrune > 0 {
            CloudSyncCoordinator.shared.runWhilePruning {
                // Settlements first (have member nullify refs), then groups,
                // then members. ExpenseShares not in this prune set — they
                // sync via iOS-only splitExpenses path which we don't touch.
                for s in pruneSettlements { context.delete(s) }
                for g in pruneGroups      { context.delete(g) }
                for m in pruneMembers     { context.delete(m) }
            }
            SecureLogger.info("Pruned household: \(pruneMembers.count) members, \(pruneGroups.count) groups, \(pruneSettlements.count) settlements")
        }

        try? context.save()
    }

    // MARK: - Push (envelope-merge, preserves iOS-owned keys)

    func pushSnapshot(from context: ModelContext, cutoff: Date) async throws {
        guard let ownerId = AuthManager.shared.currentUser?.id.uuidString else {
            SecureLogger.warning("HouseholdRepository.pushSnapshot skipped — no authenticated user")
            return
        }

        let allMembers     = (try? context.fetch(FetchDescriptor<HouseholdMember>())) ?? []
        let allGroups      = (try? context.fetch(FetchDescriptor<HouseholdGroup>())) ?? []
        let allSettlements = (try? context.fetch(FetchDescriptor<HouseholdSettlement>())) ?? []

        // 1. Re-fetch the live envelope so iOS-owned keys survive
        //    (splitExpenses, sharedBudgets, sharedGoals) AND we know
        //    which entities cloud currently has — for the
        //    resurrection guard below.
        let envelopeRows: [EnvelopeRow] = try await client
            .from("household_state")
            .select("snapshot")
            .limit(1)
            .execute()
            .value

        let cloudMemberIds     = Self.idSet(in: envelopeRows.first?.snapshot, path: ["household", "members"])
        let cloudGroupIds      = Self.idSet(in: envelopeRows.first?.snapshot, path: ["household", "groups"])
        let cloudSettlementIds = Self.idSet(in: envelopeRows.first?.snapshot, path: ["settlements"])

        // 2. Filter each local list: keep if cloud-known OR fresh
        //    local. Skip entities that are old AND missing from
        //    cloud — those were deleted on another device.
        let members     = allMembers.filter     { cloudMemberIds.contains($0.id)     || $0.joinedAt > cutoff }
        let groups      = allGroups.filter      { cloudGroupIds.contains($0.id)      || $0.createdAt > cutoff }
        let settlements = allSettlements.filter { cloudSettlementIds.contains($0.id) || $0.createdAt > cutoff }

        let droppedMembers     = allMembers.count - members.count
        let droppedGroups      = allGroups.count - groups.count
        let droppedSettlements = allSettlements.count - settlements.count
        if droppedMembers + droppedGroups + droppedSettlements > 0 {
            SecureLogger.info("Skipped \(droppedMembers) member(s), \(droppedGroups) group(s), \(droppedSettlements) settlement(s) deleted on another device")
        }

        // 3. Build encoded household + settlements payload from the
        //    filtered set.
        let encodedHousehold = makeEncodedHousehold(
            ownerId: ownerId,
            members: members,
            groups: groups
        )
        let encodedSettlements = settlements.compactMap(makeEncodedSettlement(from:))

        // Round-trip Encodable → AnyJSON so we can splice into dict.
        let encoder = Self.iosEncoder
        let householdJSON   = try JSONDecoder().decode(AnyJSON.self, from: encoder.encode(encodedHousehold))
        let settlementsJSON = try JSONDecoder().decode(AnyJSON.self, from: encoder.encode(encodedSettlements))

        // 3. Merge into existing envelope (or build minimal one).
        let mergedEnvelope: AnyJSON
        if let existing = envelopeRows.first?.snapshot,
           case .object(var dict) = existing {
            dict["household"] = householdJSON
            dict["settlements"] = settlementsJSON
            // Don't touch splitExpenses / sharedBudgets / sharedGoals —
            // iOS owns those. Initialize if missing so iOS doesn't
            // crash on an undefined key (its decoder defaults `[]`).
            if dict["splitExpenses"] == nil { dict["splitExpenses"] = .array([]) }
            if dict["sharedBudgets"] == nil { dict["sharedBudgets"] = .array([]) }
            if dict["sharedGoals"]   == nil { dict["sharedGoals"]   = .array([]) }
            mergedEnvelope = .object(dict)
        } else {
            mergedEnvelope = .object([
                "household": householdJSON,
                "splitExpenses": .array([]),
                "settlements": settlementsJSON,
                "sharedBudgets": .array([]),
                "sharedGoals": .array([])
            ])
        }

        // 4. Upsert.
        let row = EnvelopePushRow(owner_id: ownerId, snapshot: mergedEnvelope)
        try await client
            .from("household_state")
            .upsert(row, onConflict: "owner_id")
            .execute()
        SecureLogger.info("Pushed household envelope: \(members.count) members, \(groups.count) groups, \(settlements.count) settlements")
    }

    // MARK: - Encode (macOS @Model → iOS-shape DTO)

    private func makeEncodedHousehold(
        ownerId: String,
        members: [HouseholdMember],
        groups: [HouseholdGroup]
    ) -> EncodedHousehold {
        // macOS has no parent Household entity. Synthesize one keyed
        // off the auth user id so the same Mac user always lands on
        // the same household record. iOS's createdBy is also a
        // userId — match.
        let householdId = ownerIdToUUID(ownerId)
        let earliest = members.map(\.joinedAt).min() ?? .now

        return EncodedHousehold(
            id: householdId.uuidString,
            name: "Household",
            createdBy: ownerId,
            members: members.map { makeEncodedMember(from: $0, ownerId: ownerId) },
            inviteCode: deterministicInviteCode(for: ownerId),
            groups: groups.map(makeEncodedGroup(from:)),
            createdAt: earliest,
            updatedAt: .now
        )
    }

    private func makeEncodedMember(from m: HouseholdMember, ownerId: String) -> EncodedMember {
        // iOS userId is required (real auth.uid() string for owner;
        // synthetic for non-owner virtual members). For the Mac
        // user's own member row we use the real ownerId; for the
        // others we use member.id.uuidString — stable + unique +
        // round-trips back to the same macOS member on pull.
        let userId = m.isOwner ? ownerId : m.id.uuidString

        return EncodedMember(
            id: m.id.uuidString,
            userId: userId,
            displayName: m.name,
            email: m.email ?? "",
            role: macOSRoleToIOS(m.role),
            joinedAt: m.joinedAt,
            sharedAccountIds: nil,
            shareTransactions: true,
            isActive: m.isActive,
            archivedAt: m.archivedAt,
            groupIds: m.groups.map { $0.id.uuidString }
        )
    }

    private func makeEncodedGroup(from g: HouseholdGroup) -> EncodedGroup {
        EncodedGroup(
            id: g.id.uuidString,
            name: g.name,
            colorHex: g.colorHex,
            memberIds: g.members.map { $0.id.uuidString },
            createdAt: g.createdAt
        )
    }

    private func makeEncodedSettlement(from s: HouseholdSettlement) -> EncodedSettlement? {
        // Settlements without resolvable members are local-junk; skip.
        guard let from = s.fromMember?.id.uuidString,
              let to   = s.toMember?.id.uuidString else { return nil }
        return EncodedSettlement(
            id: s.id.uuidString,
            householdId: ownerIdToUUID(AuthManager.shared.currentUser?.id.uuidString ?? "").uuidString,
            fromUserId: from,
            toUserId: to,
            amount: CloudHelpers.toCents(s.amount),
            note: s.note ?? "",
            date: s.date,
            relatedExpenseIds: [],
            createdAt: s.createdAt
        )
    }

    // MARK: - Decode (iOS-shape DTO → macOS @Model)

    private func makeMember(from dto: DecodedMember, id: UUID) -> HouseholdMember {
        let role = iOSRoleToMac(dto.role ?? "")
        let m = HouseholdMember(
            name: dto.displayName ?? "Member",
            email: (dto.email?.isEmpty == false) ? dto.email : nil,
            avatarColor: "3B82F6",
            isOwner: role == .owner,
            role: role,
            defaultSharePercent: nil
        )
        m.id = id
        applyMember(dto, to: m)
        return m
    }

    private func applyMember(_ dto: DecodedMember, to m: HouseholdMember) {
        m.name = dto.displayName ?? m.name
        if let email = dto.email, !email.isEmpty { m.email = email }
        let role = iOSRoleToMac(dto.role ?? "")
        m.role = role
        m.isOwner = (role == .owner)
        m.isActive = dto.isActive ?? m.isActive
        m.archivedAt = dto.archivedAt
        if let joined = dto.joinedAt { m.joinedAt = joined }
    }

    private func makeGroup(from dto: DecodedGroup, id: UUID, members: [HouseholdMember]) -> HouseholdGroup {
        let g = HouseholdGroup(
            name: dto.name ?? "Group",
            colorHex: dto.colorHex ?? "8B5CF6"
        )
        g.id = id
        if let created = dto.createdAt { g.createdAt = created }
        g.members = members
        return g
    }

    private func applyGroup(_ dto: DecodedGroup, to g: HouseholdGroup, members: [HouseholdMember]) {
        g.name = dto.name ?? g.name
        g.colorHex = dto.colorHex ?? g.colorHex
        if let created = dto.createdAt { g.createdAt = created }
        g.members = members
    }

    private func makeSettlement(
        from dto: DecodedSettlement,
        id: UUID,
        fromMember: HouseholdMember?,
        target: HouseholdMember?
    ) -> HouseholdSettlement {
        let amount = CloudHelpers.toDecimal(cents: dto.amount ?? 0)
        let s = HouseholdSettlement(
            amount: amount,
            date: dto.date ?? .now,
            note: (dto.note?.isEmpty == false) ? dto.note : nil,
            fromMember: fromMember,
            toMember: target,
            linkedTransaction: nil
        )
        s.id = id
        if let created = dto.createdAt { s.createdAt = created }
        return s
    }

    private func applySettlement(
        _ dto: DecodedSettlement,
        to s: HouseholdSettlement,
        from: HouseholdMember?,
        target: HouseholdMember?
    ) {
        s.amount = CloudHelpers.toDecimal(cents: dto.amount ?? 0)
        if let date = dto.date { s.date = date }
        s.note = (dto.note?.isEmpty == false) ? dto.note : nil
        s.fromMember = from
        s.toMember = target
        if let created = dto.createdAt { s.createdAt = created }
    }

    // MARK: - Role mapping

    /// macOS HouseholdRole → iOS wire format. Now 1:1 after Household Rebuild
    /// P4.1: macOS gained `.partner`/`.viewer` and legacy `.guest` collapses
    /// to `.viewer` (also handled by the computed accessor on
    /// `HouseholdMember.role`).
    private func macOSRoleToIOS(_ r: HouseholdRole) -> String {
        switch r {
        case .owner:        return "owner"
        case .partner:      return "partner"
        case .adult:        return "adult"
        case .child:        return "child"
        case .viewer, .guest: return "viewer"
        }
    }

    private func iOSRoleToMac(_ raw: String) -> HouseholdRole {
        switch raw {
        case "owner":   return .owner
        case "partner": return .partner
        case "adult":   return .adult
        case "child":   return .child
        case "viewer":  return .viewer
        default:        return .adult
        }
    }

    // MARK: - Helpers

    /// Deterministic UUID from the auth user id so the same Mac
    /// user always lands on the same household record id.
    private func ownerIdToUUID(_ ownerId: String) -> UUID {
        UUID(uuidString: ownerId) ?? UUID()
    }

    /// Stable invite code derived from the user's id so each Mac
    /// session generates the same one. iOS will overwrite this when
    /// it pushes — we just need a value that doesn't churn.
    private func deterministicInviteCode(for ownerId: String) -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        var hash = 0
        for c in ownerId.unicodeScalars { hash = (hash &* 31) &+ Int(c.value) }
        var out = ""
        var n = abs(hash)
        for _ in 0..<6 {
            let idx = chars.index(chars.startIndex, offsetBy: n % chars.count)
            out.append(chars[idx])
            n /= chars.count
            if n == 0 { n = abs(hash) }
        }
        return out
    }
}
