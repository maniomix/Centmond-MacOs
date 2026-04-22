import SwiftUI
import SwiftData
import Flow

// ============================================================
// MARK: - Review Queue Hub (P3)
// ============================================================
//
// Grouped list hub backed by `ReviewQueueService`. Renders every
// reason code the service emits in one place with a reason-chip
// filter, per-group headers, and bulk "Accept all" actions.
//
// Data source: `ReviewQueueService.buildQueue(in:)` — re-runs on
// every body evaluation. Hydrates `Transaction` / `Subscription`
// references from the model context so rows stay live.
//
// Triage mode (P4) still points at the legacy transaction-only
// flow — we'll rebuild it once the hub ships.
// ============================================================

struct ReviewQueueView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var allTransactions: [Transaction]
    @Query private var allSubscriptions: [Subscription]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var currentIndex = 0
    @State private var triageMode = false
    @State private var selectedReason: ReviewReasonCode? = nil
    @State private var collapsedReasons: Set<ReviewReasonCode> = []

    /// Single-step undo. Captured by the triage action handlers before they
    /// mutate, visible for 5 seconds as a banner, cleared after use or
    /// timeout. Intentionally not a stack — triage is for fast decisions;
    /// users who want deep undo should use the regular Transactions view.
    @State private var undoAction: UndoAction? = nil
    @State private var undoExpiryToken: UUID? = nil

    /// Bulk selection set — keyed by `ReviewItem.id`. Because
    /// `buildQueue` re-runs on every body pass and items mint fresh
    /// UUIDs, we re-hydrate this set against the current queue on every
    /// evaluation via `currentSelectionKeys` — so the set is used only
    /// for membership tests driven by stable `dedupeKey`s, not the
    /// volatile item IDs.
    @State private var selectedDedupeKeys: Set<String> = []

    /// Cached computation of everything derived from the SwiftData layer.
    /// Rebuilt explicitly on appear, when the underlying @Query arrays
    /// change length, and after every mutation (`rebuildSnapshot`).
    /// Without this cache, hover / selection / chip taps triggered full
    /// `buildQueue` runs every body pass and the view pegged CPU at
    /// ~110 % on open.
    @State private var snapshot: Snapshot = .empty

    struct Snapshot {
        let queue: [ReviewItem]
        let countsByReason: [ReviewReasonCode: Int]
        let transactionIndex: [UUID: Transaction]
        let subscriptionIndex: [UUID: Subscription]

        static let empty = Snapshot(queue: [], countsByReason: [:], transactionIndex: [:], subscriptionIndex: [:])
    }

    // MARK: - Derived

    private var queue: [ReviewItem] { snapshot.queue }
    private var countsByReason: [ReviewReasonCode: Int] { snapshot.countsByReason }
    private var transactionIndex: [UUID: Transaction] { snapshot.transactionIndex }
    private var subscriptionIndex: [UUID: Subscription] { snapshot.subscriptionIndex }

    private var filteredQueue: [ReviewItem] {
        guard let selectedReason else { return queue }
        return queue.filter { $0.reason == selectedReason }
    }

    private var grouped: [(reason: ReviewReasonCode, items: [ReviewItem])] {
        let groups = Dictionary(grouping: filteredQueue, by: \.reason)
        return ReviewReasonCode.allCases
            .filter { groups[$0]?.isEmpty == false }
            .map { ($0, groups[$0] ?? []) }
    }

    private func rebuildSnapshot() {
        let q = ReviewQueueService.buildQueue(in: modelContext)
        snapshot = Snapshot(
            queue: q,
            countsByReason: Dictionary(grouping: q, by: \.reason).mapValues(\.count),
            transactionIndex: Dictionary(uniqueKeysWithValues: allTransactions.map { ($0.id, $0) }),
            subscriptionIndex: Dictionary(uniqueKeysWithValues: allSubscriptions.map { ($0.id, $0) })
        )
    }

    /// Subset that the (legacy, P1) triage flow knows how to handle:
    /// transaction-bound reasons only.
    private var triageItems: [Transaction] {
        filteredQueue.compactMap { item in
            guard let txID = item.transactionID else { return nil }
            return transactionIndex[txID]
        }
    }

    var body: some View {
        Group {
            if queue.isEmpty {
                EmptyStateView(
                    icon: "tray.fill",
                    heading: "All caught up!",
                    description: "There are no items in the review queue right now. Nice work."
                )
            } else if triageMode {
                triageView
            } else {
                hubView
            }
        }
        .onAppear {
            rebuildSnapshot()
            if router.requestTriage, !snapshot.queue.isEmpty {
                currentIndex = 0
                triageMode = true
            }
            router.requestTriage = false
        }
        .onChange(of: allTransactions.count) { _, _ in rebuildSnapshot() }
        .onChange(of: allSubscriptions.count) { _, _ in rebuildSnapshot() }
    }

    // MARK: - Hub View

    private var hubView: some View {
        VStack(spacing: 0) {
            header
            reasonChipRow
            if !selectedDedupeKeys.isEmpty { bulkActionBar }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if filteredQueue.isEmpty {
                        filteredEmptyState
                    } else {
                        ForEach(grouped, id: \.reason) { group in
                            groupSection(group.reason, items: group.items)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bulk action bar (P5)

    private var selectedItems: [ReviewItem] {
        queue.filter { selectedDedupeKeys.contains($0.dedupeKey) }
    }

    private var bulkActionBar: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            Text("\(selectedItems.count) selected")
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            Button("Select all visible") {
                selectedDedupeKeys.formUnion(filteredQueue.map(\.dedupeKey))
            }
            .buttonStyle(GhostButtonStyle())

            Spacer()

            Menu {
                ForEach(categories) { cat in
                    Button { bulkCategorize(to: cat) } label: {
                        Label(cat.name, systemImage: cat.icon)
                    }
                }
            } label: {
                Label("Categorize", systemImage: "tag")
            }
            .menuStyle(.button)
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!bulkHasTransactionTarget)

            Button { bulkAccept() } label: {
                Label("Accept", systemImage: "checkmark.circle")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button { bulkDismiss() } label: {
                Label("Dismiss", systemImage: "xmark.circle")
            }
            .buttonStyle(GhostButtonStyle())

            Button { selectedDedupeKeys.removeAll() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plainHover)
            .help("Clear selection")
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.accent.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    private var bulkHasTransactionTarget: Bool {
        selectedItems.contains { $0.transactionID != nil }
    }

    private func bulkAccept() {
        for item in selectedItems {
            if let txID = item.transactionID, let tx = transactionIndex[txID] {
                acceptTransaction(tx)
            } else {
                ReviewQueueService.dismiss(item, in: modelContext)
            }
        }
        selectedDedupeKeys.removeAll()
    }

    private func bulkCategorize(to category: BudgetCategory) {
        var resolved = 0
        for item in selectedItems {
            guard let txID = item.transactionID, let tx = transactionIndex[txID] else { continue }
            tx.category = category
            tx.isReviewed = true
            tx.updatedAt = .now
            resolved += 1
        }
        if resolved > 0 { ReviewQueueTelemetry.shared.recordResolved(count: resolved) }
        selectedDedupeKeys.removeAll()
        rebuildSnapshot()
    }

    private func bulkDismiss() {
        for item in selectedItems {
            ReviewQueueService.dismiss(item, in: modelContext)
        }
        selectedDedupeKeys.removeAll()
        rebuildSnapshot()
    }

    private func toggleSelection(_ key: String) {
        if selectedDedupeKeys.contains(key) {
            selectedDedupeKeys.remove(key)
        } else {
            selectedDedupeKeys.insert(key)
        }
    }

    /// Apply `category` to every uncategorized row sharing `payee` — the
    /// smart "Apply to similar" follow-up offered from a row's context
    /// menu. Cheap: scans `allTransactions` in memory.
    private func categorizeAllFromPayee(_ payee: String, to category: BudgetCategory) {
        var resolved = 0
        for tx in allTransactions where tx.payee == payee && tx.category == nil && !tx.isReviewed {
            tx.category = category
            tx.isReviewed = true
            tx.updatedAt = .now
            resolved += 1
        }
        if resolved > 0 { ReviewQueueTelemetry.shared.recordResolved(count: resolved) }
        rebuildSnapshot()
    }

    private var header: some View {
        HStack(spacing: CentmondTheme.Spacing.lg) {
            Text("\(filteredQueue.count) \(filteredQueue.count == 1 ? "item" : "items") to review")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)

            let resolved = ReviewQueueTelemetry.shared.resolvedThisWeek
            if resolved > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                    Text("\(resolved) resolved this week")
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.positive)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(CentmondTheme.Colors.positive.opacity(0.12))
                .clipShape(Capsule())
            }

            Spacer()

            if !filteredQueue.isEmpty {
                Button { acceptAllVisible() } label: {
                    Label("Accept All", systemImage: "checkmark.circle")
                }
                .buttonStyle(GhostButtonStyle())
            }

            Button {
                currentIndex = 0
                triageMode = true
            } label: {
                Label("Triage Mode", systemImage: "bolt.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(triageItems.isEmpty)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .background(CentmondTheme.Colors.bgSecondary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    private var reasonChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CentmondTheme.Spacing.xs) {
                filterChip(
                    label: "All",
                    icon: "tray.full",
                    reason: nil,
                    count: queue.count
                )
                ForEach(ReviewReasonCode.allCases, id: \.self) { reason in
                    if let count = countsByReason[reason], count > 0 {
                        filterChip(
                            label: reason.title,
                            icon: reason.icon,
                            reason: reason,
                            count: count
                        )
                    }
                }
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.md)
        }
        .background(CentmondTheme.Colors.bgSecondary.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    private func filterChip(
        label: String,
        icon: String,
        reason: ReviewReasonCode?,
        count: Int
    ) -> some View {
        let isActive = selectedReason == reason
        return Button {
            withAnimation(CentmondTheme.Motion.micro) { selectedReason = reason }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label)
                Text("\(count)")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(isActive ? CentmondTheme.Colors.accent.opacity(0.2) : CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .font(CentmondTheme.Typography.caption)
            .foregroundStyle(isActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? CentmondTheme.Colors.accent.opacity(0.08) : CentmondTheme.Colors.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
        }
        .buttonStyle(.plainHover)
    }

    @ViewBuilder
    private var filteredEmptyState: some View {
        VStack(spacing: CentmondTheme.Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            Text("Nothing here")
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Button("Clear filter") {
                withAnimation(CentmondTheme.Motion.micro) { selectedReason = nil }
            }
            .buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CentmondTheme.Spacing.xxxl)
    }

    @ViewBuilder
    private func groupSection(_ reason: ReviewReasonCode, items: [ReviewItem]) -> some View {
        let isCollapsed = collapsedReasons.contains(reason)
        VStack(spacing: 0) {
            groupHeader(reason: reason, count: items.count, isCollapsed: isCollapsed)

            if !isCollapsed {
                ForEach(items) { item in
                    reviewItemView(for: item)
                }
            }
        }
    }

    private func groupHeader(reason: ReviewReasonCode, count: Int, isCollapsed: Bool) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Button {
                withAnimation(CentmondTheme.Motion.micro) {
                    if isCollapsed { collapsedReasons.remove(reason) }
                    else { collapsedReasons.insert(reason) }
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 12)
            }
            .buttonStyle(.plainHover)

            Image(systemName: reason.icon)
                .font(.system(size: 12))
                .foregroundStyle(color(for: reason))

            Text(reason.title)
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .tracking(0.5)

            Text("\(count)")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(CentmondTheme.Colors.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Spacer()

            Button { acceptAll(in: reason) } label: {
                Text("Accept all")
                    .font(CentmondTheme.Typography.caption)
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgPrimary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    @ViewBuilder
    private func reviewItemView(for item: ReviewItem) -> some View {
        let key = item.dedupeKey
        let isSelected = selectedDedupeKeys.contains(key)
        let hasSelection = !selectedDedupeKeys.isEmpty

        if let txID = item.transactionID, let tx = transactionIndex[txID] {
            ReviewItemRow(
                transaction: tx,
                reason: item.reason,
                categories: categories,
                isSelected: isSelected,
                hasAnySelection: hasSelection,
                onToggleSelect: { toggleSelection(key) },
                onAccept: { acceptTransaction(tx) },
                onInspect: { router.inspectTransaction(tx.id) },
                onDismiss: {
                    ReviewQueueService.dismiss(item, in: modelContext)
                    rebuildSnapshot()
                },
                onCategorize: { category in
                    tx.category = category
                    tx.isReviewed = true
                    tx.updatedAt = .now
                    ReviewQueueTelemetry.shared.recordResolved()
                    rebuildSnapshot()
                },
                onCategorizeSamePayee: { category in
                    categorizeAllFromPayee(tx.payee, to: category)
                }
            )
        } else if let subID = item.subscriptionID, let sub = subscriptionIndex[subID] {
            SubscriptionReviewRow(
                subscription: sub,
                reason: item.reason,
                isSelected: isSelected,
                hasAnySelection: hasSelection,
                onToggleSelect: { toggleSelection(key) },
                onInspect: { router.inspectSubscription(sub.id) },
                onDismiss: {
                    ReviewQueueService.dismiss(item, in: modelContext)
                    rebuildSnapshot()
                }
            )
        }
    }

    // MARK: - Actions

    private func acceptTransaction(_ tx: Transaction) {
        tx.isReviewed = true
        if tx.status == .pending { tx.status = .cleared }
        tx.updatedAt = .now
        ReviewQueueTelemetry.shared.recordResolved()
        rebuildSnapshot()
    }

    private func acceptAllVisible() {
        for item in filteredQueue {
            if let txID = item.transactionID, let tx = transactionIndex[txID] {
                tx.isReviewed = true
                if tx.status == .pending { tx.status = .cleared }
                tx.updatedAt = .now
                ReviewQueueTelemetry.shared.recordResolved()
            } else {
                ReviewQueueService.dismiss(item, in: modelContext)
            }
        }
        rebuildSnapshot()
    }

    private func acceptAll(in reason: ReviewReasonCode) {
        let items = queue.filter { $0.reason == reason }
        for item in items {
            if let txID = item.transactionID, let tx = transactionIndex[txID] {
                tx.isReviewed = true
                if tx.status == .pending { tx.status = .cleared }
                tx.updatedAt = .now
                ReviewQueueTelemetry.shared.recordResolved()
            } else {
                ReviewQueueService.dismiss(item, in: modelContext)
            }
        }
        rebuildSnapshot()
    }

    private func color(for reason: ReviewReasonCode) -> Color {
        switch reason {
        case .missingAccount, .negativeIncome:
            return CentmondTheme.Colors.negative
        case .uncategorizedTxn, .unusualAmount, .duplicateCandidate,
             .unlinkedRecurring, .unlinkedSubscription, .futureDated:
            return CentmondTheme.Colors.warning
        case .pendingTxn, .unreviewedTransfer, .staleCleared:
            return CentmondTheme.Colors.textTertiary
        }
    }

    // MARK: - Triage / Focus Mode (P4)

    /// Item stream driving the card stack — same as `filteredQueue` but
    /// pinned to the start of the triage session so that accepting items
    /// doesn't constantly reshuffle the deck under the user. Rebuilt when
    /// entering triage or clearing the filter.
    private var triageQueue: [ReviewItem] { filteredQueue }

    @ViewBuilder
    private var triageView: some View {
        VStack(spacing: CentmondTheme.Spacing.xxl) {
            triageHeader

            if currentIndex < triageQueue.count {
                triageCard(for: triageQueue[currentIndex])
            } else {
                triageCompleteCard
            }

            Spacer()
        }
        .padding(.top, CentmondTheme.Spacing.xxl)
        .overlay(alignment: .bottom) { undoBanner }
        .onKeyPress("a") { primaryAction(); return .handled }
        .onKeyPress("s") { advance(); return .handled }
        .onKeyPress("d") { dismissCurrent(); return .handled }
        .onKeyPress("i") { inspectCurrent(); return .handled }
        .onKeyPress(keys: ["1", "2", "3", "4", "5", "6", "7", "8"]) { press in
            guard currentIndex < triageQueue.count,
                  triageQueue[currentIndex].reason == .uncategorizedTxn,
                  let txID = triageQueue[currentIndex].transactionID,
                  let tx = transactionIndex[txID] else { return .ignored }
            let idx = Int(String(press.characters))! - 1
            guard idx < categories.count else { return .ignored }
            categorize(tx, to: categories[idx])
            return .handled
        }
        .onKeyPress(.escape) { triageMode = false; return .handled }
    }

    private var triageHeader: some View {
        HStack {
            Button { triageMode = false } label: {
                Label("Back to List", systemImage: "chevron.left")
            }
            .buttonStyle(GhostButtonStyle())

            Spacer()

            if currentIndex < triageQueue.count {
                VStack(spacing: 2) {
                    Text("\(currentIndex + 1) of \(triageQueue.count)")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    if let selectedReason {
                        Text(selectedReason.title.uppercased())
                            .font(CentmondTheme.Typography.overline)
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            .tracking(0.5)
                    }
                }
            }

            Spacer()

            GeometryReader { geo in
                let progress = triageQueue.isEmpty ? 1.0 : Double(currentIndex) / Double(triageQueue.count)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(CentmondTheme.Colors.strokeSubtle)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CentmondTheme.Colors.accent)
                        .frame(width: geo.size.width * progress)
                        .animation(CentmondTheme.Motion.default, value: progress)
                }
            }
            .frame(width: 200, height: 4)
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
    }

    private var triageCompleteCard: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(CentmondTheme.Colors.positive)
            Text("All caught up!")
                .font(CentmondTheme.Typography.heading2)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Button("Back to List") { triageMode = false }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private func triageCard(for item: ReviewItem) -> some View {
        let subject = triageSubject(for: item)
        VStack(spacing: CentmondTheme.Spacing.xl) {
            // Reason chip
            HStack(spacing: 6) {
                Image(systemName: item.reason.icon).font(.system(size: 11))
                Text(item.reason.title)
            }
            .font(CentmondTheme.Typography.caption)
            .foregroundStyle(color(for: item.reason))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color(for: item.reason).opacity(0.12))
            .clipShape(Capsule())

            // Amount
            Text(CurrencyFormat.standard(subject.amount))
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .foregroundStyle(subject.amountTint)
                .monospacedDigit()

            // Title (payee or service name)
            Text(subject.title)
                .font(CentmondTheme.Typography.heading2)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            // Meta row
            if !subject.metaLabels.isEmpty {
                HStack(spacing: CentmondTheme.Spacing.xxl) {
                    ForEach(subject.metaLabels, id: \.text) { label in
                        Label(label.text, systemImage: label.icon)
                            .foregroundStyle(label.tint ?? CentmondTheme.Colors.textSecondary)
                    }
                }
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }

            // Reason-specific quick action (categorize grid for uncategorized)
            if item.reason == .uncategorizedTxn,
               let txID = item.transactionID,
               let tx = transactionIndex[txID],
               !categories.isEmpty {
                categorizeGrid(for: tx)
            }

            Divider()
                .background(CentmondTheme.Colors.strokeSubtle)
                .frame(maxWidth: 400)

            triageActionBar(for: item)

            Text(keyboardHint(for: item.reason))
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .multilineTextAlignment(.center)
        }
        .padding(CentmondTheme.Spacing.xxxl)
        .frame(maxWidth: 600)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func categorizeGrid(for tx: Transaction) -> some View {
        VStack(spacing: CentmondTheme.Spacing.sm) {
            Text("ASSIGN CATEGORY")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .tracking(0.5)

            HFlow(spacing: 6) {
                ForEach(Array(categories.prefix(8).enumerated()), id: \.element.id) { idx, cat in
                    Button { categorize(tx, to: cat) } label: {
                        HStack(spacing: 4) {
                            Text("\(idx + 1)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                            Image(systemName: cat.icon).font(.system(size: 10))
                            Text(cat.name)
                        }
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(Color(hex: cat.colorHex))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: cat.colorHex).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm))
                    }
                    .buttonStyle(.plainHover)
                }
            }
        }
        .padding(.top, CentmondTheme.Spacing.sm)
    }

    private func triageActionBar(for item: ReviewItem) -> some View {
        HStack(spacing: CentmondTheme.Spacing.lg) {
            Button { primaryAction() } label: {
                Label(primaryLabel(for: item.reason) + " (A)", systemImage: "checkmark")
                    .frame(width: 160)
            }
            .buttonStyle(PrimaryButtonStyle())

            Button { advance() } label: {
                Label("Skip (S)", systemImage: "arrow.right").frame(width: 120)
            }
            .buttonStyle(SecondaryButtonStyle())

            Button { dismissCurrent() } label: {
                Label("Dismiss (D)", systemImage: "xmark").frame(width: 120)
            }
            .buttonStyle(GhostButtonStyle())

            Button { inspectCurrent() } label: {
                Label("Inspect (I)", systemImage: "sidebar.right").frame(width: 120)
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    @ViewBuilder
    private var undoBanner: some View {
        if let undo = undoAction {
            HStack(spacing: CentmondTheme.Spacing.sm) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(CentmondTheme.Colors.accent)
                Text(undo.label)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Spacer()
                Button("Undo") { performUndo() }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut("z", modifiers: .command)
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.vertical, CentmondTheme.Spacing.sm)
            .frame(maxWidth: 420)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1))
            .padding(.bottom, CentmondTheme.Spacing.xxl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Triage actions

    /// What the primary "A" key / button does for this reason.
    private func primaryLabel(for reason: ReviewReasonCode) -> String {
        switch reason {
        case .uncategorizedTxn:     return "Accept"
        case .pendingTxn:           return "Mark cleared"
        case .unusualAmount:        return "Confirm"
        case .duplicateCandidate:   return "Keep"
        case .missingAccount:       return "Open to fix"
        case .unlinkedRecurring:    return "Accept"
        case .unlinkedSubscription: return "Inspect"
        case .unreviewedTransfer:   return "Accept"
        case .futureDated:          return "Accept"
        case .negativeIncome:       return "Open to fix"
        case .staleCleared:         return "Accept"
        }
    }

    private func primaryAction() {
        guard currentIndex < triageQueue.count else { return }
        let item = triageQueue[currentIndex]
        switch item.reason {
        case .missingAccount, .negativeIncome, .unlinkedSubscription:
            // Blockers / subscription row need the inspector to resolve —
            // don't fake-accept them.
            inspectCurrent()
        default:
            if let txID = item.transactionID, let tx = transactionIndex[txID] {
                acceptWithUndo(tx)
            } else {
                dismissCurrent()
            }
        }
    }

    private func acceptWithUndo(_ tx: Transaction) {
        let prevReviewed = tx.isReviewed
        let prevStatus = tx.status
        undoAction = UndoAction(label: "Accepted \(tx.payee)") {
            tx.isReviewed = prevReviewed
            tx.status = prevStatus
            tx.updatedAt = .now
            self.rebuildSnapshot()
        }
        scheduleUndoExpiry()
        tx.isReviewed = true
        if tx.status == .pending { tx.status = .cleared }
        tx.updatedAt = .now
        ReviewQueueTelemetry.shared.recordResolved()
        rebuildSnapshot()
        advance()
    }

    private func categorize(_ tx: Transaction, to category: BudgetCategory) {
        let prevCategory = tx.category
        let prevReviewed = tx.isReviewed
        undoAction = UndoAction(label: "Categorized as \(category.name)") {
            tx.category = prevCategory
            tx.isReviewed = prevReviewed
            tx.updatedAt = .now
            self.rebuildSnapshot()
        }
        scheduleUndoExpiry()
        tx.category = category
        tx.isReviewed = true
        tx.updatedAt = .now
        ReviewQueueTelemetry.shared.recordResolved()
        rebuildSnapshot()
        advance()
    }

    private func dismissCurrent() {
        guard currentIndex < triageQueue.count else { return }
        let item = triageQueue[currentIndex]
        ReviewQueueService.dismiss(item, in: modelContext)
        undoAction = UndoAction(label: "Dismissed \(item.reason.title)") {
            ReviewQueueService.undismiss(item, in: modelContext)
            self.rebuildSnapshot()
        }
        scheduleUndoExpiry()
        rebuildSnapshot()
        advance()
    }

    private func inspectCurrent() {
        guard currentIndex < triageQueue.count else { return }
        let item = triageQueue[currentIndex]
        if let txID = item.transactionID {
            router.inspectTransaction(txID)
        } else if let subID = item.subscriptionID {
            router.inspectSubscription(subID)
        }
    }

    private func performUndo() {
        undoAction?.run()
        withAnimation(CentmondTheme.Motion.micro) { undoAction = nil }
    }

    private func scheduleUndoExpiry() {
        let token = UUID()
        undoExpiryToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if undoExpiryToken == token {
                withAnimation(CentmondTheme.Motion.default) { undoAction = nil }
            }
        }
    }

    private func advance() {
        withAnimation(CentmondTheme.Motion.default) {
            if currentIndex < triageQueue.count - 1 {
                currentIndex += 1
            } else {
                currentIndex = triageQueue.count
            }
        }
    }

    // MARK: - Subject hydration

    private struct TriageSubject {
        let title: String
        let amount: Decimal
        let amountTint: Color
        let metaLabels: [MetaLabel]
    }

    private struct MetaLabel {
        let text: String
        let icon: String
        let tint: Color?
    }

    private func triageSubject(for item: ReviewItem) -> TriageSubject {
        if let txID = item.transactionID, let tx = transactionIndex[txID] {
            var meta: [MetaLabel] = [
                MetaLabel(
                    text: tx.date.formatted(.dateTime.month(.abbreviated).day().year()),
                    icon: "calendar",
                    tint: nil
                )
            ]
            if let account = tx.account {
                meta.append(MetaLabel(text: account.name, icon: account.type.iconName, tint: nil))
            }
            meta.append(MetaLabel(
                text: tx.status.displayName,
                icon: "circle.fill",
                tint: Color(hex: tx.status.dotColor)
            ))
            return TriageSubject(
                title: tx.payee,
                amount: tx.amount,
                amountTint: tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary,
                metaLabels: meta
            )
        }
        if let subID = item.subscriptionID, let sub = subscriptionIndex[subID] {
            var meta: [MetaLabel] = [
                MetaLabel(text: sub.billingCycle.displayName, icon: "repeat", tint: nil)
            ]
            if let last = sub.lastChargeDate {
                meta.append(MetaLabel(
                    text: "Last " + last.formatted(.dateTime.month(.abbreviated).day()),
                    icon: "clock",
                    tint: CentmondTheme.Colors.warning
                ))
            }
            return TriageSubject(
                title: sub.serviceName,
                amount: sub.amount,
                amountTint: CentmondTheme.Colors.textPrimary,
                metaLabels: meta
            )
        }
        return TriageSubject(
            title: "Unknown",
            amount: item.amountMagnitude,
            amountTint: CentmondTheme.Colors.textPrimary,
            metaLabels: []
        )
    }

    private func keyboardHint(for reason: ReviewReasonCode) -> String {
        let primary = primaryLabel(for: reason)
        let base = "A = \(primary)  \u{2022}  S = Skip  \u{2022}  D = Dismiss  \u{2022}  I = Inspect  \u{2022}  \u{2318}Z = Undo"
        return reason == .uncategorizedTxn ? base + "  \u{2022}  1-8 = Assign Category" : base
    }
}

/// One-step undo captured by a triage action. `run` restores the pre-action
/// state; the triage banner calls it when the user hits Undo / \u{2318}Z.
private struct UndoAction {
    let label: String
    let run: () -> Void
}

// MARK: - Transaction Row

struct ReviewItemRow: View {
    let transaction: Transaction
    let reason: ReviewReasonCode
    let categories: [BudgetCategory]
    let isSelected: Bool
    let hasAnySelection: Bool
    var onToggleSelect: () -> Void
    var onAccept: () -> Void
    var onInspect: () -> Void
    var onDismiss: () -> Void
    var onCategorize: (BudgetCategory) -> Void
    var onCategorizeSamePayee: (BudgetCategory) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            selectionCheckbox

            Image(systemName: reason.icon)
                .font(.system(size: 14))
                .foregroundStyle(reasonTint)
                .frame(width: 28)

            Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .frame(width: 60, alignment: .leading)

            Text(transaction.payee)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            if let cat = transaction.category {
                HStack(spacing: 3) {
                    Image(systemName: cat.icon).font(.system(size: 10))
                    Text(cat.name)
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(Color(hex: cat.colorHex))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color(hex: cat.colorHex).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
            } else if reason == .uncategorizedTxn {
                Text("Uncategorized")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(CentmondTheme.Colors.warning.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
            }

            Text(CurrencyFormat.standard(transaction.amount))
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(transaction.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary)
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)

            Button { onInspect() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .buttonStyle(.plainHover)
            .help("Inspect")

            Button { onAccept() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.positive)
            }
            .buttonStyle(.plainHover)
            .help("Mark as reviewed")

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .buttonStyle(.plainHover)
            .help("Dismiss — don't show again")
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .frame(height: 44)
        .background(isHovered ? CentmondTheme.Colors.bgQuaternary : .clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { Haptics.tick() }
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
        .onTapGesture {
            if hasAnySelection { onToggleSelect() }
        }
        .contextMenu {
            Button { onAccept() } label: { Label("Accept", systemImage: "checkmark.circle") }
            Button { onInspect() } label: { Label("Inspect", systemImage: "sidebar.right") }
            Button(role: .destructive) { onDismiss() } label: {
                Label("Dismiss", systemImage: "xmark.circle")
            }
            Divider()
            Button { onToggleSelect() } label: {
                Label(isSelected ? "Deselect" : "Select", systemImage: isSelected ? "circle" : "checkmark.circle")
            }
            if transaction.category == nil {
                Divider()
                Menu("Assign Category") {
                    ForEach(categories) { cat in
                        Button { onCategorize(cat) } label: {
                            Label(cat.name, systemImage: cat.icon)
                        }
                    }
                }
                Menu("Apply to all \"\(transaction.payee)\"") {
                    ForEach(categories) { cat in
                        Button { onCategorizeSamePayee(cat) } label: {
                            Label(cat.name, systemImage: cat.icon)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    private var selectionCheckbox: some View {
        let shouldShow = isSelected || isHovered || hasAnySelection
        return Button { onToggleSelect() } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                .symbolRenderingMode(.hierarchical)
                .opacity(shouldShow ? 1 : 0)
                .animation(CentmondTheme.Motion.micro, value: shouldShow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 20)
        .help(isSelected ? "Deselect" : "Select for bulk action")
    }

    private var reasonTint: Color {
        switch reason {
        case .missingAccount, .negativeIncome: return CentmondTheme.Colors.negative
        case .pendingTxn, .unreviewedTransfer, .staleCleared: return CentmondTheme.Colors.textTertiary
        default: return CentmondTheme.Colors.warning
        }
    }
}

// MARK: - Subscription Row

struct SubscriptionReviewRow: View {
    let subscription: Subscription
    let reason: ReviewReasonCode
    let isSelected: Bool
    let hasAnySelection: Bool
    var onToggleSelect: () -> Void
    var onInspect: () -> Void
    var onDismiss: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            selectionCheckbox

            Image(systemName: reason.icon)
                .font(.system(size: 14))
                .foregroundStyle(CentmondTheme.Colors.warning)
                .frame(width: 28)

            if let last = subscription.lastChargeDate {
                Text(last.formatted(.dateTime.month(.abbreviated).day()))
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 60, alignment: .leading)
            } else {
                Text("—")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .frame(width: 60, alignment: .leading)
            }

            Text(subscription.serviceName)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            Text("No recent charge")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.warning)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(CentmondTheme.Colors.warning.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))

            Text(CurrencyFormat.standard(subscription.amount))
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)

            Button { onInspect() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .buttonStyle(.plainHover)
            .help("Inspect")

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .buttonStyle(.plainHover)
            .help("Dismiss — don't show again")
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .frame(height: 44)
        .background(isHovered ? CentmondTheme.Colors.bgQuaternary : .clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { Haptics.tick() }
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
        .onTapGesture {
            if hasAnySelection { onToggleSelect() }
        }
        .contextMenu {
            Button { onInspect() } label: { Label("Inspect", systemImage: "sidebar.right") }
            Button(role: .destructive) { onDismiss() } label: {
                Label("Dismiss", systemImage: "xmark.circle")
            }
            Divider()
            Button { onToggleSelect() } label: {
                Label(isSelected ? "Deselect" : "Select", systemImage: isSelected ? "circle" : "checkmark.circle")
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
        }
    }

    private var selectionCheckbox: some View {
        let shouldShow = isSelected || isHovered || hasAnySelection
        return Button { onToggleSelect() } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                .symbolRenderingMode(.hierarchical)
                .opacity(shouldShow ? 1 : 0)
                .animation(CentmondTheme.Motion.micro, value: shouldShow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 20)
        .help(isSelected ? "Deselect" : "Select for bulk action")
    }
}
