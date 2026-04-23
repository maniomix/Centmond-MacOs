import Foundation
import SwiftData

/// Launch-time repair pass for household-related references. Analog of
/// `CategoryReferenceRepair` + `NetWorthReferenceRepair`, namespaced to the
/// Household feature so each area's repair code stays findable.
///
/// What it handles:
/// • `ExpenseShare` rows whose `parentTransaction` is nil (orphaned after a
///   cascade delete that somehow half-completed) — hard-delete.
/// • `HouseholdSettlement` rows with neither `fromMember` nor `toMember` —
///   hard-delete (no one to attribute to).
/// • `ExpenseShare` rows with nil `member` but non-nil parent — can't
///   attribute to anyone, hard-delete.
/// • Stale shares on deleted transactions that survived deletion cascade.
///
/// Idempotent. Safe to call on every launch. Cheap — scans at most the full
/// share + settlement count, both of which stay small in practice.
enum HouseholdReferenceRepair {
    @discardableResult
    static func run(context: ModelContext) -> Int {
        var removed = 0

        // Archive was dropped in favor of hard-delete (user decision
        // 2026-04-21: "add delete member insteat of archive"). Purge any
        // pre-existing archived members so the picker + hub stop showing
        // duplicates like "Mani, Ali, Mani, Ali" from legacy archive cycles.
        if let members = try? context.fetch(FetchDescriptor<HouseholdMember>()) {
            for m in members where !m.isActive {
                context.delete(m)
                removed += 1
            }
        }

        // Orphan shares: no parent OR no member.
        if let shares = try? context.fetch(FetchDescriptor<ExpenseShare>()) {
            for share in shares {
                if share.parentTransaction == nil || share.member == nil {
                    context.delete(share)
                    removed += 1
                }
            }
        }

        // Settlements with both member pointers nil — nothing to show, nothing
        // to reconcile against. Still keep settlements where one side is nil
        // (e.g. member archived but history remains) because they're historical.
        if let settlements = try? context.fetch(FetchDescriptor<HouseholdSettlement>()) {
            for s in settlements where s.fromMember == nil && s.toMember == nil {
                context.delete(s)
                removed += 1
            }
        }

        // HouseholdGroup rows with empty members + no name drift — harmless,
        // leave alone. A zero-member group is a valid "awaiting assignment"
        // state, not an error.

        if removed > 0 {
            context.persist()
        }
        return removed
    }
}
