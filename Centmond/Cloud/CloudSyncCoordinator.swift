import Foundation
import Combine
import CoreData
import SwiftData
import Network
import Supabase

// ============================================================
// MARK: - CloudSyncCoordinator (macOS)
// ============================================================
// Orchestrates push/pull between SwiftData and Supabase.
//
// State machine the UI cares about (all @Published):
//   • status: .idle / .syncing / .success(Date) / .error / .offline
//   • isOnline (from NWPathMonitor)
//   • pendingChanges (true while there are unpushed local edits)
//   • lastSuccessfulSync (last time push+pull both succeeded)
//
// Triggers:
//   • Sign-in →                            initialPull()
//   • SwiftData save notification →        debounced push (2 s)
//   • NWPathMonitor offline → online →     full reconcile (immediate)
//   • Realtime postgres_changes event →    pull (debounced 1.5 s)
//   • Sign-out →                           stop everything, reset status
//
// Cross-device delete safety: each push uses `lastSyncedAt`
// stored in UserDefaults. Repositories filter their upserts to
// `model.updatedAt > lastSyncedAt` — same defensive trick iOS
// uses to prevent re-uploading rows another device just deleted.
// (Implemented in Session 4b when each repo gets its push hook;
// this coordinator establishes the timestamp.)
// ============================================================

@MainActor
final class CloudSyncCoordinator: ObservableObject {

    static let shared = CloudSyncCoordinator()

    // MARK: - Published state

    enum Status: Equatable {
        case idle
        case syncing
        case success(Date)
        case error(String)
        case offline
    }

    @Published var status: Status = .idle
    @Published var isOnline: Bool = true
    @Published var pendingChanges: Bool = false
    @Published var lastSuccessfulSync: Date?

    // MARK: - Internals

