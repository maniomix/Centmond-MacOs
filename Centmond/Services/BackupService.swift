import Foundation
import SwiftData

/// Centralized data export and full-wipe routines.
///
/// Backups currently focus on Transactions — the entity users care about most for
/// portability and the only one referenced by `ExportSheet`. The wipe routine, by
/// contrast, must cover every persisted entity so "Delete All Data" actually means
/// what it says (the previous Settings implementation only cleared a few prefs).
enum BackupService {

    // MARK: - Export options

    struct ExportOptions {
        var format: ExportFormat
        var dateRange: ExportDateRange
        var includeCategories: Bool
        var includeAccounts: Bool
        var includeNotes: Bool
        var includeHouseholdMembers: Bool = true
    }

    // MARK: - Transaction export

    /// Builds a serialized export of transactions matching the provided options.
    /// Returns the file extension and the encoded `Data` ready to write to disk.
    static func exportTransactions(
        options: ExportOptions,
        in context: ModelContext
    ) throws -> (fileExtension: String, data: Data) {
        let fetch = FetchDescriptor<Transaction>(
            sortBy: [SortDescriptor(\Transaction.date, order: .reverse)]
        )
        let all = (try? context.fetch(fetch)) ?? []
        let filtered = all.filter { tx in
            dateRangeContains(options.dateRange, date: tx.date)
        }

        switch options.format {
        case .csv:
            let csv = encodeCSV(filtered, options: options)
            return ("csv", Data(csv.utf8))
        case .json:
            let json = try encodeJSON(filtered, options: options)
            return ("json", json)
        }
    }

    private static func dateRangeContains(_ range: ExportDateRange, date: Date) -> Bool {
        let cal = Calendar.current
        let now = Date.now
        switch range {
        case .allTime:
            return true
        case .thisMonth:
            return cal.isDate(date, equalTo: now, toGranularity: .month)
        case .lastThreeMonths:
            guard let cutoff = cal.date(byAdding: .month, value: -3, to: now) else { return true }
            return date >= cutoff
        case .thisYear:
            return cal.isDate(date, equalTo: now, toGranularity: .year)
        }
    }

    // MARK: - CSV

    private static func encodeCSV(_ txs: [Transaction], options: ExportOptions) -> String {
        var headers = ["Date", "Payee", "Amount", "Type"]
        if options.includeCategories { headers.append("Category") }
        if options.includeAccounts { headers.append("Account") }
        if options.includeHouseholdMembers { headers.append("Member") }
        if options.includeNotes { headers.append("Notes") }
        headers.append("Transfer")

        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withFullDate]

        var lines: [String] = [headers.joined(separator: ",")]
        for tx in txs {
            var fields: [String] = [
                dateFmt.string(from: tx.date),
                csvEscape(tx.payee),
                NSDecimalNumber(decimal: tx.amount).stringValue,
                tx.isIncome ? "income" : "expense"
            ]
            if options.includeCategories { fields.append(csvEscape(tx.category?.name ?? "")) }
            if options.includeAccounts { fields.append(csvEscape(tx.account?.name ?? "")) }
            if options.includeHouseholdMembers { fields.append(csvEscape(tx.householdMember?.name ?? "")) }
            if options.includeNotes { fields.append(csvEscape(tx.notes ?? "")) }
            fields.append(tx.isTransfer ? "yes" : "")
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return s
    }

    // MARK: - JSON

    private struct TransactionDTO: Encodable {
        let id: UUID
        let date: Date
        let payee: String
        let amount: String
        let isIncome: Bool
        let status: String
        let isReviewed: Bool
        let isTransfer: Bool
        let transferGroupID: UUID?
        let category: String?
        let account: String?
        let householdMember: String?
        let notes: String?
        let tags: [String]
    }

    private static func encodeJSON(_ txs: [Transaction], options: ExportOptions) throws -> Data {
        let dtos: [TransactionDTO] = txs.map { tx in
            TransactionDTO(
                id: tx.id,
                date: tx.date,
                payee: tx.payee,
                amount: NSDecimalNumber(decimal: tx.amount).stringValue,
                isIncome: tx.isIncome,
                status: tx.status.rawValue,
                isReviewed: tx.isReviewed,
                isTransfer: tx.isTransfer,
                transferGroupID: tx.transferGroupID,
                category: options.includeCategories ? tx.category?.name : nil,
                account: options.includeAccounts ? tx.account?.name : nil,
                householdMember: tx.householdMember?.name,
                notes: options.includeNotes ? tx.notes : nil,
                tags: tx.tags.map(\.name)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(dtos)
    }

    // MARK: - Wipe

    /// Deletes every persisted entity from the SwiftData store. Used by
    /// Settings → Data → Delete All Data. The previous implementation only
    /// touched UserDefaults, leaving the database fully intact — that was a
    /// silent footgun for users trying to start over.
    ///
    /// **CLOUD POLICY (intentional, do not "fix"):** this wipe propagates
    /// to cloud. CloudSyncCoordinator's willSave hook auto-queues every
    /// deletion below; the next push (2 s debounce) drains the queue and
    /// also pushes empty snapshots for `subscription_state` and
    /// `household_state`. The cloud row set ends up empty across all
    /// tables, then realtime fans out to every other signed-in device.
    /// A user clicking "Delete All Data" expects a global reset — if we
    /// only wiped local, the next sign-in would just re-pull everything
    /// and undo the intent.
    static func wipeAllData(in context: ModelContext) {
        SecureLogger.info("BackupService.wipeAllData starting — will propagate to cloud + all signed-in devices")
        deleteAll(Transaction.self, in: context)
        deleteAll(TransactionSplit.self, in: context)
        deleteAll(Account.self, in: context)
        deleteAll(BudgetCategory.self, in: context)
        deleteAll(MonthlyBudget.self, in: context)
        deleteAll(MonthlyTotalBudget.self, in: context)
        deleteAll(Goal.self, in: context)
        deleteAll(Subscription.self, in: context)
        deleteAll(RecurringTransaction.self, in: context)
        deleteAll(DismissedInsight.self, in: context)
        deleteAll(HouseholdMember.self, in: context)
        deleteAll(Tag.self, in: context)
        deleteAll(SmartFolder.self, in: context)

        context.persist()

        // Reset companion preferences so the user lands on a clean onboarding state.
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        UserDefaults.standard.set(false, forKey: "appLockEnabled")
        UserDefaults.standard.set("", forKey: "appPasscode")
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) {
        let descriptor = FetchDescriptor<T>()
        if let items = try? context.fetch(descriptor) {
            for item in items {
                context.delete(item)
            }
        }
    }
}
