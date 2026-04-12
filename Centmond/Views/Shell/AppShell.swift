import SwiftUI
import SwiftData

struct AppShell: View {
    @Environment(\.modelContext) private var modelContext
    @State private var router = AppRouter()
    @State private var showCommandPalette = false
    @State private var didMaterializeRecurring = false

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { router.shouldShowInspector },
            set: { router.isInspectorVisible = $0 }
        )
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ContentRouter(screen: router.selectedScreen)
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
        .onKeyPress(action: handleKeyPress)
        .onChange(of: router.selectedScreen) { _, _ in
            router.inspectorContext = .none
        }
        .task {
            // Materialize any overdue recurring transactions exactly once
            // per app launch. RecurringService is idempotent — it advances
            // each template's nextOccurrence as it goes — so a second run
            // within the same session is a no-op, but we gate on a flag
            // anyway so we never block UI on startup work twice.
            guard !didMaterializeRecurring else { return }
            didMaterializeRecurring = true
            RecurringService.materializeDue(in: modelContext)
        }
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
