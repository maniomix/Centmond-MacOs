import MarkdownUI
import Splash
import SwiftUI

// MARK: - Splash Code Syntax Highlighter

struct SplashCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private let syntaxHighlighter: SyntaxHighlighter<AttributedStringOutputFormat>

    init() {
        let theme = Theme.midnight(withFont: .init(size: 13))
        self.syntaxHighlighter = SyntaxHighlighter(format: AttributedStringOutputFormat(theme: theme))
    }

    func highlightCode(_ code: String, language: String?) -> Text {
        let highlighted = syntaxHighlighter.highlight(code)
        return Text(AttributedString(highlighted))
    }
}

// MARK: - Centmond Markdown Theme

extension MarkdownUI.Theme {
    static let centmondDark = MarkdownUI.Theme.gitHub
        .text {
            ForegroundColor(Color(.labelColor).opacity(0.75))
            FontSize(12.5)
        }
        .paragraph { configuration in
            configuration.label
                .lineSpacing(8)
                .markdownMargin(top: 32, bottom: 32)
        }
        .listItem { configuration in
            configuration.label
                .lineSpacing(8)
                .markdownMargin(top: 18, bottom: 18)
        }
        .list { configuration in
            ListCardWrapper { configuration.label }
                .markdownMargin(top: 18, bottom: 18)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.heavy)
                    FontSize(22)
                    ForegroundColor(DS.Colors.accent)
                }
                .markdownMargin(top: 6, bottom: 14)
        }
        .heading2 { configuration in
            VStack(alignment: .leading, spacing: 0) {
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(17)
                        ForegroundColor(DS.Colors.accent)
                    }
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs)
                    .fill(DS.Colors.accent.opacity(0.3))
                    .frame(height: 2)
                    .padding(.top, 6)
            }
            .markdownMargin(top: 4, bottom: 16)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(17)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 14, bottom: 8)
        }
        .strong {
            ForegroundColor(DS.Colors.accent)
            FontWeight(.bold)
        }
        .link {
            ForegroundColor(DS.Colors.accent)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(11.5)
            ForegroundColor(DS.Colors.accent)
            BackgroundColor(DS.Colors.accent.opacity(0.08))
        }
}

// ============================================================
// MARK: - Chat Bubble View (Premium Card Design)
// ============================================================

struct ChatBubbleView: View {
    let message: AIMessage
    let colorScheme: ColorScheme
    let groupActions: ([AIAction]) -> [AIChatView.ActionGroup]
    let onConfirm: (UUID) -> Void
    let onReject: (UUID) -> Void
    var onEditMessage: ((UUID, String) -> Void)? = nil

    @State private var appeared = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var isHovering = false
    @State private var copiedFlash = false

    /// Parsed insights (if the response contains structured financial data)
    private var parsedInsights: (text: String, insights: [FinancialInsight]?) {
        guard message.role == .assistant else { return (message.content, nil) }

        // 1. Try ---INSIGHTS--- JSON block
        let parsed = InsightParser.parse(message.content)
        if let insights = parsed.insights {
            return (parsed.text, insights)
        }

        // 2. Fallback: try to extract from markdown text
        if let extracted = InsightParser.extractFromText(message.content), extracted.count >= 2 {
            return (message.content, extracted)
        }

        return (message.content, nil)
    }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            if message.role == .assistant {
                let parsed = parsedInsights
                if let insights = parsed.insights {
                    // Text above dashboard cards (with category capsules)
                    if !stripInsightsHeading(parsed.text).isEmpty {
                        assistantTextBubble(stripInsightsHeading(parsed.text), insights: insights)
                    }

                    // Dashboard cards below
                    AIInsightDashboard(
                        title: extractTitle(from: parsed.text),
                        insights: insights,
                        markdownText: parsed.text
                    )
                } else {
                    // Regular markdown mode
                    assistantBubble
                }
                messageActionsRow
            } else {
                userBubble
                if !isEditing { messageActionsRow }
            }

