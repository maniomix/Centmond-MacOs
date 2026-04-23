import SwiftUI
import Flow

// ============================================================
// MARK: - AI Suggested Prompts
// ============================================================
//
// Tappable prompt chips shown when the chat is empty.
//
// ============================================================

struct AISuggestedPrompts: View {
    let onSelect: (String) -> Void

    private let prompts: [(icon: String, text: String)] = [
        ("cart", "Add a $15 lunch expense"),
        ("chart.pie", "How much did I spend on dining this month?"),
        ("target", "Create a vacation savings goal for $2000"),
        ("arrow.triangle.branch", "Split a $80 dinner with Sara"),
        ("chart.bar", "Show me my spending breakdown"),
        ("banknote", "Set my monthly budget to $3000"),
        ("lightbulb", "Any tips to save more?"),
        ("repeat.circle", "What subscriptions do I have?"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.subtext)
                .padding(.horizontal, 4)

            HFlow(spacing: 8) {
                ForEach(prompts, id: \.text) { prompt in
                    Button {
                        onSelect(prompt.text)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: prompt.icon)
                                .font(CentmondTheme.Typography.caption)
                            Text(prompt.text)
                                .font(DS.Typography.caption)
                        }
                        .foregroundStyle(DS.Colors.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }
}
