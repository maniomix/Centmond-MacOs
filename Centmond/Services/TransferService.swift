import Foundation
import SwiftData

/// Creates and tears down paired transfer transactions. A transfer is
/// modeled as two `Transaction` rows sharing the same `transferGroupID`,
/// both flagged `isTransfer == true`:
///   - the *out* leg sits on the source account, `isIncome == false`
///   - the *in* leg sits on the destination account, `isIncome == true`
///
/// Transfers should not affect income/expense totals — `BalanceService`
/// (P1.5) is the only place that needs to know to exclude them.
enum TransferService {

    /// Create both legs of a transfer in one transaction. Returns the
    /// (out, in) pair on success, or `nil` if the inputs are invalid
    /// (same account on both sides, non-positive amount, etc).
    @discardableResult
    static func createTransfer(
        amount: Decimal,
        date: Date,
        from source: Account,
        to destination: Account,
        notes: String?,
        in context: ModelContext
    ) -> (out: Transaction, `in`: Transaction)? {
        guard amount > 0 else { return nil }
        guard source.id != destination.id else { return nil }

        let group = UUID()
        let trimmedNotes = notes.flatMap(TextNormalization.trimmedOrNil)

        let outLeg = Transaction(
            date: date,
            payee: "Transfer to \(destination.name)",
            amount: amount,
            notes: trimmedNotes,
            isIncome: false,
            account: source,
            category: nil
        )
        outLeg.isTransfer = true
        outLeg.transferGroupID = group

        let inLeg = Transaction(
            date: date,
            payee: "Transfer from \(source.name)",
            amount: amount,
            notes: trimmedNotes,
            isIncome: true,
            account: destination,
            category: nil
        )
        inLeg.isTransfer = true
        inLeg.transferGroupID = group

        context.insert(outLeg)
        context.insert(inLeg)
        BalanceService.recalculate(source, destination)
        return (outLeg, inLeg)
    }

    /// Find the other leg of a transfer pair, if any. Returns `nil` for
    /// non-transfer transactions or for orphaned legs whose pair has
    /// already been deleted.
    static func pairedLeg(of tx: Transaction, in context: ModelContext) -> Transaction? {
        guard tx.isTransfer, let group = tx.transferGroupID else { return nil }
        let txID = tx.id
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.transferGroupID == group && $0.id != txID }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Delete a transfer leg together with its pair, so the two halves
    /// can never drift apart. For non-transfer transactions this just
    /// deletes the single row.
    static func deletePair(_ tx: Transaction, in context: ModelContext) {
        let otherAccount = pairedLeg(of: tx, in: context)?.account
        let txAccount = tx.account
        if let other = pairedLeg(of: tx, in: context) {
            context.delete(other)
        }
        context.delete(tx)
        BalanceService.recalculate(txAccount, otherAccount)
    }
}
