import SwiftUI

// ============================================================
// MARK: - Financial Insight Model
// ============================================================

struct FinancialInsight: Identifiable, Decodable, Equatable {
    var id: String { category }
    let category: String
    let spent: Double
    let budget: Double
    let status: InsightStatus
    let advice: String

    enum InsightStatus: String, Decodable {
        case danger
        case warning
        case safe
    }

    var progress: Double {
        guard budget > 0 else { return spent > 0 ? 1.0 : 0 }
        return min(spent / budget, 1.5) // cap at 150% for visual
    }

    var statusColor: Color {
        switch status {
        case .danger:  return Color(red: 1.0, green: 0.28, blue: 0.28)
        case .warning: return Color(red: 1.0, green: 0.72, blue: 0.2)
        case .safe:    return Color(red: 0.3, green: 0.85, blue: 0.45)
        }
    }

    var icon: String {
        let lower = category.lowercased()
        switch lower {
        case "groceries", "grocery":     return "cart.fill"
        case "shopping":                 return "bag.fill"
        case "dining", "restaurant":     return "fork.knife"
        case "health", "medical":        return "heart.fill"
        case "transport", "transportation", "gas": return "car.fill"
        case "entertainment":            return "tv.fill"
        case "bills", "utilities":       return "bolt.fill"
        case "subscriptions":            return "arrow.clockwise"
        case "rent", "housing":          return "house.fill"
        case "education":               return "book.fill"
        case "savings":                  return "banknote.fill"
        case "income", "salary":         return "dollarsign.circle.fill"
        default:                         return "creditcard.fill"
        }
    }
}

// ============================================================
// MARK: - Insight Parser
// ============================================================

enum InsightParser {

    private static let separator = "---INSIGHTS---"

    /// Extract insights JSON from an AI response, if present.
    /// Returns (cleanedText, insights). If no insights block, returns nil insights.
    static func parse(_ response: String) -> (text: String, insights: [FinancialInsight]?) {
        guard let range = response.range(of: separator, options: .caseInsensitive) else {
            return (response, nil)
        }

        let textPart = String(response[response.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var jsonPart = String(response[range.upperBound...])

        // Strip ---ACTIONS--- and everything after (insights come before actions)
        if let actionsRange = jsonPart.range(of: "---ACTIONS---", options: .caseInsensitive) {
            jsonPart = String(jsonPart[jsonPart.startIndex..<actionsRange.lowerBound])
        }

        jsonPart = jsonPart
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonPart.data(using: .utf8),
              let insights = try? JSONDecoder().decode([FinancialInsight].self, from: data),
              !insights.isEmpty else {
            return (textPart, nil)
        }

        return (textPart, insights)
    }

    /// Try to extract insights from plain text (fallback when model doesn't output JSON).
    /// Looks for patterns like "Category — You've spent $X" or "Category: $X against $Y budget"
    static func extractFromText(_ text: String) -> [FinancialInsight]? {
        var insights: [FinancialInsight] = []

        // Pattern: "• **Category** — ... $Amount ... $Budget ..."
        let pattern = #"\*\*([A-Za-z]+)\*\*\s*[—–:-]\s*.*?\$(\d[\d,.]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let category = nsText.substring(with: match.range(at: 1))
            let amountStr = nsText.substring(with: match.range(at: 2)).replacingOccurrences(of: ",", with: "")
            guard let spent = Double(amountStr) else { continue }

            // Try to find budget amount in the same line
            let fullLine = nsText.substring(with: match.range(at: 0))
            let budgetPattern = #"budget[:\s]*\$?(\d[\d,.]*)"#
            var budget = spent * 1.2 // default: assume budget is 120% of spent
            if let budgetRegex = try? NSRegularExpression(pattern: budgetPattern, options: .caseInsensitive) {
                let budgetMatches = budgetRegex.matches(in: fullLine, range: NSRange(location: 0, length: fullLine.count))
                if let bm = budgetMatches.first, bm.numberOfRanges >= 2 {
                    let bStr = (fullLine as NSString).substring(with: bm.range(at: 1)).replacingOccurrences(of: ",", with: "")
                    if let b = Double(bStr) { budget = b }
                }
            }

            let status: FinancialInsight.InsightStatus
            if spent > budget { status = .danger }
            else if spent > budget * 0.8 { status = .warning }
            else { status = .safe }

            insights.append(FinancialInsight(
                category: category,
                spent: spent,
                budget: budget,
                status: status,
                advice: "" // text-based extraction doesn't get advice
            ))
        }

        return insights.isEmpty ? nil : insights
    }
}

// ============================================================
// MARK: - Insight Dashboard View
// ============================================================

struct AIInsightDashboard: View {
    let title: String
    let insights: [FinancialInsight]
    let markdownText: String

    @State private var appeared = false
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──
            dashboardHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .opacity(0.2)
                .padding(.horizontal, 12)

            // ── Summary text (if any) ──
            if !markdownText.isEmpty {
                Text(summaryLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
            }

            // ── Card Grid ──
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(insights.enumerated()), id: \.element.id) { index, insight in
                    InsightCardView(insight: insight)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 15)
                        .scaleEffect(appeared ? 1 : 0.92)
                        .animation(
                            .spring(response: 0.45, dampingFraction: 0.75)
                                .delay(Double(index) * 0.08),
                            value: appeared
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: 580, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .fill(.ultraThinMaterial)
                .centmondShadow(2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            DS.Colors.accent.opacity(0.2),
                            Color.white.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .onAppear {
            withAnimation {
                appeared = true
            }
        }
    }

    // MARK: - Header

    private var dashboardHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.Colors.accent)

            Text(title.isEmpty ? "Financial Overview" : title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Spacer()

            Text("Centmond AI")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)

            Image(systemName: "sparkles")
                .font(CentmondTheme.Typography.micro)
                .foregroundStyle(DS.Colors.accent.opacity(0.5))
        }
    }

    /// Extract the first sentence from markdown text as a summary
    private var summaryLine: String {
        let plain = markdownText
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "##", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = plain.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.first ?? ""
    }
}

// ============================================================
// MARK: - Individual Insight Card
// ============================================================

struct InsightCardView: View {
    let insight: FinancialInsight
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: icon + category + status dot
            HStack(spacing: 6) {
                Image(systemName: insight.icon)
                    .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
                    .foregroundStyle(insight.statusColor)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                            .fill(insight.statusColor.opacity(0.12))
                    )

                Text(insight.category)
                    .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Circle()
                    .fill(insight.statusColor)
                    .frame(width: 6, height: 6)
            }

            // Amount display
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(CurrencyFormat.abbreviated(insight.spent))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(insight.statusColor)

                if insight.budget > 0 {
                    Text("/ $\(insight.budget, specifier: "%.0f")")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous)
                        .fill(Color.primary.opacity(0.06))

                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [insight.statusColor.opacity(0.7), insight.statusColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, min(geo.size.width, geo.size.width * insight.progress)))
                }
            }
            .frame(height: 5)

            // Advice text (if available)
            if !insight.advice.isEmpty {
                Text(insight.advice
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "`", with: ""))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .fill(Color(.controlBackgroundColor).opacity(isHovered ? 1 : 0.7))
                .shadow(
                    color: insight.statusColor.opacity(isHovered ? 0.12 : 0),
                    radius: 6, y: 2
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                .strokeBorder(
                    insight.statusColor.opacity(isHovered ? 0.25 : 0.08),
                    lineWidth: 0.5
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
