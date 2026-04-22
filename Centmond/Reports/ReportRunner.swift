import Foundation
import SwiftData

// Thin glue between SwiftData and the pure ReportEngine. Fetches
// every array the engine cares about, assembles `Inputs`, runs it.
// Centralized so the hub and the detail view share one execution path.

@MainActor
enum ReportRunner {

    static func run(_ def: ReportDefinition, context: ModelContext, currencyCode: String = "USD") -> ReportResult {
        let inputs = ReportEngine.Inputs(
            transactions:        fetch(Transaction.self,         context: context),
            accounts:            fetch(Account.self,             context: context),
            categories:          fetch(BudgetCategory.self,      context: context),
            netWorthSnapshots:   fetch(NetWorthSnapshot.self,    context: context),
            subscriptions:       fetch(Subscription.self,        context: context),
            recurring:           fetch(RecurringTransaction.self, context: context),
            goals:               fetch(Goal.self,                context: context),
            goalContributions:   fetch(GoalContribution.self,    context: context),
            monthlyBudgets:      fetch(MonthlyBudget.self,       context: context),
            monthlyTotalBudgets: fetch(MonthlyTotalBudget.self,  context: context),
            currencyCode: currencyCode
        )
        return ReportEngine.run(def, inputs: inputs)
    }

    private static func fetch<T: PersistentModel>(_: T.Type, context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }
}
