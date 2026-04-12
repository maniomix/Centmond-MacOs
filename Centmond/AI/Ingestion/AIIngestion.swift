import Foundation
import SwiftData

// ============================================================
// MARK: - AI Autonomous Ingestion
// ============================================================
//
// Unified ingestion layer that brings financial data into the
// app from pasted text, statement rows, and receipt-style input.
//
// Flow:
//   raw text -> parse -> normalize -> detect flags -> stage -> review -> import
//
// Detects:
//   - merchant normalization
//   - category suggestions
//   - duplicates
//   - recurring/subscription candidates
//   - transfer candidates
//
// macOS Centmond: @Observable, ModelContext, Decimal/Double amounts,
// category names instead of Category enum, payee instead of note.
//
// ============================================================

// MARK: - Ingestion Models

enum IngestionSourceType: String, Codable, CaseIterable, Identifiable {
    case pastedStatement     = "pasted_statement"
    case pastedTransactions  = "pasted_transactions"
    case receiptText         = "receipt_text"
    case genericText         = "generic_text"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pastedStatement:    return "Bank Statement"
        case .pastedTransactions: return "Transaction List"
        case .receiptText:        return "Receipt Text"
        case .genericText:        return "Generic Text"
        }
    }

    var icon: String {
        switch self {
        case .pastedStatement:    return "doc.text"
        case .pastedTransactions: return "list.bullet.clipboard"
        case .receiptText:        return "receipt"
        case .genericText:        return "text.alignleft"
        }
    }
}

struct IngestionSession: Identifiable {
    let id: UUID
    let sourceType: IngestionSourceType
    let rawInput: String
    var candidates: [CandidateTransaction]
    var status: SessionStatus
    let startedAt: Date
    var completedAt: Date?
    let groupId: UUID

    var parseErrors: [String] = []

    var approvedCount: Int { candidates.filter { $0.approval == .approved }.count }
    var rejectedCount: Int { candidates.filter { $0.approval == .rejected }.count }
    var pendingCount: Int { candidates.filter { $0.approval == .pending }.count }
    var flaggedCount: Int { candidates.filter(\.requiresReview).count }
    var duplicateCount: Int { candidates.filter(\.isDuplicateSuspect).count }

    var safeToAutoApprove: [CandidateTransaction] {
        candidates.filter { $0.confidence >= 0.75 && !$0.requiresReview && $0.approval == .pending }
    }

    enum SessionStatus: String {
        case parsing
        case staged
        case importing
        case completed
        case failed
    }
}

struct CandidateTransaction: Identifiable {
    let id: UUID
    let rawText: String
    var merchant: String
    var normalizedMerchant: String
    var amount: Double                    // dollars
    var date: Date
    var transactionType: CandidateType
    var categoryName: String?
    var categoryConfidence: Double

    var confidence: Double

    var isDuplicateSuspect: Bool = false
    var duplicateOfId: UUID?
    var duplicateConfidence: Double = 0
    var duplicateReason: String?

    var isRecurringSuspect: Bool = false
    var recurringHint: String?

    var isSubscriptionSuspect: Bool = false
    var subscriptionHint: String?

    var isTransferSuspect: Bool = false
    var transferAccountHint: String?

    var requiresReview: Bool = false
    var reviewReasons: [String] = []

    var approval: ApprovalStatus = .pending

    enum ApprovalStatus: String {
        case pending
        case approved
        case rejected
    }

    enum CandidateType: String {
        case expense
        case income
    }
}

struct IngestionImportResult {
    let importedCount: Int
    let failedCount: Int
    let skippedCount: Int
    let summary: String
}

// MARK: - Merchant Normalizer

enum MerchantNormalizer {

    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        let prefixes = [
            "POS ", "POS-", "PURCHASE ", "CARD ", "DEBIT ", "DIRECT ",
            "CCD ", "ACH ", "EFT ", "PREAUTH ", "CHECKCARD ", "VISA ",
            "MC ", "MASTERCARD ", "AMEX ", "PAYPAL *", "SQ *", "TST* ",
            "PP*", "SP ", "GOOGLE *", "APPLE.COM/", "AMZN MKTP ",
        ]
        for prefix in prefixes {
            if text.uppercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }

