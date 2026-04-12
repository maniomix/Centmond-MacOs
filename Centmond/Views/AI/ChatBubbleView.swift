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
            ForegroundColor(Color(.labelColor).opacity(0.55))
            FontSize(13)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(15)
                    ForegroundColor(DS.Colors.accent)
                }
                .markdownMargin(top: 2, bottom: 12)
        }
        .heading2 { configuration in
            VStack(alignment: .leading, spacing: 0) {
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(14)
                        ForegroundColor(DS.Colors.accent)
                    }
                RoundedRectangle(cornerRadius: 1)
                    .fill(DS.Colors.accent.opacity(0.25))
                    .frame(height: 1)
                    .padding(.top, 5)
            }
            .markdownMargin(top: 2, bottom: 14)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(13)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 10, bottom: 6)
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
            FontSize(11)
            ForegroundColor(DS.Colors.accent)
            BackgroundColor(DS.Colors.accent.opacity(0.08))
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 5, bottom: 5)
        }
        .paragraph { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 6)
        }
}

// MARK: - Chat Bubble View

/// A single chat bubble with a simple appear animation.
struct ChatBubbleView: View {
    let message: AIMessage
    let colorScheme: ColorScheme
    let groupActions: ([AIAction]) -> [AIChatView.ActionGroup]
    let onConfirm: (UUID) -> Void
    let onReject: (UUID) -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            if message.role == .assistant {
                Markdown(message.content)
                    .markdownTheme(.centmondDark)
                    .markdownCodeSyntaxHighlighter(SplashCodeSyntaxHighlighter())
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: 500, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.92))
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    )
            } else {
                Text(message.content)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }

            // Action cards for assistant messages
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
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .scaleEffect(appeared ? 1 : 0.97, anchor: message.role == .user ? .trailing : .leading)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }
}
