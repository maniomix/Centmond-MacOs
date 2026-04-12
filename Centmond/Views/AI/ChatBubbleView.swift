import SwiftUI

/// A single chat bubble with a simple appear animation.
struct ChatBubbleView: View {
    let message: AIMessage
    let colorScheme: ColorScheme
    let groupActions: ([AIAction]) -> [AIChatView.ActionGroup]
    let onConfirm: (UUID) -> Void
    let onReject: (UUID) -> Void

    @State private var appeared = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                Text(message.content)
                    .font(DS.Typography.body)
                    .foregroundStyle(message.role == .user ? .white : DS.Colors.text)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(message.role == .user
                                  ? DS.Colors.accent
                                  : (colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface))
                    )

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

            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) {
                appeared = true
            }
        }
    }
}