        let trailingPatterns = [
            #"[\s\-]*#\d{2,}.*$"#,
            #"[\s\-]*\*\d{3,}.*$"#,
            #"\s+STORE\s*\d+.*$"#,
            #"\s+STR\s*\d+.*$"#,
            #"\s+-\s*[A-Z]{2}\s*$"#,
            #"\s+\d{5,}$"#,
            #"\s+[A-Z]{2}\s+\d{5}$"#,
            #"\s+\d{2}/\d{2}$"#,
            #"\s+xx+\d{4}$"#,
        ]
        for pattern in trailingPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            }
        }

        text = text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text == text.uppercased() && text.count > 2 {
            text = text.capitalized
        }

        return text
    }

    static func areSameMerchant(_ a: String, _ b: String) -> Bool {
        let na = normalize(a).lowercased()
        let nb = normalize(b).lowercased()

        if na == nb { return true }
        if na.isEmpty || nb.isEmpty { return false }

        let minLen = min(na.count, nb.count, 8)
        guard minLen >= 4 else { return false }
        let prefixA = String(na.prefix(minLen))
        let prefixB = String(nb.prefix(minLen))
        if prefixA == prefixB { return true }

        let wordsA = Set(na.split(separator: " ").map(String.init))
        let wordsB = Set(nb.split(separator: " ").map(String.init))
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return false }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union) >= 0.6
    }

    static let subscriptionMerchants: Set<String> = [
        "netflix", "spotify", "apple music", "youtube premium", "youtube",
        "disney", "disney+", "hbo", "hulu", "amazon prime", "prime video",
        "adobe", "microsoft 365", "microsoft", "office 365",
        "dropbox", "google one", "google storage", "icloud",
        "chatgpt", "openai", "claude", "anthropic",
        "gym", "fitness", "planet fitness", "anytime fitness",
        "nordvpn", "expressvpn", "surfshark",
        "audible", "kindle", "scribd",
        "crunchyroll", "paramount", "peacock", "apple tv",
    ]

    static let transferKeywords: [String] = [
        "transfer", "xfer", "internal", "own account",
        "savings", "checking", "credit card payment",
        "payment to", "payment from", "self",
    ]
}

// MARK: - Text Parser

enum IngestionTextParser {

    struct ParsedRow {
        let rawText: String
        let merchant: String
        let amount: Double       // dollars
        let date: Date?
        let isIncome: Bool
        let isReceiptTotal: Bool
    }

    static func parse(_ text: String) -> [ParsedRow] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        if isReceiptText(lines) {
            return parseReceipt(lines)
        }