            // Action cards
            if let actions = message.actions, !actions.isEmpty {
                let grouped = groupActions(actions)
                ForEach(grouped, id: \.id) { group in
                    if group.count > 1 {
                        GroupedActionCard(
                            actions: group.actions,
                            onConfirmAll: {
                                for a in group.actions where a.status == .pending {
                                    onConfirm(a.id)
                                }
                            },
                            onRejectAll: {
                                for a in group.actions {
                                    onReject(a.id)
                                }
                            }
                        )
                    } else if let action = group.actions.first {
                        AIActionCard(action: action) { id in
                            onConfirm(id)
                        } onReject: { id in
                            onReject(id)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                appeared = true
            }
        }
        .onHover { isHovering = $0 }
    }

    // MARK: - Message Actions Row (hover-revealed)

    private var messageActionsRow: some View {
        HStack(spacing: 4) {
            actionPill(
                icon: copiedFlash ? "checkmark" : "doc.on.doc",
                label: copiedFlash ? "Copied" : "Copy"
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                withAnimation(.easeInOut(duration: 0.15)) { copiedFlash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeInOut(duration: 0.2)) { copiedFlash = false }
                }
            }

            if message.role == .user, onEditMessage != nil {
                actionPill(icon: "pencil", label: "Edit") {
                    editText = message.content
                    isEditing = true
                }
            }
        }
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: copiedFlash)
        .padding(.top, 2)
    }

    private func actionPill(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(CentmondTheme.Typography.overlineSemibold)
                Text(label)
                    .font(CentmondTheme.Typography.overlineSemibold)
            }
            .foregroundStyle(DS.Colors.subtext)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isEditing {
                // Edit mode
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $editText)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 36, maxHeight: 120)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                                .fill(DS.Colors.accent.opacity(0.8))
                        )

                    HStack(spacing: 8) {
                        Button {
                            isEditing = false
                        } label: {
                            Text("Cancel")
                                .font(CentmondTheme.Typography.captionSmall.weight(.medium))
                                .foregroundStyle(DS.Colors.subtext)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(DS.Colors.surface2))
                        }
                        .buttonStyle(.plain)

                        Button {
                            let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            isEditing = false
                            onEditMessage?(message.id, trimmed)
                        } label: {
                            Text("Send")
                                .font(CentmondTheme.Typography.captionSmallSemibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(DS.Colors.accent))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                // Normal display
                Text(message.content)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                            .fill(DS.Colors.accent.gradient)
                    )
                    .contextMenu {
                        if onEditMessage != nil {
                            Button {
                                editText = message.content
                                isEditing = true
                            } label: {
                                Label("Edit Message", systemImage: "pencil")
                            }

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.content, forType: .string)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Assistant Bubble (Premium Card)

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sparkle header strip
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
                    .foregroundStyle(DS.Colors.accent)
                Text("Centmond AI")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Colors.accent.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .opacity(0.3)
                .padding(.horizontal, 12)

            // Markdown content with capsules
            CapsuleMarkdownView(text: AssistantTextSanitizer.sanitize(message.content))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: 560, alignment: .leading)
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
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Text-only Assistant Bubble (used below dashboard cards)

    private func assistantTextBubble(_ text: String, insights: [FinancialInsight]? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sparkle header strip
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
                    .foregroundStyle(DS.Colors.accent)
                Text("Centmond AI")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Colors.accent.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .opacity(0.3)
                .padding(.horizontal, 12)

            // Markdown with inline category capsules
            CapsuleMarkdownView(text: AssistantTextSanitizer.sanitize(text), insights: insights)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: 560, alignment: .leading)
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
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Helpers

    /// Extract a heading title from markdown (e.g. "## Saving Tips" → "Saving Tips")
    private func extractTitle(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" || $0 == " " })
                let clean = String(title).unicodeScalars.drop(while: { scalar in
                    !scalar.properties.isAlphabetic && scalar.value > 127
                })
                let result = String(clean).trimmingCharacters(in: .whitespaces)
                return result.isEmpty ? String(title).trimmingCharacters(in: .whitespaces) : result
            }
        }
        return "Financial Overview"
    }

    /// Strip the heading line (already shown in dashboard header) to avoid duplication
    private func stripInsightsHeading(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        // Remove the first heading line and any blank lines after it
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("#") {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                lines.removeFirst()
            }
        }
        // Also remove the first summary line if it's already in the dashboard
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}

