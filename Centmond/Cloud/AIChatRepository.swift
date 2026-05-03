import Foundation
import SwiftData
import Supabase

// ============================================================
// MARK: - AIChatRepository (macOS)
// ============================================================
// Sync adapter for AI chat history.
//
// Cloud schema:
//   ai_chat_sessions(id PK, owner_id, title, archived_at,
//                    created_at, updated_at)
//   ai_chat_messages(id PK, session_id FK→sessions ON DELETE
//                    CASCADE, owner_id, role, content,
//                    actions jsonb, created_at)
//
// Strategy: per-row sync (NOT JSONB-blob like Subscription)
// because chat tables grow per-message and we want realtime
// fan-out of new messages to other devices without re-uploading
// the whole transcript.
//
// Push: push-everything-newer-than-cutoff each cycle. Messages
// are append-only so no edit conflicts; sessions update only on
// rename or new-message timestamp bump.
//
// Pull: fetch all sessions + messages, reconcile by id. Insert
// missing locals; never delete locals here (cloud→local prune is
// Phase 2 work, and stale local sessions are harmless until then).
//
// Delete: ChatSession deletion is captured by CloudSyncCoordinator's
// willSave hook → CloudDeletionQueue → drainDeletions → cloud
// DELETE on `ai_chat_sessions`. The cloud FK cascades the
// child messages, so we don't queue individual ChatMessageRecord
// deletions (the local cascade-delete still touches them, but
// `cloudTable(forEntity:)` returns nil for "ChatMessageRecord"
// so they're skipped — fewer wasted DELETE round trips).
//
// macOS-only fields NOT synced: ChatSession.archivedAt (no field
// on macOS model yet), ChatMessageRecord.session relationship
// (rebuilt from session_id FK on pull).
// ============================================================

@MainActor
final class AIChatRepository {

    static let shared = AIChatRepository()
    private init() {}

    private var client: SupabaseClient { CloudClient.shared.client }

    // MARK: - Wire DTOs

    private struct SessionRow: Codable {
        let id: String
        let title: String?
        let created_at: String
        let updated_at: String
    }

    private struct MessageRow: Codable {
        let id: String
        let session_id: String
        let role: String
        let content: String
        let actions: AnyJSON?
        let created_at: String
    }

    // MARK: - Pull

    /// Pull all sessions + messages and reconcile by id. Cloud rows
    /// missing locally get inserted; locals not in cloud are pruned
    /// IFF their `updatedAt < cutoff` (gating prevents wiping a chat
    /// the user just renamed and hasn't pushed yet).
    ///
    /// Cloud FK cascade on `ai_chat_messages.session_id` means we only
    /// need to prune sessions — message orphans are removed by the
    /// SwiftData @Relationship cascade when their session is deleted.
    func pullAll(into context: ModelContext, cutoff: Date) async throws {
        let sessionRows: [SessionRow] = try await client
            .from("ai_chat_sessions")
            .select("id, title, created_at, updated_at")
            .order("updated_at", ascending: false)
            .execute()
            .value
        let messageRows: [MessageRow] = try await client
            .from("ai_chat_messages")
            .select("id, session_id, role, content, actions, created_at")
            .order("created_at", ascending: true)
            .execute()
            .value
        SecureLogger.info("Pulled \(sessionRows.count) chat sessions, \(messageRows.count) messages")

        let local = (try? context.fetch(FetchDescriptor<ChatSession>())) ?? []
        var sessionById: [UUID: ChatSession] = CloudHelpers.indexById(local) { $0.id }

        // 1) Reconcile sessions
        var seenSessionIds = Set<UUID>()
        for row in sessionRows {
            guard let id = CloudHelpers.uuid(row.id) else { continue }
            seenSessionIds.insert(id)
            if let existing = sessionById[id] {
                applySession(row, to: existing)
            } else {
                let new = ChatSession(title: row.title ?? "New Chat")
                new.id = id
                new.createdAt = CloudHelpers.parseDate(row.created_at) ?? .now
                new.updatedAt = CloudHelpers.parseDate(row.updated_at) ?? new.createdAt
                context.insert(new)
                sessionById[id] = new
            }
        }

        // Prune sessions absent from cloud (relies on cascade-delete
        // relationship to ChatMessageRecord to clean up child rows).
        let toPrune = local.filter { s in
            !seenSessionIds.contains(s.id) && s.updatedAt < cutoff
        }
        if !toPrune.isEmpty {
            CloudSyncCoordinator.shared.runWhilePruning {
                for s in toPrune {
                    sessionById.removeValue(forKey: s.id)
                    context.delete(s)
                }
            }
            SecureLogger.info("Pruned \(toPrune.count) chat session(s) absent from cloud")
        }

        // 2) Reconcile messages — need a flat lookup of all known message ids
        //    across surviving sessions. Reading `.messages` on the pruned
        //    ChatSession entities would be unsafe (model deleted), so we
        //    only flat-map over what's still in `sessionById`.
        let knownMessageIds: Set<UUID> = Set(sessionById.values.flatMap { $0.messages.map(\.id) })

        for row in messageRows {
            guard let mid = CloudHelpers.uuid(row.id),
                  let sid = CloudHelpers.uuid(row.session_id),
                  let parent = sessionById[sid] else { continue }
            if knownMessageIds.contains(mid) { continue }

            let role = AIMessage.Role(rawValue: row.role) ?? .user
            let actions = decodeActions(row.actions)
            let record = ChatMessageRecord(role: role, content: row.content, actions: actions)
            record.id = mid
            record.timestamp = CloudHelpers.parseDate(row.created_at) ?? .now
            record.session = parent
            parent.messages.append(record)
        }

        try? context.save()
    }

