import SwiftUI

struct SheetRouter: View {
    let sheet: SheetType
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch sheet {
            case .newTransaction:
                NewTransactionSheet()
            case .newTransfer:
                NewTransferSheet()
            case .newAccount:
                NewAccountSheet()
            case .newGoal:
                NewGoalSheet()
            case .newSubscription:
                NewSubscriptionSheet()
            case .detectedSubscriptions:
                DetectedSubscriptionsSheet()
            case .detectedRecurring:
                DetectedRecurringSheet()
            case .newBudgetCategory:
                NewBudgetCategorySheet()
            case .newRecurring:
                NewRecurringSheet()
            case .importCSV:
                #if os(macOS)
                ImportCSVSheet()
                #else
                Text("CSV import coming to iOS").padding()
                #endif
            case .splitTransaction(let transaction):
                SplitTransactionSheet(transaction: transaction)
            case .proUpgrade:
                ProUpgradeSheet()
            case .export:
                #if os(macOS)
                ExportSheet()
                #else
                Text("Export coming to iOS").padding()
                #endif
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
            case .shareTransaction(let transaction):
                HouseholdShareSheet(transaction: transaction)
            case .householdSettleUp:
                HouseholdSettleUpSheet()
            }
        }
        .frame(width: sheet.preferredWidth)
        .background {
            // Tap-to-dismiss: any click not consumed by a form control
            // (rows, buttons, fields, menus, pickers) bubbles to this
            // background and closes the sheet. Mirrors the shell-level
            // empty-click behavior for persistent panels.
            CentmondTheme.Colors.bgTertiary
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
        }
        .themedColorScheme()
        .dismissOnEscape()
    }
}