// ============================================================
// MARK: - Streaming-Safe Markdown Sanitizer
// ============================================================
//
// During live token streaming, the Markdown parser sees
// incomplete fragments like "**Bol" or "- Item" mid-line.
// This causes visual flickering as bold/list syntax appears
// and disappears.
//
// StreamingMarkdownSanitizer closes any "dangling" Markdown
// tokens so the parser always receives a valid document.
//

// ============================================================
// MARK: - Assistant Text Sanitizer (defensive)
// ============================================================
//
// Catches the case where the model under context pressure or
// optimization throttling produces a malformed `---INSIGHTS---`
// or `---ACTIONS---` delimiter (e.g. truncated to `---INS` or
// `---ACT`) — the structured parsers miss it and raw JSON
// payloads bleed into the visible message.
//
// This sanitizer:
//   1. Truncates the message at the first `---I` or `---A`
//      partial-delimiter occurrence (so truncated tails go away).
//   2. Strips orphan JSON object fragments like `{"category":...}`,
//      `{"type":"advice","params"...}`, etc., that escape the
//      delimiter check entirely.
//   3. Cleans up trailing punctuation residue ("," / ":") and
//      collapses whitespace introduced by removed JSON.

enum AssistantTextSanitizer {
    static func sanitize(_ raw: String) -> String {
        var result = raw

        // 1. Cut at the first partial-delimiter we recognize.
        // The model is allowed to emit any of these as a separator
        // *prefix*; everything from there on is structured payload.
        let cutMarkers = ["---INSIGHTS---", "---ACTIONS---",
                          "---INSIGHT", "---ACTION",
                          "---INS", "---ACT",
                          "—INSIGHTS—", "—ACTIONS—"]
        var earliestCut: String.Index? = nil
        for marker in cutMarkers {
            if let r = result.range(of: marker, options: .caseInsensitive),
               (earliestCut == nil || r.lowerBound < earliestCut!) {
                earliestCut = r.lowerBound
            }
        }
        if let cut = earliestCut {
            result = String(result[result.startIndex..<cut])
        }

        // 2. Strip orphan JSON object fragments (balanced or partial).
        // Matches things like {"category":"Travel","spent":79,...}
        // and partial leftovers that begin with `{"` or contain
        // unmistakable JSON key fragments. Conservative: only kicks
        // in for substrings that look distinctly like our payload
        // shapes ("category":, "spent":, "params":, "type":, "advice":).
        let jsonShapeKeys = ["\"category\"", "\"spent\"", "\"budget\"",
                             "\"params\"", "\"advice\"", "\"warning\""]
        if jsonShapeKeys.contains(where: { result.contains($0) }) {
            // Strip JSON-ish runs: from { to next } (greedy-safe via NSRegex)
            let patterns = [
                #"\{[^{}]*"(category|type|params|advice|warning|spent|budget)"[^{}]*\}?"#,
                #"\}\s*\]?\s*\{"#,                  // adjacent broken objects
                #"\["[^\]]*"(category|type)"[^\]]*\]?"#,
            ]
            for p in patterns {
                if let regex = try? NSRegularExpression(pattern: p,
                                                        options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                    let range = NSRange(result.startIndex..., in: result)
                    result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
                }
            }
        }

        // 3. Clean up trailing punctuation residue and double whitespace
        //    left behind by stripped JSON.
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[,;:]\s*$"#, with: "", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum StreamingMarkdownSanitizer {

    /// Makes incomplete Markdown well-formed for rendering.
    /// - Only runs during streaming (cheap string scan).
    /// - Does NOT modify the accumulated raw buffer.
    static func sanitize(_ text: String) -> String {
        var result = text

        // 1. Close dangling bold / italic markers
        result = closeDanglingMarkers(result)

        // 2. If the last line starts with a heading `##` but has no content yet,
        //    append a zero-width space so the parser doesn't choke.
        if let lastNewline = result.lastIndex(of: "\n") {
            let lastLine = String(result[result.index(after: lastNewline)...])
            let stripped = lastLine.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("#") && stripped.drop(while: { $0 == "#" || $0 == " " }).isEmpty {
                result += "\u{200B}"
            }
        }

        // 3. Strip a trailing lone `*` or `_` that isn't paired
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("*") && !trimmed.hasSuffix("**") {
            // Single trailing asterisk — just hide it during streaming
            result = String(result.dropLast())
        }

        return result
    }

    /// Count unmatched `**` or `*` markers and close them.
    /// Single-pass UTF8 scan — was 3× `components(separatedBy:)` plus
    /// `replacingOccurrences` on every render, allocating O(N) arrays
    /// per keystroke during streaming.
    private static func closeDanglingMarkers(_ text: String) -> String {
        var stars = 0           // single `*` outside of `**` runs
        var doubleStars = 0     // count of `**` pairs
        var ticks = 0           // backticks outside of ``` runs
        var tripleTicks = 0

        var pendingStar = false      // saw exactly one `*`
        var pendingTicks: Int = 0    // 1 or 2 backticks awaiting

        for b in text.utf8 {
            if b == 0x2A { // '*'
                if pendingStar { doubleStars += 1; pendingStar = false }
                else { pendingStar = true }
            } else if pendingStar {
                stars += 1
                pendingStar = false
            }

            if b == 0x60 { // '`'
                pendingTicks += 1
                if pendingTicks == 3 { tripleTicks += 1; pendingTicks = 0 }
            } else if pendingTicks > 0 {
                ticks += pendingTicks
                pendingTicks = 0
            }
        }
        if pendingStar { stars += 1 }
        if pendingTicks > 0 { ticks += pendingTicks }

        var result = text
        if doubleStars % 2 != 0 { result += "**" }
        if stars % 2 != 0 { result += "*" }
        if ticks % 2 != 0 { result += "`" }
        _ = tripleTicks
        return result
    }
}

// ============================================================
// MARK: - Capsule Markdown View
// ============================================================
//
// Renders Markdown text with inline category capsules.
// Detects bullet lines like "- **Groceries** — You spent $332"
// and replaces the bold category name with a styled capsule.
//
// Used in both streaming and final output so they match.
//

struct CapsuleMarkdownView: View {
    let text: String
    var insights: [FinancialInsight]? = nil

