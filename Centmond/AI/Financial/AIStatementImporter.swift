import Foundation
import SwiftData

// ============================================================
// MARK: - AI Statement Importer
// ============================================================
//
// Parses CSV/text bank statement data into staged transactions
// for review.
//
// Flow: raw text -> parse -> normalize -> deduplicate -> stage -> review
//
// Low-confidence entries are flagged for manual review.
// Supports common bank CSV formats and tab-separated data.
//
// macOS Centmond: ModelContext for duplicate checks,
// amounts in dollars (Double) instead of cents (Int),
// AICategorySuggester returns String (category name).
//
// ============================================================

struct StagedTransaction: Identifiable {
    let id = UUID()
    let date: Date
    let amount: Double
    let rawDescription: String
    let normalizedMerchant: String
    let suggestedCategory: String
    let categoryConfidence: Double
    var status: ReviewStatus = .pending
    var isDuplicate: Bool = false

    enum ReviewStatus: String {
        case pending
        case approved
        case rejected
        case modified
    }

    var transactionType: String {
        amount >= 0 ? "expense" : "income"
    }
}

struct ImportResult {
    let staged: [StagedTransaction]
    let duplicateCount: Int
    let lowConfidenceCount: Int
    let parseErrors: [String]

    var summary: String {
        var lines: [String] = []
        lines.append("Parsed \(staged.count) transactions")
        if duplicateCount > 0 {
            lines.append("  \(duplicateCount) potential duplicate(s)")
        }
        if lowConfidenceCount > 0 {
            lines.append("  \(lowConfidenceCount) need category review")
        }
        if !parseErrors.isEmpty {
            lines.append("  \(parseErrors.count) line(s) couldn't be parsed")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor @Observable
final class AIStatementImporter {
    static let shared = AIStatementImporter()

    private init() {}

    // MARK: - Parse CSV/Text

    func parseStatement(_ rawText: String, context: ModelContext) -> ImportResult {
        let lines = rawText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return ImportResult(staged: [], duplicateCount: 0, lowConfidenceCount: 0,
                                parseErrors: ["Empty input"])
        }

        let delimiter = detectDelimiter(lines)
        let (dataLines, columnMap) = detectColumns(lines, delimiter: delimiter)

        var staged: [StagedTransaction] = []
        var errors: [String] = []

        for line in dataLines {
            let fields = splitLine(line, delimiter: delimiter)
            if let txn = parseLine(fields: fields, columnMap: columnMap) {
                staged.append(txn)
            } else {
                errors.append("Could not parse: \(String(line.prefix(60)))...")
            }
        }

        // Deduplicate against existing transactions
        let descriptor = FetchDescriptor<Transaction>()
        let existing = (try? context.fetch(descriptor)) ?? []
        let duplicateCount = markDuplicates(&staged, existing: existing)

        let lowConfidenceCount = staged.filter { $0.categoryConfidence < 0.5 }.count

        return ImportResult(
            staged: staged,
            duplicateCount: duplicateCount,
            lowConfidenceCount: lowConfidenceCount,
            parseErrors: errors
        )
    }

    func toActions(_ staged: [StagedTransaction]) -> [AIAction] {
        staged.filter { $0.status == .approved || $0.status == .modified }
            .map { txn in
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                return AIAction(
                    type: .addTransaction,
                    params: AIAction.ActionParams(
                        amount: abs(txn.amount),
                        category: txn.suggestedCategory,
                        note: txn.normalizedMerchant,
                        date: df.string(from: txn.date),
                        transactionType: txn.transactionType
                    )
                )
            }
    }

    // MARK: - Parsing Helpers

    private func detectDelimiter(_ lines: [String]) -> Character {
        let first = lines.prefix(3).joined()
        let commaCount = first.filter { $0 == "," }.count
        let tabCount = first.filter { $0 == "\t" }.count
        let semiCount = first.filter { $0 == ";" }.count

        if tabCount > commaCount && tabCount > semiCount { return "\t" }
        if semiCount > commaCount { return ";" }
        return ","
    }

    private func detectColumns(_ lines: [String], delimiter: Character) -> ([String], ColumnMap) {
        guard let header = lines.first else {
            return (lines, ColumnMap())
        }

        let fields = splitLine(header, delimiter: delimiter).map { $0.lowercased() }
        var map = ColumnMap()

        for (i, f) in fields.enumerated() {
            if f.contains("date") || f.contains("datum") {
                map.dateIndex = i
            }
            if f.contains("amount") || f.contains("betrag") ||
               f.contains("sum") || f.contains("value") {
                map.amountIndex = i
            }
            if f.contains("description") || f.contains("merchant") || f.contains("payee") ||
               f.contains("memo") || f.contains("name") ||
               f.contains("detail") || f.contains("beschreibung") {
                map.descriptionIndex = i
            }
            if f.contains("debit") { map.debitIndex = i }
            if f.contains("credit") { map.creditIndex = i }
            if f.contains("category") { map.categoryIndex = i }
        }

        if map.dateIndex != nil && (map.amountIndex != nil || map.descriptionIndex != nil) {
            return (Array(lines.dropFirst()), map)
        }

        map.dateIndex = 0
        map.descriptionIndex = 1
        map.amountIndex = fields.count > 2 ? 2 : 1
        return (lines, map)
    }

    private func parseLine(fields: [String], columnMap: ColumnMap) -> StagedTransaction? {
        guard let dateIdx = columnMap.dateIndex, dateIdx < fields.count,
              let date = parseDate(fields[dateIdx]) else { return nil }

        var amount: Double?
        if let amtIdx = columnMap.amountIndex, amtIdx < fields.count {
            amount = parseAmount(fields[amtIdx])
        } else if let debIdx = columnMap.debitIndex, debIdx < fields.count {
            amount = parseAmount(fields[debIdx])
            if (amount == nil || amount == 0), let credIdx = columnMap.creditIndex, credIdx < fields.count {
                if let credit = parseAmount(fields[credIdx]) {
                    amount = -credit
                }
            }
        }
        guard let finalAmount = amount, finalAmount != 0 else { return nil }

        let rawDesc: String
        if let descIdx = columnMap.descriptionIndex, descIdx < fields.count {
            rawDesc = fields[descIdx]
        } else {
            rawDesc = fields.filter { !$0.isEmpty }.joined(separator: " ")
        }

        let normalized = normalizeMerchant(rawDesc)
        let (category, confidence) = suggestCategory(normalized)

        return StagedTransaction(
            date: date,
            amount: finalAmount,
            rawDescription: rawDesc,
            normalizedMerchant: normalized,
            suggestedCategory: category,
            categoryConfidence: confidence
        )
    }

    private func splitLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == delimiter && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    // MARK: - Date Parsing

    private func parseDate(_ raw: String) -> Date? {
        let formats = [
            "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "dd.MM.yyyy",
            "yyyy/MM/dd", "M/d/yyyy", "d/M/yyyy", "dd-MM-yyyy",
            "yyyy.MM.dd", "MMM d, yyyy", "d MMM yyyy"
        ]
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")

        for format in formats {
            df.dateFormat = format
            if let date = df.date(from: trimmed) { return date }
        }
        return nil
    }

    // MARK: - Amount Parsing

    private func parseAmount(_ raw: String) -> Double? {
        var cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.contains(",") && cleaned.contains(".") {
            if let commaIdx = cleaned.lastIndex(of: ","),
               let dotIdx = cleaned.lastIndex(of: ".") {
                if commaIdx > dotIdx {
                    cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                        .replacingOccurrences(of: ",", with: ".")
                } else {
                    cleaned = cleaned.replacingOccurrences(of: ",", with: "")
                }
            }
        } else if cleaned.contains(",") {
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        }

        if cleaned.hasPrefix("(") && cleaned.hasSuffix(")") {
            cleaned = "-" + cleaned.dropFirst().dropLast()
        }

        return Double(cleaned)
    }

    // MARK: - Merchant Normalization

    private func normalizeMerchant(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let patterns = [
            "\\b[A-Z0-9]{10,}\\b",
            "\\bREF:\\s*\\S+",
            "\\b\\d{6,}\\b",
            "\\bPOS\\b",
            "\\bVISA\\b|\\bMC\\b"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result,
                    range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Category Suggestion

    private func suggestCategory(_ merchant: String) -> (String, Double) {
        if let cat = AICategorySuggester.shared.suggest(note: merchant) {
            return (cat, 0.8)
        }
        return ("Other", 0.2)
    }

    // MARK: - Duplicate Detection

    private func markDuplicates(_ staged: inout [StagedTransaction], existing: [Transaction]) -> Int {
        var count = 0
        for i in staged.indices {
            let txn = staged[i]
            let isDupe = existing.contains { ex in
                let exAmount = NSDecimalNumber(decimal: ex.amount).doubleValue
                return exAmount == abs(txn.amount) &&
                    Calendar.current.isDate(ex.date, inSameDayAs: txn.date) &&
                    (ex.payee.lowercased().contains(String(txn.normalizedMerchant.lowercased().prefix(5))) ||
                     txn.normalizedMerchant.lowercased().contains(String(ex.payee.lowercased().prefix(5))))
            }
            if isDupe {
                staged[i].isDuplicate = true
                count += 1
            }
        }
        return count
    }
}

// MARK: - Column Map

private struct ColumnMap {
    var dateIndex: Int?
    var amountIndex: Int?
    var descriptionIndex: Int?
    var debitIndex: Int?
    var creditIndex: Int?
    var categoryIndex: Int?
}