    // MARK: - Push

    /// Upsert sessions and messages whose local timestamp is newer
    /// than `cutoff` (the coordinator's lastSyncedAt). Messages are
    /// append-only; sessions update on rename or activity bump.
    func pushDirty(context: ModelContext, cutoff: Date) async throws {
        try await pushDirtySessions(context: context, cutoff: cutoff)
        try await pushDirtyMessages(context: context, cutoff: cutoff)
    }

    private func pushDirtySessions(context: ModelContext, cutoff: Date) async throws {
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.updatedAt > cutoff }
        )
        let dirty = (try? context.fetch(descriptor)) ?? []
        guard !dirty.isEmpty else { return }
        let rows = dirty.map { s in
            SessionRow(
                id: s.id.uuidString,
                title: s.title,
                created_at: CloudHelpers.isoString(s.createdAt),
                updated_at: CloudHelpers.isoString(s.updatedAt)
            )
        }
        try await client
            .from("ai_chat_sessions")
            .upsert(rows, onConflict: "id")
            .execute()
        SecureLogger.info("Pushed \(rows.count) chat session(s)")
    }

    private func pushDirtyMessages(context: ModelContext, cutoff: Date) async throws {
        let descriptor = FetchDescriptor<ChatMessageRecord>(
            predicate: #Predicate { $0.timestamp > cutoff }
        )
        let dirty = (try? context.fetch(descriptor)) ?? []
        guard !dirty.isEmpty else { return }

        var rows: [MessageRow] = []
        rows.reserveCapacity(dirty.count)
        for record in dirty {
            // Skip detached records — a message without a session would
            // violate the FK on push. Shouldn't happen in normal flow.
            guard let sessionId = record.session?.id else { continue }
            rows.append(MessageRow(
                id: record.id.uuidString,
                session_id: sessionId.uuidString,
                role: record.roleRaw,
                content: record.content,
                actions: encodeActions(record.actionsJSON),
                created_at: CloudHelpers.isoString(record.timestamp)
            ))
        }
        guard !rows.isEmpty else { return }
        try await client
            .from("ai_chat_messages")
            .upsert(rows, onConflict: "id")
            .execute()
        SecureLogger.info("Pushed \(rows.count) chat message(s)")
    }

    // MARK: - Delete (used by drainDeletions on session deletes)

    /// Delete sessions in cloud. Cloud FK cascade handles the
    /// matching `ai_chat_messages` rows, so message deletes don't
    /// need to be queued individually.
    func deleteSessions(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        struct DeletedRow: Codable { let id: String }
        // Chunk by 100 — see TransactionRepository.deleteMany.
        let chunkSize = 100
        var totalDeleted = 0
        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let batch = Array(ids[start ..< min(start + chunkSize, ids.count)])
            let deleted: [DeletedRow] = try await client
                .from("ai_chat_sessions")
                .delete()
                .in("id", values: batch.map(\.uuidString))
                .select("id")
                .execute()
                .value
            totalDeleted += deleted.count
            await Task.yield()
        }
        SecureLogger.info("Deleted \(totalDeleted) of \(ids.count) requested chat session(s)")
    }

    // MARK: - Helpers

    private func applySession(_ row: SessionRow, to model: ChatSession) {
        model.title = row.title ?? model.title
        if let updated = CloudHelpers.parseDate(row.updated_at) {
            // Last-writer-wins on updated_at: only adopt cloud value if
            // it's newer than what we have locally. Prevents an old
            // realtime echo from clobbering a fresh local rename.
            if updated > model.updatedAt {
                model.updatedAt = updated
            }
        }
    }

    /// Convert AnyJSON (from cloud jsonb) → encoded Data containing
    /// `[AIAction]`. Returns nil if the column was null or doesn't
    /// contain an array of decodable actions.
    private func decodeActions(_ value: AnyJSON?) -> [AIAction]? {
        guard let value else { return nil }
        // Re-encode → decode is cheap (small payloads) and reuses the
        // same Codable impl AIAction already has, so we don't duplicate
        // schema knowledge in this layer.
        guard let raw = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode([AIAction].self, from: raw)
    }

    /// Inverse of decodeActions: takes the local Data blob (encoded
    /// `[AIAction]`) and converts to AnyJSON for jsonb push. Returns
    /// nil for empty / undecodable blobs so we send SQL NULL not "".
    private func encodeActions(_ data: Data?) -> AnyJSON? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(AnyJSON.self, from: data)
    }
}