    private static let bulletRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^[-*•]\s+\*\*([^*]+)\*\*\s*[—–\-:]\s*(.*)"#)
    }()

    var body: some View {
        let segments = parseSegments()
        let hasBullets = segments.contains { if case .bullet = $0 { return true } else { return false } }

        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let md):
                    if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Markdown(md)
                            .markdownTheme(.centmondDark)
                            .markdownCodeSyntaxHighlighter(SplashCodeSyntaxHighlighter())
                            .textSelection(.enabled)
                    }
                case .bullet(let category, let description):
                    bulletView(category: category, description: description)
                }
            }

            // Fallback: if insights available but model didn't write bullets
            if let insights, !insights.isEmpty, !hasBullets {
                ForEach(insights) { insight in
                    let spentStr = "**$\(String(format: "%.2f", insight.spent))**"
                    let budgetStr = insight.budget > 0 ? " / $\(String(format: "%.0f", insight.budget))" : ""
                    let amountPrefix = "\(spentStr)\(budgetStr) — "
                    let adviceText = insight.advice.isEmpty
                        ? "Spent this month."
                        : insight.advice
                            .replacingOccurrences(of: "**", with: "")
                            .replacingOccurrences(of: "*", with: "")
                    bulletView(
                        category: insight.category,
                        description: amountPrefix + adviceText
                    )
                }
            }
        }
    }

    // MARK: - Bullet with Capsule

    @ViewBuilder
    private func bulletView(category: String, description: String) -> some View {
        // Always use category color (distinct per category), not budget status color
        let color: SwiftUI.Color = Self.fallbackColor(for: category)
        let insight = insights?.first { $0.category.lowercased() == category.lowercased() }
        let icon = insight?.icon ?? Self.fallbackIcon(for: category)

        HStack(alignment: .top, spacing: 0) {
            // Category capsule — fixed width for alignment
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .medium))
                Text(category)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.12))
            )
            .frame(minWidth: 95, alignment: .leading)

            // Description with amounts bold+colored inline
            styledDescription(description, color: color)
                .font(.system(size: 12.5))
                .foregroundStyle(SwiftUI.Color(.labelColor).opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// Render description: **$amount** → bold+colored, rest → plain
    private func styledDescription(_ text: String, color: SwiftUI.Color) -> Text {
        let parts = text.components(separatedBy: "**")
        var result = Text("")
        for (i, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if i % 2 == 1 {
                // Bold segment (amounts like $332.20)
                result = result + Text(part)
                    .fontWeight(.bold)
                    .foregroundColor(color)
            } else {
                result = result + Text(part)
            }
        }
        return result
    }

    // MARK: - Segment Parsing

    private enum Segment {
        case markdown(String)
        case bullet(category: String, description: String)
    }

    private func parseSegments() -> [Segment] {
        let lines = text.components(separatedBy: .newlines)
        var segments: [Segment] = []
        var currentMarkdown: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let match = Self.matchBullet(trimmed) {
                // Flush accumulated markdown
                if !currentMarkdown.isEmpty {
                    segments.append(.markdown(currentMarkdown.joined(separator: "\n")))
                    currentMarkdown = []
                }
                segments.append(.bullet(category: match.category, description: match.description))
            } else {
                currentMarkdown.append(line)
            }
        }

        if !currentMarkdown.isEmpty {
            let joined = currentMarkdown.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(joined))
            }
        }

        return segments
    }

    private static func matchBullet(_ line: String) -> (category: String, description: String)? {
        guard let regex = bulletRegex else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 3 else { return nil }

        let category = (line as NSString).substring(with: match.range(at: 1))
        let description = (line as NSString).substring(with: match.range(at: 2))
        return (category, description)
    }

    // MARK: - Fallback Icon & Color

    private static func fallbackIcon(for category: String) -> String {
        let lower = category.lowercased()
        switch lower {
        case "groceries", "grocery":      return "cart.fill"
        case "shopping":                  return "bag.fill"
        case "dining", "restaurant":      return "fork.knife"
        case "health", "medical":         return "heart.fill"
        case "transport", "transportation", "gas": return "car.fill"
        case "entertainment":             return "tv.fill"
        case "bills", "utilities":        return "bolt.fill"
        case "subscriptions":             return "arrow.clockwise"
        case "rent", "housing":           return "house.fill"
        case "education":                 return "book.fill"
        case "savings":                   return "banknote.fill"
        case "income", "salary":          return "dollarsign.circle.fill"
        default:                          return "creditcard.fill"
        }
    }

    /// Category color used during streaming (before insights are available).
    private static func fallbackColor(for category: String) -> SwiftUI.Color {
        let lower = category.lowercased()
        switch lower {
        case "groceries", "grocery":      return SwiftUI.Color(red: 0.3, green: 0.82, blue: 0.45)
        case "shopping":                  return SwiftUI.Color(red: 1.0, green: 0.6, blue: 0.2)
        case "dining", "restaurant":      return SwiftUI.Color(red: 0.95, green: 0.55, blue: 0.25)
        case "health", "medical":         return SwiftUI.Color(red: 1.0, green: 0.35, blue: 0.35)
        case "transport", "transportation", "gas": return SwiftUI.Color(red: 0.35, green: 0.7, blue: 1.0)
        case "entertainment":             return SwiftUI.Color(red: 0.75, green: 0.45, blue: 1.0)
        case "bills", "utilities":        return SwiftUI.Color(red: 1.0, green: 0.78, blue: 0.2)
        case "subscriptions":             return SwiftUI.Color(red: 0.6, green: 0.5, blue: 1.0)
        case "rent", "housing":           return SwiftUI.Color(red: 0.55, green: 0.75, blue: 0.95)
        case "education":                 return SwiftUI.Color(red: 0.4, green: 0.6, blue: 1.0)
        case "savings":                   return SwiftUI.Color(red: 0.3, green: 0.85, blue: 0.55)
        case "income", "salary":          return SwiftUI.Color(red: 0.3, green: 0.85, blue: 0.45)
        default:                          return DS.Colors.accent
        }
    }
}

// MARK: - List Card Wrapper (for Markdown bulleted/numbered lists)

private struct ListCardWrapper<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                    .fill(Color.black.opacity(0.28))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
            )
    }
}
