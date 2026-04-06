import SwiftUI

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let router: AppRouter
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var hoveredID: UUID?

    private var filteredCommands: [PaletteCommand] {
        if searchText.isEmpty { return PaletteCommand.allCommands }
        let query = searchText.lowercased()
        return PaletteCommand.allCommands.filter {
            $0.title.lowercased().contains(query) ||
            $0.category.lowercased().contains(query)
        }
    }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            // Palette
            VStack(spacing: 0) {
                // Search field
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)

                    TextField("Type a command or search...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }
                .padding(.horizontal, CentmondTheme.Spacing.lg)
                .frame(height: 48)

                Divider()
                    .background(CentmondTheme.Colors.strokeSubtle)

                // Results
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            let commands = filteredCommands
                            let grouped = Dictionary(grouping: commands, by: \.category)
                            let sortedCategories = grouped.keys.sorted()

                            ForEach(sortedCategories, id: \.self) { category in
                                Text(category.uppercased())
                                    .font(CentmondTheme.Typography.overline)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .tracking(0.5)
                                    .padding(.horizontal, CentmondTheme.Spacing.lg)
                                    .padding(.top, CentmondTheme.Spacing.sm)
                                    .padding(.bottom, CentmondTheme.Spacing.xs)

                                ForEach(grouped[category] ?? []) { command in
                                    let index = commands.firstIndex(where: { $0.id == command.id }) ?? 0
                                    commandRow(command, isHighlighted: index == selectedIndex)
                                        .id(command.id)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selectedIndex) { _, newIndex in
                        let commands = filteredCommands
                        if newIndex >= 0 && newIndex < commands.count {
                            proxy.scrollTo(commands[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
            .background(CentmondTheme.Colors.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                    .stroke(CentmondTheme.Colors.strokeDefault, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 48, y: 16)
            .frame(width: CentmondTheme.Sizing.commandPaletteWidth)
            .padding(.top, 120)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredCommands.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.return) {
            let commands = filteredCommands
            if selectedIndex >= 0 && selectedIndex < commands.count {
                executeCommand(commands[selectedIndex])
            }
            return .handled
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
    }

    private func commandRow(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        Button {
            executeCommand(command)
        } label: {
            HStack(spacing: CentmondTheme.Spacing.md) {
                Image(systemName: command.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 20)

                Text(command.title)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                Spacer()

                if let shortcut = command.shortcutHint {
                    Text(shortcut)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                }
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .frame(height: 40)
            .background(
                isHighlighted || hoveredID == command.id
                    ? CentmondTheme.Colors.bgQuaternary
                    : .clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHover)
        .onHover { hovering in
            if hovering { Haptics.tick() }
            hoveredID = hovering ? command.id : nil
        }
    }

    private func executeCommand(_ command: PaletteCommand) {
        isPresented = false

        switch command.action {
        case .navigate(let screen):
            router.navigate(to: screen)
        case .sheet(let sheetType):
            router.showSheet(sheetType)
        case .toggleInspector:
            router.isInspectorVisible.toggle()
        }
    }
}

// MARK: - Palette Command Model

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let category: String
    let shortcutHint: String?
    let action: PaletteAction

    enum PaletteAction {
        case navigate(Screen)
        case sheet(SheetType)
        case toggleInspector
    }

    static let allCommands: [PaletteCommand] = [
        // Navigation
        PaletteCommand(title: "Go to Dashboard", icon: "house.fill", category: "Navigation", shortcutHint: "⌘D", action: .navigate(.dashboard)),
        PaletteCommand(title: "Go to Transactions", icon: "list.bullet.rectangle.fill", category: "Navigation", shortcutHint: "⌘T", action: .navigate(.transactions)),
        PaletteCommand(title: "Go to Budget", icon: "chart.pie.fill", category: "Navigation", shortcutHint: "⌘B", action: .navigate(.budget)),
        PaletteCommand(title: "Go to Accounts", icon: "building.columns.fill", category: "Navigation", shortcutHint: "⌘4", action: .navigate(.accounts)),
        PaletteCommand(title: "Go to Goals", icon: "target", category: "Navigation", shortcutHint: "⌘5", action: .navigate(.goals)),
        PaletteCommand(title: "Go to Subscriptions", icon: "arrow.triangle.2.circlepath", category: "Navigation", shortcutHint: "⌘6", action: .navigate(.subscriptions)),
        PaletteCommand(title: "Go to Recurring", icon: "repeat", category: "Navigation", shortcutHint: "⌘7", action: .navigate(.recurring)),
        PaletteCommand(title: "Go to Forecasting", icon: "chart.line.uptrend.xyaxis", category: "Navigation", shortcutHint: "⌘8", action: .navigate(.forecasting)),
        PaletteCommand(title: "Go to Insights", icon: "lightbulb.fill", category: "Navigation", shortcutHint: "⌘9", action: .navigate(.insights)),
        PaletteCommand(title: "Go to Net Worth", icon: "chart.bar.fill", category: "Navigation", shortcutHint: nil, action: .navigate(.netWorth)),
        PaletteCommand(title: "Go to Reports", icon: "doc.text.fill", category: "Navigation", shortcutHint: nil, action: .navigate(.reports)),
        PaletteCommand(title: "Go to Review Queue", icon: "tray.fill", category: "Navigation", shortcutHint: nil, action: .navigate(.reviewQueue)),
        PaletteCommand(title: "Go to Household", icon: "person.2.fill", category: "Navigation", shortcutHint: nil, action: .navigate(.household)),
        PaletteCommand(title: "Go to Settings", icon: "gearshape.fill", category: "Navigation", shortcutHint: nil, action: .navigate(.settings)),

        // Quick Actions
        PaletteCommand(title: "New Transaction", icon: "plus.circle.fill", category: "Quick Actions", shortcutHint: "⌘N", action: .sheet(.newTransaction)),
        PaletteCommand(title: "New Account", icon: "building.columns", category: "Quick Actions", shortcutHint: nil, action: .sheet(.newAccount)),
        PaletteCommand(title: "New Goal", icon: "target", category: "Quick Actions", shortcutHint: nil, action: .sheet(.newGoal)),
        PaletteCommand(title: "New Subscription", icon: "arrow.triangle.2.circlepath", category: "Quick Actions", shortcutHint: nil, action: .sheet(.newSubscription)),
        PaletteCommand(title: "Import CSV", icon: "square.and.arrow.down", category: "Quick Actions", shortcutHint: nil, action: .sheet(.importCSV)),
        PaletteCommand(title: "Export Data", icon: "square.and.arrow.up", category: "Quick Actions", shortcutHint: nil, action: .sheet(.export)),
        PaletteCommand(title: "Toggle Inspector", icon: "sidebar.right", category: "Quick Actions", shortcutHint: "⌘I", action: .toggleInspector),
    ]
}
