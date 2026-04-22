import SwiftUI
import SwiftData
import KeyboardShortcuts

struct AppShell: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter()
    @State private var showCommandPalette = false
    @Query private var transactions: [Transaction]
    // Debounce for the scheduled-services pipeline. Scene-active fires on
    // every foreground return (cmd-tab, notification, spotlight, etc.).
    // Without this gate each wake ran Recurring + NetWorth + AIInsight +
    // ReportSchedule — four full-table scans — no matter how recent the
    // last run. 30s gate keeps intent (catch new day) but kills churn.
    @State private var lastPipelineRun: Date?
    private static let pipelineDebounceSeconds: TimeInterval = 30
    /// Explicit control of sidebar visibility. Default `.all` = sidebar
    /// always shown on launch. Without this binding the system could
    /// auto-collapse the sidebar (window too narrow, previous-session
    /// state restore, user drag-collapsed it), and because SidebarView
    /// strips the native `.sidebarToggle` toolbar button, there would
    /// be no way for the user to bring it back. With the binding we
    /// can `columnVisibility = .all` programmatically and the sidebar
    /// re-appears.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Runs the scheduled-services pipeline (Recurring + NetWorth history +
    /// AI insights + Report schedules). `force=true` skips the debounce
    /// (used for launch + midnight ticks). `force=false` respects the
    /// 30-second gate so scene-active foreground returns don't thrash.
    private func runScheduledPipeline(force: Bool) {
        if !force, let last = lastPipelineRun,
           Date.now.timeIntervalSince(last) < Self.pipelineDebounceSeconds {
            return
        }
        _ = RecurringScheduler.tick(in: modelContext)
        NetWorthHistoryService.tick(context: modelContext)
        AIInsightEngine.shared.refresh(context: modelContext)
        ReportScheduleService.runDueSchedules(context: modelContext)
        lastPipelineRun = .now
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { router.shouldShowInspector },
            set: { router.isInspectorVisible = $0 }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            ContentRouter(screen: router.selectedScreen)
                .background {
                    // Click on empty/unclaimed content area closes any open
                    // shell-level panels (inspector, command palette). Children
                    // that consume the tap (rows, buttons, charts) are not
                    // affected — `.background` only receives taps that bubble
                    // past every foreground view.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { dismissShellPanels() }
                }
                .inspector(isPresented: inspectorBinding) {
                    InspectorView(context: router.inspectorContext)
                        .inspectorColumnWidth(
                            min: 240,
                            ideal: CentmondTheme.Sizing.inspectorWidth,
                            max: 400
                        )
                }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .environment(router)
        .frame(
            minWidth: CentmondTheme.Sizing.minWindowWidth,
            minHeight: CentmondTheme.Sizing.minWindowHeight
        )
        .background(CentmondTheme.Colors.bgPrimary)
        .preferredColorScheme(.dark)
        .sheet(item: $router.activeSheet) { sheet in
            SheetRouter(sheet: sheet)
                .environment(router)
        }
        .overlay {
            if showCommandPalette {
                CommandPaletteView(
                    isPresented: $showCommandPalette,
                    router: router
                )
            }
        }
        .overlay {
            if router.isOnboardingVisible {
                OnboardingOverlay()
                    .environment(router)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.isOnboardingVisible)
        .onKeyPress(action: handleKeyPress)
        .onReceive(NotificationCenter.default.publisher(for: .replayOnboarding)) { _ in
            router.replayOnboarding()
        }
        .onChange(of: router.selectedScreen) { _, _ in
            router.inspectorContext = .none
        }
        .task {
            // Continuous recurring pipeline: tick on launch, then re-tick
            // every midnight while the app stays in the foreground. The
            // scenePhase observer below covers wake-from-background.
            // RecurringScheduler.tick is idempotent so overlapping fires
            // are harmless.
            // First launch on a fresh store: fill a year of daily
            // Net Worth history from current balances + transaction
            // deltas so the trend chart isn't empty on day zero.
            NetWorthHistoryService.backfillIfNeeded(context: modelContext)

            while !Task.isCancelled {
                runScheduledPipeline(force: true)
                let delay = RecurringScheduler.secondsUntilNextMidnight()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            runScheduledPipeline(force: false)
        }
        // Review Queue hidden — transaction churn no longer needs to
        // repoll its count.
        // .onChange(of: transactions.count) { _, _ in
        //     refreshReviewQueueCount()
        // }
        .onAppear {
            // Guarantee the sidebar is visible on app launch. macOS
            // auto-restores the previous session's column visibility
            // state, which can land on `.detailOnly` if the user ever
            // collapsed it — and without the sidebar toggle button
            // they have no way back.
            columnVisibility = .all
            router.presentOnboardingIfNeeded(isEmpty: transactions.isEmpty)
        }
        .task {
            for await _ in KeyboardShortcuts.events(for: .toggleAIChat) {
                router.navigate(to: .aiChat)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - Panel Dismissal

extension AppShell {
    /// Rebuilds the review queue count on a background dispatch so the
    /// main thread is free to render the sidebar + dashboard while the
    /// scan runs. Result is published back onto the router on MainActor.
    ///
    /// Why not synchronous: on a multi-thousand-row store the scan is
    /// still non-trivial (detectors traverse faulting relationships)
    /// and synchronous calls on launch + scene-active caused jank that
    /// looked like the Review Queue screen hanging.
    func refreshReviewQueueCount() {
        let ctx = modelContext
        Task { @MainActor in
            let count = ReviewQueueService.buildQueue(in: ctx).count
            router.reviewQueueCount = count
        }
    }

    /// Closes any shell-level panels that are currently open. Returns
    /// whether anything was actually closed, so callers (Esc key,
    /// background tap) can decide if the event was consumed.
    @discardableResult
    func dismissShellPanels() -> Bool {
        // While onboarding is up it owns the foreground — don't let shell
        // Esc/empty-click cascade into inspector/palette dismissal behind
        // the overlay. The overlay itself handles its own Esc.
        if router.isOnboardingVisible { return false }
        var closed = false
        if showCommandPalette {
            showCommandPalette = false
            closed = true
        }
        if router.isInspectorVisible {
            router.isInspectorVisible = false
            closed = true
        }
        return closed
    }
}

// MARK: - Keyboard Shortcut Handling

extension AppShell {

    /// Positional screen shortcuts: Cmd+1 through Cmd+9
    private static let numberScreens: [Character: Screen] = [
        "1": .dashboard,
        "2": .transactions,
        "3": .budget,
        "4": .accounts,
        "5": .goals,
        "6": .subscriptions,
        "7": .recurring,
        "8": .forecasting,
        "9": .insights,
        "0": .aiChat,
    ]

    func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // Esc closes shell-level panels. Sheets and popovers dismiss
        // themselves; command palette also self-handles Esc — we only
        // need to cover the inspector here. Onboarding takes priority
        // while visible so the user can bail mid-tour.
        if keyPress.key == .escape {
            if router.isOnboardingVisible {
                router.completeOnboarding(skipped: true, atStep: 0)
                return .handled
            }
            return dismissShellPanels() ? .handled : .ignored
        }

        guard keyPress.modifiers.contains(.command) else { return .ignored }

        let key = keyPress.characters

        // App actions
        switch key {
        case "k":
            showCommandPalette.toggle()
            return .handled
        case "i":
            router.isInspectorVisible.toggle()
            return .handled
        case "n":
            router.showSheet(.newTransaction)
            return .handled
        default:
            break
        }

        // Mnemonic navigation
        switch key {
        case "d":
            router.navigate(to: .dashboard)
            return .handled
        case "t":
            router.navigate(to: .transactions)
            return .handled
        case "b":
            router.navigate(to: .budget)
            return .handled
        default:
            break
        }

        // Positional navigation (Cmd+1..9)
        if let char = key.first, let screen = Self.numberScreens[char] {
            router.navigate(to: screen)
            return .handled
        }

        return .ignored
    }
}