        return lines.compactMap { parseLine($0) }
    }

    // MARK: - Line Parsing

    private static func parseLine(_ line: String) -> ParsedRow? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }

        guard let amountResult = extractAmount(from: trimmed) else { return nil }
        let dateResult = extractDate(from: trimmed)

        var merchantText = trimmed
        merchantText = removePattern(amountResult.matched, from: merchantText)
        if let dateMatch = dateResult?.matched {
            merchantText = removePattern(dateMatch, from: merchantText)
        }

        merchantText = merchantText
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "|-\u{2013}\u{2014}\u{2022}\u{00B7},;")))
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !merchantText.isEmpty || amountResult.dollars > 0 else { return nil }

        return ParsedRow(
            rawText: trimmed,
            merchant: merchantText.isEmpty ? "Unknown" : merchantText,
            amount: amountResult.dollars,
            date: dateResult?.date,
            isIncome: amountResult.isNegative,
            isReceiptTotal: false
        )
    }

    // MARK: - Receipt Detection

    private static func isReceiptText(_ lines: [String]) -> Bool {
        let joined = lines.joined(separator: " ").lowercased()
        let receiptKeywords = ["total", "subtotal", "tax", "change", "receipt", "thank you"]
        let matchCount = receiptKeywords.filter { joined.contains($0) }.count
        return matchCount >= 2
    }

    private static func parseReceipt(_ lines: [String]) -> [ParsedRow] {
        var merchant = "Receipt"
        for line in lines.prefix(5) {
            let lower = line.lowercased()
            if lower.count >= 3,
               extractAmount(from: line) == nil,
               extractDate(from: line) == nil,
               !lower.contains("receipt"),
               !lower.contains("invoice") {
                merchant = line
                break
            }
        }

        var totalAmount: Double?
        let totalKeywords = ["total", "sum", "amount due", "balance", "grand total"]
        for line in lines.reversed() {
            let lower = line.lowercased()
            if totalKeywords.contains(where: { lower.contains($0) }),
               let amt = extractAmount(from: line) {
                totalAmount = amt.dollars
                break
            }
        }

        if totalAmount == nil {
            var maxAmt: Double = 0
            for line in lines.suffix(5) {
                if let amt = extractAmount(from: line), amt.dollars > maxAmt {
                    maxAmt = amt.dollars
                }
            }
            if maxAmt > 0 { totalAmount = maxAmt }
        }

        var receiptDate: Date?
        for line in lines {
            if let dr = extractDate(from: line) {
                receiptDate = dr.date
                break
            }
        }

        guard let total = totalAmount, total > 0 else { return [] }

        return [ParsedRow(
            rawText: lines.joined(separator: "\n"),
            merchant: merchant,
            amount: total,
            date: receiptDate,
            isIncome: false,
            isReceiptTotal: true
        )]
    }

    // MARK: - Amount Extraction

    struct AmountResult {
        let dollars: Double
        let isNegative: Bool
        let matched: String
    }

    static func extractAmount(from text: String) -> AmountResult? {
        let patterns = [
            #"(-?\$\s*[\d,]+\.?\d{0,2})"#,
            #"(-?[\d.]+,\d{2}\s*[€£])"#,
            #"(-?[\d.]+,\d{2})\s*(?:€|EUR|eur)"#,
            #"(?:^|[\s\-|])(-?\d{1,6}\.\d{2})(?:$|[\s\-|])"#,
            #"(?:^|[\s\-|])(-?\d{1,6},\d{2})(?:$|[\s\-|])"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)

            if let match = regex.firstMatch(in: text, range: range) {
                let matchRange = match.range(at: 1)
                guard let swiftRange = Range(matchRange, in: text) else { continue }
                let raw = String(text[swiftRange])

                if let dollars = parseAmountToDollars(raw) {
                    return AmountResult(
                        dollars: abs(dollars),
                        isNegative: dollars < 0 || raw.contains("-"),
                        matched: raw
                    )
                }
            }
        }
        return nil
    }

    private static func parseAmountToDollars(_ raw: String) -> Double? {
        var cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "EUR", with: "")
            .replacingOccurrences(of: "eur", with: "")
            .trimmingCharacters(in: .whitespaces)

        let isNegative = cleaned.hasPrefix("-")
        cleaned = cleaned.replacingOccurrences(of: "-", with: "")

        if cleaned.contains(",") {
            if cleaned.contains(".") && cleaned.lastIndex(of: ",")! > cleaned.lastIndex(of: ".")! {
                cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            } else if !cleaned.contains(".") {
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            }
        }

        cleaned = cleaned.replacingOccurrences(of: ",", with: "")

        guard let value = Double(cleaned) else { return nil }
        return isNegative ? -value : value
    }

    // MARK: - Date Extraction

    struct DateResult {
        let date: Date
        let matched: String
    }

    static func extractDate(from text: String) -> DateResult? {
        let patterns: [(String, String)] = [
            (#"\b(\d{4}-\d{2}-\d{2})\b"#, "yyyy-MM-dd"),
            (#"\b(\d{1,2}/\d{1,2}/\d{4})\b"#, "M/d/yyyy"),
            (#"\b(\d{1,2}\.\d{1,2}\.\d{4})\b"#, "dd.MM.yyyy"),
            (#"\b(\d{1,2}/\d{1,2}/\d{2})\b"#, "M/d/yy"),
            (#"\b((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2})\b"#, "MMM d"),
        ]

        for (pattern, format) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)

            if let match = regex.firstMatch(in: text, range: range) {
                let matchRange = match.range(at: 1)
                guard let swiftRange = Range(matchRange, in: text) else { continue }
                let dateStr = String(text[swiftRange])

                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = format

                if var date = df.date(from: dateStr) {
                    if format == "MMM d" {
                        let cal = Calendar.current
                        var comps = cal.dateComponents([.month, .day], from: date)
                        comps.year = cal.component(.year, from: Date())
                        date = cal.date(from: comps) ?? date
                    }
                    return DateResult(date: date, matched: dateStr)
                }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func removePattern(_ pattern: String, from text: String) -> String {
        guard !pattern.isEmpty else { return text }
        return text.replacingOccurrences(of: pattern, with: "")
    }
}

// MARK: - Ingestion Engine

@MainActor @Observable
final class AIIngestionEngine {
    static let shared = AIIngestionEngine()

    var activeSession: IngestionSession?

    private init() {}

    // MARK: - Public API

    func ingest(rawText: String, sourceType: IngestionSourceType, context: ModelContext) -> IngestionSession {
        let groupId = UUID()

        let parsedRows = IngestionTextParser.parse(rawText)

        var candidates = parsedRows.map { row in
            buildCandidate(from: row)
        }

        detectDuplicates(&candidates, context: context)
        detectRecurring(&candidates, context: context)
        detectSubscriptions(&candidates, context: context)
        detectTransfers(&candidates, context: context)
        computeConfidenceAndFlags(&candidates)

        let session = IngestionSession(
            id: UUID(),
            sourceType: sourceType,
            rawInput: rawText,
            candidates: candidates,
            status: candidates.isEmpty ? .failed : .staged,
            startedAt: Date(),
            groupId: groupId,
            parseErrors: candidates.isEmpty ? ["No transactions could be parsed from this text."] : []
        )

        activeSession = session
        return session
    }

    func autoApproveSafe() {
        guard var session = activeSession else { return }
        for i in session.candidates.indices {
            let c = session.candidates[i]
            if c.confidence >= 0.75 && !c.requiresReview && c.approval == .pending {
                session.candidates[i].approval = .approved
            }
        }
        activeSession = session
    }

    func toggleApproval(_ candidateId: UUID) {
        guard var session = activeSession else { return }
        guard let idx = session.candidates.firstIndex(where: { $0.id == candidateId }) else { return }

        switch session.candidates[idx].approval {
        case .pending, .rejected:
            session.candidates[idx].approval = .approved
        case .approved:
            session.candidates[idx].approval = .rejected
        }
        activeSession = session
    }

    func setApproval(_ candidateId: UUID, to status: CandidateTransaction.ApprovalStatus) {
        guard var session = activeSession else { return }
        guard let idx = session.candidates.firstIndex(where: { $0.id == candidateId }) else { return }
        session.candidates[idx].approval = status
        activeSession = session
    }

    func importApproved(context: ModelContext) async -> IngestionImportResult {
        guard var session = activeSession else {
            return IngestionImportResult(importedCount: 0, failedCount: 0, skippedCount: 0,
                                         summary: "No active session")
        }

        session.status = .importing
        activeSession = session

        let approved = session.candidates.filter { $0.approval == .approved }
        let skipped = session.candidates.count - approved.count

        var imported = 0
        var failed = 0

        for candidate in approved {
            let action = candidateToAction(candidate)
            let result = await AIActionExecutor.execute(action, context: context)

            if result.success {
                imported += 1
                AIActionHistory.shared.record(
                    action: action,
                    result: result,
                    trustDecision: nil,
                    classification: nil,
                    groupId: session.groupId,
                    groupLabel: "Import: \(session.sourceType.title)",
                    isAutoExecuted: candidate.confidence >= 0.75
                )

                if let catName = candidate.categoryName {
                    AIMerchantMemory.shared.learnFromTransaction(
                        note: candidate.normalizedMerchant,
                        category: catName,
                        amount: candidate.amount
                    )
                }
            } else {
                failed += 1
            }
        }

        session.status = .completed
        session.completedAt = Date()
        activeSession = session

        let summary = "Imported \(imported) transaction(s)" +
            (failed > 0 ? ", \(failed) failed" : "") +
            (skipped > 0 ? ", \(skipped) skipped" : "")

        return IngestionImportResult(
            importedCount: imported,
            failedCount: failed,
            skippedCount: skipped,
            summary: summary
        )
    }

    func dismiss() {
        activeSession = nil
    }

    // MARK: - Candidate Builder

    private func buildCandidate(from row: IngestionTextParser.ParsedRow) -> CandidateTransaction {
        let normalized = MerchantNormalizer.normalize(row.merchant)

        var categoryName: String?
        var catConfidence: Double = 0

        if let memorySuggestion = AIMemoryRetrieval.suggestCategory(for: normalized) {
            categoryName = memorySuggestion.category
            catConfidence = memorySuggestion.confidence
        }

        return CandidateTransaction(
            id: UUID(),
            rawText: row.rawText,
            merchant: row.merchant,
            normalizedMerchant: normalized,
            amount: row.amount,
            date: row.date ?? Date(),
            transactionType: row.isIncome ? .income : .expense,
            categoryName: categoryName,
            categoryConfidence: catConfidence,
            confidence: 0
        )
    }

    // MARK: - Duplicate Detection

    private func detectDuplicates(_ candidates: inout [CandidateTransaction], context: ModelContext) {
        let descriptor = FetchDescriptor<Transaction>()
        guard let existing = try? context.fetch(descriptor) else { return }
        let cal = Calendar.current

        for i in candidates.indices {
            let c = candidates[i]

            for ex in existing {
                var matchScore: Double = 0
                var reasons: [String] = []

                let exAmount = NSDecimalNumber(decimal: ex.amount).doubleValue
                let diff = abs(c.amount - exAmount)
                if diff < 1.0 {
                    matchScore += 0.3
                    if diff < 0.01 { matchScore += 0.1; reasons.append("exact amount") }
                    else { reasons.append("similar amount") }
                } else { continue }

                if cal.isDate(c.date, inSameDayAs: ex.date) {
                    matchScore += 0.3; reasons.append("same date")
                } else {
                    let dayDiff = abs(cal.dateComponents([.day], from: c.date, to: ex.date).day ?? 99)
                    if dayDiff <= 1 { matchScore += 0.15; reasons.append("+/-1 day") }
                }

                if MerchantNormalizer.areSameMerchant(c.normalizedMerchant, ex.payee) {
                    matchScore += 0.3; reasons.append("same merchant")
                }

                if matchScore >= 0.5 {
                    candidates[i].isDuplicateSuspect = true
                    candidates[i].duplicateOfId = ex.id
                    candidates[i].duplicateConfidence = min(matchScore, 0.95)
                    candidates[i].duplicateReason = reasons.joined(separator: ", ")
                    break
                }
            }
        }

        for i in candidates.indices {
            for j in (i + 1)..<candidates.count {
                if abs(candidates[i].amount - candidates[j].amount) < 0.01,
                   Calendar.current.isDate(candidates[i].date, inSameDayAs: candidates[j].date),
                   MerchantNormalizer.areSameMerchant(candidates[i].normalizedMerchant, candidates[j].normalizedMerchant) {
                    candidates[j].isDuplicateSuspect = true
                    candidates[j].duplicateReason = "duplicate within this import"
                    candidates[j].duplicateConfidence = 0.8
                }
            }
        }
    }

    // MARK: - Recurring Detection

    private func detectRecurring(_ candidates: inout [CandidateTransaction], context: ModelContext) {
        let descriptor = FetchDescriptor<RecurringTransaction>()
        let existing = (try? context.fetch(descriptor)) ?? []

        for i in candidates.indices {
            let c = candidates[i]
            for rec in existing {
                if MerchantNormalizer.areSameMerchant(c.normalizedMerchant, rec.name) {
                    let recAmount = NSDecimalNumber(decimal: rec.amount).doubleValue
                    let amountMatch = abs(c.amount - recAmount) < max(1.0, recAmount * 0.1)
                    if amountMatch {
                        candidates[i].isRecurringSuspect = true
                        candidates[i].recurringHint = "Matches recurring: \(rec.name)"
                        break
                    }
                }
            }
        }
    }

    // MARK: - Subscription Detection

    private func detectSubscriptions(_ candidates: inout [CandidateTransaction], context: ModelContext) {
        let activeStatus = SubscriptionStatus.active
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.status == activeStatus }
        )
        let knownSubs = (try? context.fetch(descriptor)) ?? []

        for i in candidates.indices {
            let c = candidates[i]
            let lower = c.normalizedMerchant.lowercased()

            if MerchantNormalizer.subscriptionMerchants.contains(where: { lower.contains($0) }) {
                candidates[i].isSubscriptionSuspect = true
                candidates[i].subscriptionHint = "Looks like a subscription service"
            }

            for sub in knownSubs {
                if MerchantNormalizer.areSameMerchant(c.normalizedMerchant, sub.serviceName) {
                    candidates[i].isSubscriptionSuspect = true
                    candidates[i].subscriptionHint = "Matches subscription: \(sub.serviceName)"
                    if !candidates[i].isRecurringSuspect {
                        candidates[i].isRecurringSuspect = true
                        candidates[i].recurringHint = "Known subscription charge"
                    }
                    break
                }
            }
        }
    }

    // MARK: - Transfer Detection

    private func detectTransfers(_ candidates: inout [CandidateTransaction], context: ModelContext) {
        let descriptor = FetchDescriptor<Account>()
        let accounts = (try? context.fetch(descriptor)) ?? []
        let accountNames = accounts.map { $0.name.lowercased() }

        for i in candidates.indices {
            let lower = candidates[i].normalizedMerchant.lowercased()

            let hasTransferKeyword = MerchantNormalizer.transferKeywords.contains { lower.contains($0) }
            let matchesAccount = accountNames.first { name in
                lower.contains(name) || MerchantNormalizer.areSameMerchant(lower, name)
            }

            if hasTransferKeyword || matchesAccount != nil {
                candidates[i].isTransferSuspect = true
                if let acct = matchesAccount {
                    candidates[i].transferAccountHint = "May be a transfer to/from: \(acct)"
                } else {
                    candidates[i].transferAccountHint = "Contains transfer-related keywords"
                }
            }
        }
    }

    // MARK: - Confidence + Review Flags

    private func computeConfidenceAndFlags(_ candidates: inout [CandidateTransaction]) {
        for i in candidates.indices {
            var conf: Double = 0.5
            var reasons: [String] = []

            let c = candidates[i]

            if c.amount > 0 { conf += 0.1 }
            if IngestionTextParser.extractDate(from: c.rawText) != nil { conf += 0.1 }
            if c.categoryName != nil { conf += c.categoryConfidence * 0.2 }
            if !c.normalizedMerchant.isEmpty && c.normalizedMerchant != "Unknown" { conf += 0.1 }

            if c.isDuplicateSuspect { conf -= 0.25; reasons.append("Possible duplicate") }
            if c.isTransferSuspect { conf -= 0.15; reasons.append("May be a transfer") }
            if c.amount == 0 { conf -= 0.3; reasons.append("Zero amount") }
            if c.normalizedMerchant == "Unknown" || c.normalizedMerchant.isEmpty {
                conf -= 0.2; reasons.append("Unknown merchant")
            }

            let needsReview = conf < 0.6
                || c.isDuplicateSuspect
                || c.isTransferSuspect
                || c.categoryName == nil
                || (c.categoryName != nil && c.categoryConfidence < 0.5)

            if c.categoryName == nil { reasons.append("No category suggestion") }
            if c.categoryName != nil && c.categoryConfidence < 0.5 { reasons.append("Low category confidence") }

            candidates[i].confidence = max(0, min(1, conf))
            candidates[i].requiresReview = needsReview
            candidates[i].reviewReasons = reasons
        }
    }

    // MARK: - Conversion

    private func candidateToAction(_ candidate: CandidateTransaction) -> AIAction {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        return AIAction(
            type: .addTransaction,
            params: AIAction.ActionParams(
                amount: candidate.amount,
                category: candidate.categoryName ?? "Other",
                note: candidate.normalizedMerchant,
                date: df.string(from: candidate.date),
                transactionType: candidate.transactionType == .income ? "income" : "expense"
            )
        )
    }
}
