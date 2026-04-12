import SwiftUI
import SwiftData
import Flow

struct ReviewQueueView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.date, order: .reverse) private var allTransactions: [Transaction]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var currentIndex = 0
    @State private var triageMode = false
    @State private var filterReason: ReviewReason? = nil

    enum ReviewReason: String, CaseIterable {
        case uncategorized = "Uncategorized"
        case pending = "Pending"

        var icon: String {
            switch self {
            case .uncategorized: "questionmark.circle.fill"
            case .pending: "clock.fill"
            }
        }
    }

    private var reviewItems: [Transaction] {
        var items = allTransactions.filter { !$0.isReviewed && ($0.category == nil || $0.status == .pending) }
        if let filterReason {
            switch filterReason {
            case .uncategorized: items = items.filter { $0.category == nil }
            case .pending: items = items.filter { $0.status == .pending }
            }
        }
        return items
    }

    private var uncategorizedCount: Int {
        allTransactions.filter { !$0.isReviewed && $0.category == nil }.count
    }
    private var pendingCount: Int {
        allTransactions.filter { !$0.isReviewed && $0.status == .pending }.count
    }

    var body: some View {
        Group {
            if allTransactions.filter({ !$0.isReviewed && ($0.category == nil || $0.status == .pending) }).isEmpty {
                EmptyStateView(
                    icon: "tray.fill",
                    heading: "All caught up!",
                    description: "There are no transactions to review right now. Nice work."
                )
            } else if triageMode {
                triageView
            } else {
                listView
            }
        }
    }

    // MARK: - List View

    private var listView: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: CentmondTheme.Spacing.lg) {
                Text("\(reviewItems.count) items to review")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)

                // Filter chips
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    filterChip(label: "All", reason: nil, count: uncategorizedCount + pendingCount)
                    filterChip(label: "Uncategorized", reason: .uncategorized, count: uncategorizedCount)
                    filterChip(label: "Pending", reason: .pending, count: pendingCount)
                }

                Spacer()

                if !reviewItems.isEmpty {
                    Button {
                        // Mark all visible as reviewed
                        for tx in reviewItems {
                            tx.isReviewed = true
                            tx.updatedAt = .now
                        }
                    } label: {
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
                .disabled(reviewItems.isEmpty)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)
            .padding(.vertical, CentmondTheme.Spacing.lg)
            .background(CentmondTheme.Colors.bgSecondary)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CentmondTheme.Colors.strokeSubtle).frame(height: 1)
            }

            // Items
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(reviewItems) { tx in
                        ReviewItemRow(
                            transaction: tx,
                            categories: categories,
                            onAccept: {
                                tx.isReviewed = true
                                tx.updatedAt = .now
                            },
                            onInspect: { router.inspectTransaction(tx.id) },
                            onCategorize: { category in
                                tx.category = category
                                tx.isReviewed = true
                                tx.updatedAt = .now
                            }
                        )
                    }
                }
            }
        }
    }

    private func filterChip(label: String, reason: ReviewReason?, count: Int) -> some View {
        let isActive = filterReason == reason
        return Button {
            withAnimation(CentmondTheme.Motion.micro) { filterReason = reason }
        } label: {
            HStack(spacing: 4) {
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

    // MARK: - Triage View

    private var triageView: some View {
        VStack(spacing: CentmondTheme.Spacing.xxl) {
            // Header
            HStack {
                Button {
                    triageMode = false
                } label: {
                    Label("Back to List", systemImage: "chevron.left")
                }
                .buttonStyle(GhostButtonStyle())

                Spacer()

                if !reviewItems.isEmpty && currentIndex < reviewItems.count {
                    Text("\(currentIndex + 1) of \(reviewItems.count)")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                }

                Spacer()

                // Progress bar
                GeometryReader { geo in
                    let progress = reviewItems.isEmpty ? 1.0 : Double(currentIndex) / Double(reviewItems.count)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(CentmondTheme.Colors.strokeSubtle)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(CentmondTheme.Colors.accent)
                            .frame(width: geo.size.width * progress)
                            .animation(CentmondTheme.Motion.default, value: progress)
                    }
                }
                .frame(width: 200, height: 4)
            }
            .padding(.horizontal, CentmondTheme.Spacing.xxl)

            if currentIndex < reviewItems.count {
                let tx = reviewItems[currentIndex]

                VStack(spacing: CentmondTheme.Spacing.xl) {
                    // Amount
                    Text(CurrencyFormat.standard(tx.amount))
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .foregroundStyle(tx.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary)
                        .monospacedDigit()

                    // Payee
                    Text(tx.payee)
                        .font(CentmondTheme.Typography.heading2)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    // Details
                    HStack(spacing: CentmondTheme.Spacing.xxl) {
                        Label(tx.date.formatted(.dateTime.month(.abbreviated).day().year()), systemImage: "calendar")
                        if let account = tx.account {
                            Label(account.name, systemImage: account.type.iconName)
                        }
                        Label(tx.status.displayName, systemImage: "circle.fill")
                            .foregroundStyle(Color(hex: tx.status.dotColor))
                    }
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)

                    // Review reason badges
                    HStack(spacing: CentmondTheme.Spacing.sm) {
                        if tx.category == nil {
                            reasonBadge(text: "Needs Category", color: CentmondTheme.Colors.warning)
                        }
                        if tx.status == .pending {
                            reasonBadge(text: "Pending Status", color: Color(hex: "F59E0B"))
                        }
                    }

                    // Quick categorize (if uncategorized)
                    if tx.category == nil && !categories.isEmpty {
                        VStack(spacing: CentmondTheme.Spacing.sm) {
                            Text("ASSIGN CATEGORY")
                                .font(CentmondTheme.Typography.overline)
                                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                .tracking(0.5)

                            let displayCategories = Array(categories.prefix(8))
                            HFlow(spacing: 6) {
                                ForEach(displayCategories) { cat in
                                    Button {
                                        tx.category = cat
                                        tx.isReviewed = true
                                        tx.updatedAt = .now
                                        advance()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: cat.icon)
                                                .font(.system(size: 10))
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

                    Divider()
                        .background(CentmondTheme.Colors.strokeSubtle)
                        .frame(maxWidth: 400)

                    // Action buttons
                    HStack(spacing: CentmondTheme.Spacing.lg) {
                        Button {
                            markReviewed(tx)
                        } label: {
                            Label("Accept (A)", systemImage: "checkmark")
                                .frame(width: 140)
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button {
                            advance()
                        } label: {
                            Label("Skip (S)", systemImage: "arrow.right")
                                .frame(width: 140)
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button {
                            router.inspectTransaction(tx.id)
                        } label: {
                            Label("Inspect (I)", systemImage: "sidebar.right")
                                .frame(width: 140)
                        }
                        .buttonStyle(GhostButtonStyle())
                    }

                    Text("A = Accept  \u{2022}  S = Skip  \u{2022}  I = Open Inspector  \u{2022}  1-8 = Assign Category")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
                .padding(CentmondTheme.Spacing.xxxl)
                .frame(maxWidth: 600)
                .background(CentmondTheme.Colors.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                        .stroke(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
                )
            } else {
                VStack(spacing: CentmondTheme.Spacing.lg) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(CentmondTheme.Colors.positive)

                    Text("All caught up!")
                        .font(CentmondTheme.Typography.heading2)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)

                    Button("Back to List") {
                        triageMode = false
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            Spacer()
        }
        .padding(.top, CentmondTheme.Spacing.xxl)
        .onKeyPress("a") {
            if currentIndex < reviewItems.count {
                markReviewed(reviewItems[currentIndex])
            }
            return .handled
        }
        .onKeyPress("s") {
            advance()
            return .handled
        }
        .onKeyPress("i") {
            if currentIndex < reviewItems.count {
                router.inspectTransaction(reviewItems[currentIndex].id)
            }
            return .handled
        }
        .onKeyPress(keys: ["1", "2", "3", "4", "5", "6", "7", "8"]) { press in
            guard currentIndex < reviewItems.count else { return .ignored }
            let tx = reviewItems[currentIndex]
            guard tx.category == nil else { return .ignored }
            let idx = Int(String(press.characters))! - 1
            guard idx < categories.count else { return .ignored }
            tx.category = categories[idx]
            tx.isReviewed = true
            tx.updatedAt = .now
            advance()
            return .handled
        }
    }

    private func reasonBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(CentmondTheme.Typography.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
    }

    private func markReviewed(_ tx: Transaction) {
        tx.isReviewed = true
        if tx.status == .pending { tx.status = .cleared }
        tx.updatedAt = .now
        advance()
    }

    private func advance() {
        withAnimation(CentmondTheme.Motion.default) {
            if currentIndex < reviewItems.count - 1 {
                currentIndex += 1
            } else {
                currentIndex = reviewItems.count
            }
        }
    }

}

// MARK: - Review Item Row

struct ReviewItemRow: View {
    let transaction: Transaction
    let categories: [BudgetCategory]
    var onAccept: () -> Void
    var onInspect: () -> Void
    var onCategorize: (BudgetCategory) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            // Reason icon
            Image(systemName: transaction.category == nil ? "questionmark.circle.fill" : "clock.fill")
                .font(.system(size: 16))
                .foregroundStyle(CentmondTheme.Colors.warning)
                .frame(width: 32)

            // Date
            Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .frame(width: 60, alignment: .leading)

            // Payee
            Text(transaction.payee)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            // Category
            if let cat = transaction.category {
                HStack(spacing: 3) {
                    Image(systemName: cat.icon)
                        .font(.system(size: 10))
                    Text(cat.name)
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(Color(hex: cat.colorHex))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color(hex: cat.colorHex).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
            } else {
                Text("Uncategorized")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(CentmondTheme.Colors.warning.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
            }

            // Amount
            Text(CurrencyFormat.standard(transaction.amount))
                .font(CentmondTheme.Typography.mono)
                .foregroundStyle(transaction.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary)
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)

            // Actions
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
        }
        .padding(.horizontal, CentmondTheme.Spacing.xxl)
        .frame(height: 44)
        .background(isHovered ? CentmondTheme.Colors.bgQuaternary : .clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { Haptics.tick() }
            withAnimation(CentmondTheme.Motion.micro) { isHovered = hovering }
        }
        .contextMenu {
            Button { onAccept() } label: {
                Label("Accept", systemImage: "checkmark.circle")
            }
            Button { onInspect() } label: {
                Label("Inspect", systemImage: "sidebar.right")
            }
            if transaction.category == nil {
                Divider()
                Menu("Assign Category") {
                    ForEach(categories) { cat in
                        Button {
                            onCategorize(cat)
                        } label: {
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

}
