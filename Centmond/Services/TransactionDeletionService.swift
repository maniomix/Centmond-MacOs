import Foundation
import SwiftData

/// Centralized delete path for Transactions. Every caller MUST route through
/// here so goal contributions that reference the transaction are removed
/// first — otherwise goal balances drift after a deletion.
enum TransactionDeletionService {
    static func delete(_ transaction: Transaction, context: ModelContext) {
        GoalContributionService.removeContributions(forTransactionID: transaction.id, context: context)
        context.delete(transaction)
    }

    static func delete(_ transactions: [Transaction], context: ModelContext) {
        for tx in transactions {
            GoalContributionService.removeContributions(forTransactionID: tx.id, context: context)
            context.delete(tx)
        }
    }
}
