import Foundation
import SwiftData

/// Bridges Subscriptions to the real ledger. Until P3 there was no way for
/// a recorded subscription to actually create the matching expense
/// transaction — users had to remember the next payment date themselves
/// and manually log it. `markPaid` performs the round-trip in one place:
/// insert a Transaction, advance `nextPaymentDate` by the billing cycle,
/// and recalculate the linked account's balance.
enum SubscriptionService {

    /// Records a payment for `subscription` on `date` (defaulting to today),
    /// inserts the matching expense Transaction, and advances the
    /// subscription's `nextPaymentDate` by one billing cycle. Returns the
    /// inserted Transaction so callers can navigate or undo if needed.
    @discardableResult
    static func markPaid(
        _ subscription: Subscription,
        in context: ModelContext,
        on date: Date = .now
    ) -> Transaction {
        let category = lookupCategory(named: subscription.categoryName, in: context)

        let tx = Transaction(
            date: date,
            payee: subscription.serviceName,
            amount: subscription.amount,
            notes: "Subscription payment",
            isIncome: false,
            account: subscription.account,
            category: category
        )
        // Inherit household attribution from the subscription (P2).
        tx.householdMember = subscription.householdMember
            ?? HouseholdService.resolveMember(forPayee: subscription.serviceName, in: context)
        context.insert(tx)

        subscription.nextPaymentDate = nextDate(from: subscription.nextPaymentDate, cycle: subscription.billingCycle)
        subscription.updatedAt = .now

        if let account = subscription.account {
            BalanceService.recalculate(account: account)
        }

        return tx
    }

    // MARK: - Helpers

    /// Soft-link from a subscription's `categoryName` (a free-text field)
    /// to an existing `BudgetCategory`. We do not auto-create categories
    /// here — that would silently inflate the budget category list every
    /// time a user mistypes a name. If no match is found, the transaction
    /// is created uncategorized and the user can categorize it later.
    private static func lookupCategory(named name: String, in context: ModelContext) -> BudgetCategory? {
        let trimmed = TextNormalization.trimmed(name)
        guard !trimmed.isEmpty else { return nil }
        let descriptor = FetchDescriptor<BudgetCategory>()
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first { TextNormalization.equalsNormalized($0.name, trimmed) }
    }

    /// Step the supplied date forward by exactly one billing cycle. Kept
    /// here rather than on `BillingCycle` itself because that enum's
    /// stepper is private and intentionally tied to its monthly-projection
    /// logic — re-exposing it would risk drift between the two callers.
    private static func nextDate(from date: Date, cycle: BillingCycle) -> Date {
        let cal = Calendar.current
        switch cycle {
        case .weekly:    return cal.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
        case .biweekly:  return cal.date(byAdding: .weekOfYear, value: 2, to: date) ?? date
        case .monthly:   return cal.date(byAdding: .month,      value: 1, to: date) ?? date
        case .quarterly: return cal.date(byAdding: .month,      value: 3, to: date) ?? date
        case .semiannual:return cal.date(byAdding: .month,      value: 6, to: date) ?? date
        case .annual:    return cal.date(byAdding: .year,       value: 1, to: date) ?? date
        case .custom:    return cal.date(byAdding: .day,        value: 30, to: date) ?? date
        }
    }
}