    private var client: SupabaseClient { CloudClient.shared.client }
    private let lastSyncedAtKey = "centmond.lastSyncedAt"

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "centmond.networkMonitor")

    private var saveObserver: NSObjectProtocol?
    private var willSaveObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?

    /// Realtime cycle scheduling state. Replaces the previous
    /// cancel-and-restart pattern that starved during bursts of iOS
    /// edits — every event cancelled the in-flight pull and reset
    /// the debounce, so the cycle never completed and the user had
    /// to relaunch the app to see new data. New rules:
    ///   • One in-flight cycle at a time (`realtimeCycleActive`).
    ///   • Events arriving WHILE a cycle runs raise
    ///     `realtimePullPending`; the cycle re-fires itself on
    ///     completion if the flag is set.
    ///   • Events arriving while the debounce timer is already
    ///     scheduled are coalesced (no-op) — the upcoming cycle
    ///     will pick up everything.
    private var realtimeCycleActive = false
    private var realtimePullPending = false

    /// Set true while pull-driven prunes call `context.delete(...)`, so
    /// the will-save hook below skips queueing those for cloud deletion
    /// (they're cloud-driven, not user-driven). Repositories should
    /// always go through `runWhilePruning(_:)` rather than flipping this
    /// directly so the `defer` reset is guaranteed.
    private var isPruningFromCloud = false

    /// Run `body` with the prune-from-cloud guard set, so any
    /// `context.delete(...)` calls inside it are NOT auto-queued for
    /// cloud DELETE. Use this from any repository's pullAll prune step.
    /// Synchronous on purpose — keeps the flag's lifetime tied to the
    /// SwiftData mutation block, not an async task that might yield.
    func runWhilePruning(_ body: () -> Void) {
        let wasPruning = isPruningFromCloud
        isPruningFromCloud = true
        defer { isPruningFromCloud = wasPruning }
        body()
    }

    /// Fetch the set of row IDs currently in `table`. Used by repos
    /// that do "push all" (e.g. AccountRepository / GoalContribution)
    /// to filter out rows another device just deleted, so we don't
    /// resurrect them on push. RLS scopes this to the current user
    /// automatically. Cheap on small tables (selects only `id`).
    func fetchCloudIds(table: String) async throws -> Set<UUID> {
        struct IdRow: Decodable { let id: String }
        let rows: [IdRow] = try await CloudClient.shared.client
            .from(table)
            .select("id")
            .execute()
            .value
        return Set(rows.compactMap { CloudHelpers.uuid($0.id) })
    }
    private var realtimeChannel: RealtimeChannelV2?
    private var realtimeStreamTasks: [Task<Void, Never>] = []
    private var realtimeDebounce: Task<Void, Never>?

    private var modelContext: ModelContext?
    private var isStarted = false

    // MARK: - Lifecycle

    private init() {
        startNetworkMonitoring()
    }

    /// Wire the coordinator to the app's shared SwiftData context.
    /// Call from `RootView.task` once the user is authenticated.
    func start(context: ModelContext) {
        guard !isStarted else { return }
        isStarted = true
        modelContext = context

        observeContextSaves()

        Task {
            await initialPull(context: context)
            startRealtime(userId: AuthManager.shared.currentUser?.id.uuidString ?? "")
        }
    }

    /// Tear down on sign-out. Cancels timers, removes notifications,
    /// resets observable state.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        if let token = saveObserver {
            NotificationCenter.default.removeObserver(token)
            saveObserver = nil
        }
        if let token = willSaveObserver {
            NotificationCenter.default.removeObserver(token)
            willSaveObserver = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
        realtimeDebounce?.cancel()
        for t in realtimeStreamTasks { t.cancel() }
        realtimeStreamTasks.removeAll()
        if let channel = realtimeChannel {
            Task { await channel.unsubscribe() }
        }
        realtimeChannel = nil

        modelContext = nil
        status = .idle
        pendingChanges = false
        lastSuccessfulSync = nil
        UserDefaults.standard.removeObject(forKey: lastSyncedAtKey)
    }

    // MARK: - Initial pull (sign-in)

    /// Pulls every cloud table into the local SwiftData store.
    /// Order matters: parents before children, so relationship
    /// lookups in TransactionRepository.pull find the rows they need.
    private func initialPull(context: ModelContext) async {
        guard isOnline else { status = .offline; return }
        status = .syncing
        do {
            let cutoff = lastSyncedAt
            try await AccountRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await BudgetCategoryRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await TransactionRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await BudgetRepository.shared.pullAllTotals(into: context)
            try await BudgetRepository.shared.pullAllCategoryBudgets(into: context)
            try await GoalRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await GoalContributionRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await SubscriptionRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await AIChatRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await HouseholdRepository.shared.pullAll(into: context, cutoff: cutoff)
            // BudgetRepository (totals + category budgets) intentionally
            // unmigrated to cutoff-prune because the @Models lack any
            // timestamp field — adding one is a SwiftData migration we
            // chose to defer. Cross-device delete of budgets remains
            // until that lands.

            try? context.save()
            stampSyncedAt()
            status = .success(.now)
            lastSuccessfulSync = .now
            SecureLogger.info("Initial pull completed")
        } catch {
            status = .error(error.localizedDescription)
            SecureLogger.error("Initial pull failed", error)
        }
    }

    // MARK: - Save observer (push trigger)

    private func observeContextSaves() {
        // SwiftData uses Core Data underneath; the Core Data
        // notifications still fire on save. Subscribe at the
        // "did save" point so we know there are committed changes
        // worth pushing.
        saveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedPush()
            }
        }

        // CRITICAL: capture deletions BEFORE commit so we can queue them
        // for cloud DELETE. SwiftData's `context.delete(x)` removes the row
        // locally, but without this hook the cloud copy lingers and the
        // next pull re-creates the local row (a "ghost resurrection"). By
        // listening on willSave we still have access to the deleted
        // objects' attributes (they're in `context.deletedObjects`).
        willSaveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            guard !self.isPruningFromCloud else { return }
            guard let ctx = note.object as? NSManagedObjectContext else { return }
            // Snapshot ids on the context's queue, mark on main.
            var captured: [(CloudTable, UUID)] = []
            for obj in ctx.deletedObjects {
                guard let entityName = obj.entity.name,
                      let table = Self.cloudTable(forEntity: entityName) else { continue }
                if let raw = obj.primitiveValue(forKey: "id") {
                    if let u = raw as? UUID {
                        captured.append((table, u))
                    } else if let s = raw as? String, let u = UUID(uuidString: s) {
                        captured.append((table, u))
                    }
                }
            }
            guard !captured.isEmpty else { return }
            Task { @MainActor in
                for (table, id) in captured {
                    CloudDeletionQueue.shared.mark(table, id: id)
                }
            }
        }
    }

    /// Map a SwiftData @Model entity name to the cloud table it syncs to.
    /// Returns nil for entities that aren't cloud-synced (e.g. local-only
    /// caches, snapshots, AI insight rows).
    private static func cloudTable(forEntity name: String) -> CloudTable? {
        switch name {
        case "Transaction":            return .transactions
        case "Account":                return .accounts
        case "BudgetCategory":         return .categories
        case "Goal":                   return .goals
        case "GoalContribution":       return .goalContributions
        case "MonthlyTotalBudget":     return .monthlyBudgets
        case "MonthlyBudget":          return .monthlyCategoryBudgets
        case "Subscription":           return .subscriptions
        case "ChatSession":            return .aiChatSessions
        // ChatMessageRecord intentionally NOT mapped — the cloud FK on
        // ai_chat_messages.session_id has ON DELETE CASCADE, so deleting
        // a session in cloud removes its messages automatically. Mapping
        // ChatMessageRecord here would queue redundant per-message
        // DELETEs every time a session cascade-deletes locally.
        default:                       return nil
        }
    }

    private func scheduleDebouncedPush() {
        guard let context = modelContext else { return }
        guard isOnline else {
            pendingChanges = true
            status = .offline
            return
        }
        pendingChanges = true
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s debounce
            guard !Task.isCancelled, let self else { return }
            await self.pushDirty(context: context)
        }
    }

    /// Push all dirty + queued-deletion rows to cloud. Call from the
    /// debounce hook OR from manual sync triggers. Updates
    /// `lastSyncedAt` only on full success.
    func pushDirty(context: ModelContext) async {
        guard isOnline else { status = .offline; return }
        let cutoff = lastSyncedAt
        status = .syncing

        do {
            // 1. Drain the deletion queue first so subsequent pulls
            //    don't resurrect rows the user deleted.
            try await drainDeletions()

            // 2. Push only rows modified since last successful sync.
            try await pushTransactions(context: context, cutoff: cutoff)
            try await pushAccounts(context: context, cutoff: cutoff)
            try await pushCategories(context: context, cutoff: cutoff)
            try await pushBudgets(context: context)
            try await pushGoals(context: context, cutoff: cutoff)
            try await pushGoalContributions(context: context, cutoff: cutoff)
            try await pushSubscriptions(context: context, cutoff: cutoff)
            try await AIChatRepository.shared.pushDirty(context: context, cutoff: cutoff)
            try await HouseholdRepository.shared.pushSnapshot(from: context, cutoff: cutoff)

            stampSyncedAt()
            status = .success(.now)
            lastSuccessfulSync = .now
            pendingChanges = false
            SecureLogger.info("Push completed")
        } catch {
            status = .error(error.localizedDescription)
            SecureLogger.error("Push failed", error)
            // Keep `pendingChanges = true` so a future trigger retries.
        }
    }

    // MARK: - Per-entity push helpers

    private func drainDeletions() async throws {
        let queue = CloudDeletionQueue.shared
        guard !queue.isEmpty else { return }
        for (table, ids) in queue.grouped() {
            switch table {
            case .transactions:
                try await TransactionRepository.shared.deleteMany(ids: ids)
            case .accounts:
                try await AccountRepository.shared.deleteMany(ids: ids)
            case .categories:
                for id in ids { try await BudgetCategoryRepository.shared.delete(id: id) }
            case .goals:
                try await GoalRepository.shared.deleteMany(ids: ids)
            case .goalContributions:
                try await GoalContributionRepository.shared.deleteMany(ids: ids)
            case .monthlyBudgets:
                for id in ids { try await BudgetRepository.shared.deleteTotal(id: id) }
            case .monthlyCategoryBudgets:
                for id in ids { try await BudgetRepository.shared.deleteCategoryBudget(id: id) }
            case .subscriptions:
                // JSONB-blob; subscription_state row is per-user, not per-id.
                // No per-id DELETE — the deleted sub is already gone from
                // the local fetch, so when pushSubscriptions() runs later
                // in the same push cycle the snapshot upload will
                // implicitly delete it on cloud. Fall through to clear()
                // so the queue doesn't grow unbounded.
                break
            case .aiChatSessions:
                try await AIChatRepository.shared.deleteSessions(ids: ids)
            }
            queue.clear(table, ids: ids)
        }
    }

    private func pushTransactions(context: ModelContext, cutoff: Date) async throws {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.updatedAt > cutoff }
        )
        let dirty = (try? context.fetch(descriptor)) ?? []
        if !dirty.isEmpty {
            try await TransactionRepository.shared.upsertMany(dirty)
        }
    }

    private func pushAccounts(context: ModelContext, cutoff: Date) async throws {
        // Account lacks an `updatedAt` field, so we can't dirty-filter.
        // pushAllResurrectionSafe asks the cloud which IDs still exist
        // and skips locals whose ID is gone AND whose createdAt
        // predates `cutoff` — those rows were deleted on another device
        // and re-uploading them would resurrect them.
        let all = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        if !all.isEmpty {
            try await AccountRepository.shared.pushAllResurrectionSafe(all, cutoff: cutoff)
        }
    }

    private func pushCategories(context: ModelContext, cutoff: Date) async throws {
        let descriptor = FetchDescriptor<BudgetCategory>(
            predicate: #Predicate { $0.updatedAt > cutoff }
        )
        let dirty = (try? context.fetch(descriptor)) ?? []
        if !dirty.isEmpty {
            try await BudgetCategoryRepository.shared.upsertMany(dirty)
        }
    }

    /// Budget @Models lack an `updatedAt` field, so push everything every
    /// cycle. The tables are tiny (≤12 rows/year/user); upsert is idempotent.
    private func pushBudgets(context: ModelContext) async throws {
        let totals = (try? context.fetch(FetchDescriptor<MonthlyTotalBudget>())) ?? []
        if !totals.isEmpty {
            try await BudgetRepository.shared.upsertManyTotals(totals)
        }
        let categoryBudgets = (try? context.fetch(FetchDescriptor<MonthlyBudget>())) ?? []
        if !categoryBudgets.isEmpty {
            try await BudgetRepository.shared.upsertManyCategoryBudgets(categoryBudgets, in: context)
        }
    }

    private func pushGoals(context: ModelContext, cutoff: Date) async throws {
        let descriptor = FetchDescriptor<Goal>(
            predicate: #Predicate { $0.updatedAt > cutoff }
        )
        let dirty = (try? context.fetch(descriptor)) ?? []
        if !dirty.isEmpty {
            try await GoalRepository.shared.upsertMany(dirty)
        }
    }

    /// Contributions are append-only, edits rare. Push the full set
    /// every cycle but route through the resurrection-safe path so a
    /// contribution another device just deleted doesn't get
    /// re-uploaded by us.
    private func pushGoalContributions(context: ModelContext, cutoff: Date) async throws {
        let all = (try? context.fetch(FetchDescriptor<GoalContribution>())) ?? []
        if !all.isEmpty {
            try await GoalContributionRepository.shared.pushAllResurrectionSafe(all, cutoff: cutoff)
        }
    }

    /// Subscriptions live as a single JSONB blob per user — the
    /// snapshot IS the canonical list. SubscriptionRepository's push
    /// re-fetches the cloud envelope, applies a resurrection guard
    /// (skip locals whose id isn't in cloud AND whose createdAt
    /// predates `cutoff` — those were deleted on another device),
    /// and replaces only the `records` key.
    private func pushSubscriptions(context: ModelContext, cutoff: Date) async throws {
        try await SubscriptionRepository.shared.pushSnapshot(from: context, cutoff: cutoff)
    }

    // MARK: - Realtime

    private static let watchedTables = [
        "transactions", "accounts", "categories", "goals",
        "goal_contributions", "subscription_state", "household_state",
        "ai_memory", "ai_chat_sessions", "ai_chat_messages",
        "monthly_budgets", "monthly_category_budgets", "profiles"
    ]

    private func startRealtime(userId: String) {
        guard !userId.isEmpty, realtimeChannel == nil else { return }
        let channel = client.channel("centmond-mac-\(userId)")
        realtimeChannel = channel

        for table in Self.watchedTables {
            let stream = channel.postgresChange(
                AnyAction.self, schema: "public", table: table
            )
            let task = Task { [weak self] in
                for await _ in stream {
                    await MainActor.run { self?.scheduleRealtimePull() }
                }
            }
            realtimeStreamTasks.append(task)
        }
        Task { await channel.subscribe() }
        SecureLogger.info("Realtime: subscribed to \(Self.watchedTables.count) tables")
    }

    private func scheduleRealtimePull() {
        // If a cycle is already running, just flag it to re-run when
        // it completes — don't cancel, don't reschedule. This is
        // what kills the starvation: the in-flight cycle finishes
        // cleanly even during a burst of iOS edits.
        if realtimeCycleActive {
            realtimePullPending = true
            return
        }
        // If a debounced cycle is already queued up, coalesce — the
        // upcoming run will pick up everything that has changed.
        if realtimeDebounce != nil { return }

        realtimeDebounce = Task { @MainActor [weak self] in
            // 300ms is enough to coalesce the typical burst of
            // postgres_changes events from a single iOS save (the
            // server fans them out faster than that). 1.5s was
            // conservative-to-the-point-of-broken — by the time it
            // fired the user had often already given up and
            // relaunched.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.realtimeDebounce = nil
            await self.runRealtimeCycle()
        }
    }

    /// Single non-overlapping realtime cycle: optional push (only if
    /// there are pending local changes), then a full pull. Sets
    /// `realtimeCycleActive` so concurrent triggers don't pile on,
    /// and re-fires itself if events arrived during execution.
    private func runRealtimeCycle() async {
        guard let context = modelContext else { return }
        realtimeCycleActive = true
        defer {
            realtimeCycleActive = false
            // Re-fire if events came in mid-cycle so we never miss
            // anything. One extra cycle at most — it'll catch up.
            if realtimePullPending {
                realtimePullPending = false
                scheduleRealtimePull()
            }
        }

        // Push-then-pull is only needed when there are unpushed
        // local edits — without that, the push leg is a no-op
        // round-trip per repo for nothing, and (worse) when network
        // is slow it makes the pull arrive later than necessary.
        if pendingChanges {
            await pushDirty(context: context)
        }

        do {
            let cutoff = lastSyncedAt
            try await TransactionRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await AccountRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await BudgetCategoryRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await BudgetRepository.shared.pullAllTotals(into: context)
            try await BudgetRepository.shared.pullAllCategoryBudgets(into: context)
            try await GoalRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await GoalContributionRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await SubscriptionRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await AIChatRepository.shared.pullAll(into: context, cutoff: cutoff)
            try await HouseholdRepository.shared.pullAll(into: context, cutoff: cutoff)
            try? context.save()
            SecureLogger.debug("Realtime: store refreshed from cloud")
        } catch {
            SecureLogger.warning("Realtime pull failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Network monitoring

    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = (path.status == .satisfied)
                if self.isOnline && wasOffline {
                    SecureLogger.info("Network restored — kicking sync")
                    self.status = .idle
                    if let context = self.modelContext {
                        await self.pushDirty(context: context)
                    }
                } else if !self.isOnline {
                    self.status = .offline
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: - lastSyncedAt helpers

    private var lastSyncedAt: Date {
        let value = UserDefaults.standard.double(forKey: lastSyncedAtKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : .distantPast
    }

    private func stampSyncedAt() {
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastSyncedAtKey)
    }
}
