import Foundation

// ============================================================
// MARK: - HouseholdEngine (P5.3 — macOS mirror)
// ============================================================
//
// Mirror of `balance/Household/HouseholdEngine.swift` from the iOS project.
// Defines the canonical engine surface (spec §6) using macOS-native types
// (@Model classes for Household / HouseholdMember / ExpenseShare /
// HouseholdSettlement). Type names diverge from iOS where the macOS layer
// already had its own — `ExpenseShareMethod` here parallels iOS
// `ExpenseSplitMethod`; `HouseholdSettlement` here parallels iOS
// `Settlement`.
//
// NO CONFORMANCE YET. macOS `HouseholdService` needs the synthetic
// `Household` aggregate-creation pass (P4 deferred work) to run first —
// without an aggregate root, methods like `createHousehold` /
// `regenerateInviteCode` / `transferOwnership` have no anchor. Conformance
// extension lands as a follow-up sub-phase once that migration is in place.
// ============================================================

/// Strategy for archiving a member that still has open shares.
enum ArchiveStrategy: Hashable {
    case reassignOpenSharesTo(memberId: UUID)
    case waiveOpenShares
    case failIfOpenShares
}

enum ArchiveOutcome: Hashable {
    case archived
    case blockedByOpenShares(count: Int)
    case unknownMember
    case notPermitted
}

/// One row used by `recordSplit` to describe a member's contribution.
/// `value` is interpreted by `method`:
///   .equal    → ignored
///   .percent  → percent (0–100)
///   .exact    → cents
///   .shares   → integer weight
struct SplitLine: Hashable {
    let memberId: UUID
    let value: Double
}

/// Read-only summary of a household for dashboard / AI context. Mirrors iOS
/// `HouseholdSnapshot` field-for-field; cents-based amounts.
struct HouseholdSnapshot {
    let memberCount: Int
    let hasPartner: Bool
    let sharedSpending: Int
    let sharedBudget: Int
    let budgetUtilization: Double?
    let isOverBudget: Bool
    let unsettledCount: Int
    let unsettledAmount: Int
    let youOwe: Int
    let owedToYou: Int
    let activeSharedGoalCount: Int
    let topGoal: SharedGoal?
    let totalGoalProgress: Int
    let pendingInviteCount: Int

    var hasAlerts: Bool {
        isOverBudget || unsettledCount > 3 || youOwe > 0 || !hasPartner
    }

    /// One-line summary for dashboard / AI context. Mirrors iOS
    /// `HouseholdSnapshot.urgentSummary` field-for-field so cross-platform
    /// AI prompts read identical text.
    var urgentSummary: String? {
        if isOverBudget {
            return "Shared spending is over budget"
        }
        if youOwe > 0 {
            return "You have an unsettled balance"
        }
        if unsettledCount > 3 {
            return "\(unsettledCount) expenses need settling"
        }
        if !hasPartner && memberCount <= 1 {
            return "Invite your partner to get started"
        }
        return nil
    }
}

protocol HouseholdEngine {

    // MARK: 6.1 Lifecycle

    @discardableResult
    func createHousehold(name: String, ownerDisplayName: String) -> Household
    func deleteHousehold()
    @discardableResult
    func regenerateInviteCode() -> String

    // MARK: 6.2 Members

    @discardableResult
    func addMember(displayName: String, email: String, role: HouseholdRole) -> HouseholdMember?
    @discardableResult
    func updateMember(id: UUID, mutator: (HouseholdMember) -> Void) -> HouseholdMember?
    @discardableResult
    func archiveMember(id: UUID, strategy: ArchiveStrategy) -> ArchiveOutcome
    @discardableResult
    func restoreMember(id: UUID) -> Bool
    @discardableResult
    func transferOwnership(toMemberId: UUID) -> Bool

    // MARK: 6.3 Splits

    @discardableResult
    func recordSplit(
        transactionId: UUID,
        totalCents: Int,
        paidByMemberId: UUID,
        method: ExpenseShareMethod,
        lines: [SplitLine]
    ) -> [ExpenseShare]

    @discardableResult
    func editSplit(
        transactionId: UUID,
        totalCents: Int,
        paidByMemberId: UUID,
        method: ExpenseShareMethod,
        lines: [SplitLine]
    ) -> [ExpenseShare]

    func deleteSplit(transactionId: UUID)

    // MARK: 6.4 Settlement

    @discardableResult
    func settleUp(
        fromMemberId: UUID,
        toMemberId: UUID,
        amount: Int,
        materializeAsTransaction: Bool
    ) -> HouseholdSettlement?

    func unsettle(settlementId: UUID)

    // MARK: 6.5 Snapshot

    func snapshot(monthKey: String, currentMemberId: UUID) -> HouseholdSnapshot
}
