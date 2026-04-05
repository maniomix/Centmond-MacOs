import SwiftUI

struct SheetRouter: View {
    let sheet: SheetType

    var body: some View {
        Group {
            switch sheet {
            case .newTransaction:
                NewTransactionSheet()
            case .newAccount:
                NewAccountSheet()
            case .newGoal:
                NewGoalSheet()
            case .newSubscription:
                NewSubscriptionSheet()
            case .newBudgetCategory:
                NewBudgetCategorySheet()
            case .newRecurring:
                NewRecurringSheet()
            case .importCSV:
                ImportCSVSheet()
            case .splitTransaction(let transaction):
                SplitTransactionSheet(transaction: transaction)
            case .proUpgrade:
                ProUpgradeSheet()
            case .export:
                ExportSheet()
            case .editAccount(let account):
                EditAccountSheet(account: account)
            case .editGoal(let goal):
                EditGoalSheet(goal: goal)
            case .editSubscription(let subscription):
                EditSubscriptionSheet(subscription: subscription)
            case .editRecurring(let item):
                EditRecurringSheet(item: item)
            case .budgetPlanner:
                BudgetPlannerSheet()
            }
        }
        .frame(width: sheet.isCompact ? 360 : CentmondTheme.Sizing.sheetWidth)
        .background(CentmondTheme.Colors.bgTertiary)
        .preferredColorScheme(.dark)
    }
}
