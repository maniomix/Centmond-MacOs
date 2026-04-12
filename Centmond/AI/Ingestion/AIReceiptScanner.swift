import Foundation
import AppKit
import Vision
import os

// ============================================================
// MARK: - AI Receipt Scanner
// ============================================================
//
// Uses Apple Vision framework to OCR receipts and extract:
//   - Total amount
//   - Merchant/store name
//   - Date
//   - Individual line items (best-effort)
//
// Runs entirely on-device -- no data leaves the Mac.
//
// macOS Centmond: NSImage instead of UIImage, @Observable,
// amounts in dollars (Double) instead of cents (Int).
//
// ============================================================

private let logger = Logger(subsystem: "com.centmond", category: "AIReceiptScanner")

struct ReceiptData: Equatable {
    var merchantName: String?
    var totalAmount: Double?
    var date: Date?
    var lineItems: [LineItem]
    var rawText: String

    struct LineItem: Equatable, Identifiable {
        let id = UUID()
        let description: String
        let amount: Double
    }
}

@MainActor @Observable
final class AIReceiptScanner {
    static let shared = AIReceiptScanner()

    var isScanning: Bool = false
    var lastResult: ReceiptData?
    var errorMessage: String?

    private init() {}

    // MARK: - Scan

    func scan(image: NSImage) async -> ReceiptData? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMessage = "Invalid image"
            return nil
        }

        isScanning = true
        errorMessage = nil

        let recognizedText = await performOCR(cgImage: cgImage)

        guard !recognizedText.isEmpty else {
            isScanning = false
            errorMessage = "No text found in image"
            return nil
        }

        let rawText = recognizedText.joined(separator: "\n")
        let result = parseReceipt(lines: recognizedText, rawText: rawText)

        lastResult = result
        isScanning = false
        return result
    }

    // MARK: - Vision OCR

    private func performOCR(cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let lines = observations.compactMap { observation -> String? in
                    observation.topCandidates(1).first?.string
                }
                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "de-DE", "fa-IR"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                logger.error("OCR failed: \(error.localizedDescription)")
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - Receipt Parsing

    private func parseReceipt(lines: [String], rawText: String) -> ReceiptData {
        var merchantName: String?
        var totalAmount: Double?
        var date: Date?
        var lineItems: [ReceiptData.LineItem] = []

        for line in lines.prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 3 && !isNumericLine(trimmed) && !isDateLine(trimmed) {
                merchantName = trimmed
                break
            }
        }

        let totalPatterns = [
            "(?:total|sum|gesamt|summe|amount due|balance due|to pay)\\s*[:\\-]?\\s*[$€]?\\s*([\\d.,]+)",
            "[$€]\\s*([\\d.,]+)\\s*(?:total|sum|gesamt)"
        ]
        for line in lines.reversed() {
            let lower = line.lowercased()
            for pattern in totalPatterns {
                if let amount = extractAmountWithPattern(pattern, from: lower) {
                    totalAmount = amount
                    break
                }
            }
            if totalAmount != nil { break }
        }

        if totalAmount == nil {
            var maxAmount: Double = 0
            for line in lines {
                if let amount = extractAnyAmount(from: line), amount > maxAmount {
                    maxAmount = amount
                }
            }
            if maxAmount > 0 { totalAmount = maxAmount }
        }

        for line in lines {
            if let d = extractDate(from: line) {
                date = d
                break
            }
        }

        let itemPattern = "^(.+?)\\s+[$€]?([\\d]+[.,][\\d]{2})\\s*$"
        if let regex = try? NSRegularExpression(pattern: itemPattern) {
            for line in lines {
                let range = NSRange(line.startIndex..., in: line)
                if let match = regex.firstMatch(in: line, range: range) {
                    if let descRange = Range(match.range(at: 1), in: line),
                       let amtRange = Range(match.range(at: 2), in: line) {
                        let desc = String(line[descRange]).trimmingCharacters(in: .whitespaces)
                        let amtStr = String(line[amtRange]).replacingOccurrences(of: ",", with: ".")
                        if let value = Double(amtStr) {
                            if value != totalAmount && desc.count >= 2 {
                                lineItems.append(ReceiptData.LineItem(description: desc, amount: value))
                            }
                        }
                    }
                }
            }
        }

        return ReceiptData(
            merchantName: merchantName,
            totalAmount: totalAmount,
            date: date,
            lineItems: lineItems,
            rawText: rawText
        )
    }

    // MARK: - Extraction Helpers

    private func extractAmountWithPattern(_ pattern: String, from text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }

        let amtStr = String(text[range])
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)

        return Double(amtStr)
    }

    private func extractAnyAmount(from line: String) -> Double? {
        let pattern = "[$€]\\s*([\\d]+[.,][\\d]{2})|([\\d]+[.,][\\d]{2})\\s*[$€]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        for i in 1...2 {
            let range = match.range(at: i)
            if range.location != NSNotFound, let r = Range(range, in: line) {
                let amtStr = String(line[r]).replacingOccurrences(of: ",", with: ".")
                if let value = Double(amtStr) { return value }
            }
        }
        return nil
    }

    private func extractDate(from line: String) -> Date? {
        let patterns = [
            "\\b(\\d{1,2})[./\\-](\\d{1,2})[./\\-](\\d{2,4})\\b",
            "\\b(\\d{4})[./\\-](\\d{1,2})[./\\-](\\d{1,2})\\b"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                continue
            }

            let df = DateFormatter()
            let fullRange = match.range(at: 0)
            guard let r = Range(fullRange, in: line) else { continue }
            let dateStr = String(line[r])

            for fmt in ["dd/MM/yyyy", "MM/dd/yyyy", "dd.MM.yyyy", "yyyy-MM-dd", "dd-MM-yyyy"] {
                df.dateFormat = fmt
                if let d = df.date(from: dateStr) { return d }
            }
        }
        return nil
    }

    private func isNumericLine(_ line: String) -> Bool {
        let digits = line.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "$" || $0 == "€" }
        return digits.count > line.count / 2
    }

    private func isDateLine(_ line: String) -> Bool {
        extractDate(from: line) != nil
    }

    // MARK: - Convert to Action

    func toAction(from receipt: ReceiptData, categoryName: String? = nil) -> AIAction? {
        guard let amount = receipt.totalAmount else { return nil }

        let category: String
        if let cat = categoryName {
            category = cat
        } else if let merchant = receipt.merchantName {
            category = AICategorySuggester.shared.suggest(note: merchant) ?? "Other"
        } else {
            category = "Other"
        }

        let dateStr: String
        if let d = receipt.date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            dateStr = f.string(from: d)
        } else {
            dateStr = "today"
        }

        return AIAction(
            type: .addTransaction,
            params: AIAction.ActionParams(
                amount: amount,
                category: category,
                note: receipt.merchantName ?? "Receipt scan",
                date: dateStr,
                transactionType: "expense"
            )
        )
    }
}
