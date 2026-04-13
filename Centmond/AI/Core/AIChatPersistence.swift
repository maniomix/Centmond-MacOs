import Foundation
import SwiftData

// ============================================================
// MARK: - Chat Persistence Models
// ============================================================
//
// SwiftData models for persisting AI chat history to disk.
// ChatSession groups messages into named conversations.
// ChatMessageRecord stores individual messages with their role,
// content, and timestamp.
//
// ============================================================

@Model
final class ChatSession {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessageRecord.session)
    var messages: [ChatMessageRecord]

    init(title: String = "New Chat") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = []
    }

    /// Sorted messages for display
    var sortedMessages: [ChatMessageRecord] {
        messages.sorted { $0.timestamp < $1.timestamp }
    }
}

@Model
final class ChatMessageRecord {
    var id: UUID
    var roleRaw: String  // "user", "assistant", "system"
    var content: String
    var timestamp: Date
    var actionsJSON: Data? // Serialized [AIAction] for assistant messages

    var session: ChatSession?

    var role: AIMessage.Role {
        AIMessage.Role(rawValue: roleRaw) ?? .user
    }

    init(role: AIMessage.Role, content: String, actions: [AIAction]? = nil) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.content = content
        self.timestamp = Date()

        if let actions, !actions.isEmpty {
            self.actionsJSON = try? JSONEncoder().encode(actions)
        }
    }

    /// Convert back to AIMessage for use in the conversation
    func toAIMessage() -> AIMessage {
        var decodedActions: [AIAction]?
        if let data = actionsJSON {
            decodedActions = try? JSONDecoder().decode([AIAction].self, from: data)
        }
        return AIMessage(role: role, content: content, actions: decodedActions)
    }
}

// ============================================================
// MARK: - Chat Persistence Manager
// ============================================================

@MainActor
final class ChatPersistenceManager {

    static let shared = ChatPersistenceManager()

    private init() {}

    // MARK: - Session Management

    /// Create a new chat session
    func createSession(context: ModelContext, title: String = "New Chat") -> ChatSession {
        let session = ChatSession(title: title)
        context.insert(session)
        try? context.save()
        return session
    }

    /// Fetch all sessions ordered by most recent
    func fetchSessions(context: ModelContext) -> [ChatSession] {
        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Fetch the most recent session (or create one if none exists)
    func currentSession(context: ModelContext) -> ChatSession {
        if let latest = fetchSessions(context: context).first {
            return latest
        }
        return createSession(context: context)
    }

    // MARK: - Message Management

    /// Save a user message to the session
    func saveUserMessage(_ text: String, session: ChatSession, context: ModelContext) {
        let record = ChatMessageRecord(role: .user, content: text)
        record.session = session
        session.messages.append(record)
        session.updatedAt = Date()
        try? context.save()
    }

    /// Save an assistant message to the session
    func saveAssistantMessage(_ text: String, actions: [AIAction]?, session: ChatSession, context: ModelContext) {
        let record = ChatMessageRecord(role: .assistant, content: text, actions: actions)
        record.session = session
        session.messages.append(record)
        session.updatedAt = Date()

        // Auto-title: use first user message as session title
        if session.title == "New Chat",
           let firstUser = session.sortedMessages.first(where: { $0.role == .user }) {
            let preview = String(firstUser.content.prefix(50))
            session.title = preview.count < firstUser.content.count ? preview + "..." : preview
        }

        try? context.save()
    }

    /// Load messages from a session into an AIConversation
    func loadConversation(from session: ChatSession) -> AIConversation {
        let conversation = AIConversation()
        for record in session.sortedMessages {
            let msg = record.toAIMessage()
            if msg.role == .user {
                conversation.addUserMessage(msg.content)
            } else if msg.role == .assistant {
                var decodedActions: [AIAction]?
                if let data = record.actionsJSON {
                    decodedActions = try? JSONDecoder().decode([AIAction].self, from: data)
                }
                conversation.addAssistantMessage(msg.content, actions: decodedActions)
            }
        }
        return conversation
    }

    /// Delete a session and all its messages
    func deleteSession(_ session: ChatSession, context: ModelContext) {
        context.delete(session)
        try? context.save()
    }

    /// Clear all sessions
    func clearAll(context: ModelContext) {
        let sessions = fetchSessions(context: context)
        for session in sessions {
            context.delete(session)
        }
        try? context.save()
    }
}
