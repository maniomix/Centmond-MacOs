import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(AppRouter.self) private var router
    @AppStorage("sidebarIconOnly") private var sidebarIconOnly = false
    @Query(sort: \HouseholdMember.joinedAt) private var householdMembers: [HouseholdMember]
    /// Which compact-sidebar screen the cursor is hovering. Drives the
    /// dock-style magnification ripple — hovered icon scales up, its
    /// immediate neighbors scale up a bit less.
    @State private var hoveredScreen: Screen? = nil

    private var allScreensInOrder: [Screen] {
        SidebarSection.allCases.flatMap { $0.screens }
    }

    private func dockDistance(for screen: Screen) -> Int {
        guard let hovered = hoveredScreen,
              let selfIdx = allScreensInOrder.firstIndex(of: screen),
              let hoverIdx = allScreensInOrder.firstIndex(of: hovered)
        else { return Int.max }
        return abs(selfIdx - hoverIdx)
    }

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            // Compact mode: hide the full month navigator (three-part
            // prev / day+month+year / next). Show a minimal "today jump"
            // if the user has navigated away, otherwise nothing — the
            // sidebar in compact mode is for navigation icons only.
            //
            // Extra top padding in compact mode clears the macOS
            // traffic-light area (~28pt tall at the window's top-left).
            // Without it the "18 APR" stack renders immediately under
            // the close/minimize/zoom dots and looks cramped because
            // the compact column is too narrow for content to sit
            // beside the dots the way the full navigator does.
            if sidebarIconOnly {
                compactMonthNavigator
                    .padding(.horizontal, 6)
                    .padding(.top, CentmondTheme.Spacing.xxxl)  // clear traffic lights
                    .padding(.bottom, CentmondTheme.Spacing.sm)
            } else {
                monthNavigator
                    .padding(.horizontal, CentmondTheme.Spacing.md)
                    .padding(.vertical, CentmondTheme.Spacing.sm)
            }

            // Household scope chips previously lived here; moved 2026-04-22
            // into the Transactions top bar because that's the only place the
            // scope actually filters today. Keeping it global in the sidebar
            // made it feel app-wide while only biting on Transactions.

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Compact mode uses a plain VStack — macOS `List(.sidebar)`
            // paints its OWN selection highlight (the filled blue
            // rounded rect) even when the row has `.listRowBackground(
            // .clear)`. That chrome was showing as a blue box behind
            // the custom dot-only selection indicator and made the
            // selected state look like a loud button instead of the
            // clean icon + dot we want. Plain VStack + manual Button
            // per row lets the selection be ONLY the accent-tinted
            // icon + small dot below — no system chrome competing.
            if sidebarIconOnly {
                VStack(spacing: 0) {
                    // Top breathing room above the first section's first
                    // icon. Without this the icon sits flush against
                    // the sidebar's top divider line — equivalent gap
                    // to what `.padding(.vertical, 14)` gives every
                    // subsequent section boundary, so the first and
                    // nth sections look symmetrical.
                    Color.clear.frame(height: 10)

                    ForEach(Array(SidebarSection.allCases.enumerated()), id: \.offset) { sectionIdx, section in
                        // Thin divider between sections (not before the
                        // first). `.padding(.vertical, 8)` gives the
                        // divider real breathing room on both sides —
                        // earlier `Spacer().frame(height:)` collapsed
                        // to zero in a fixed-content VStack because
                        // Spacer has no intrinsic size; it only fills
                        // leftover space, and there's no leftover in a
                        // VStack whose children are all fixed-size rows.
                        if sectionIdx > 0 {
                            // 14pt padding on each side of the divider
                            // (28pt total between adjacent rows). Needed
                            // because the dock-scale icons grow ~5pt up
                            // AND down from their center anchor, so the
                            // previous 8pt padding let them visually
                            // cross the divider line. 14pt gives clear
                            // visual breathing room + a real section
                            // separation that the eye groups at.
                            Rectangle()
                                .fill(CentmondTheme.Colors.strokeSubtle.opacity(0.5))
                                .frame(height: 0.5)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 14)
                        }
                        ForEach(section.screens) { screen in
                            CompactSidebarItem(
                                screen: screen,
                                isSelected: router.selectedScreen == screen,
                                dockDistance: dockDistance(for: screen),
                                onHoverChanged: { hovering in
                                    if hovering { hoveredScreen = screen }
                                },
                                onTap: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        router.selectedScreen = screen
                                    }
                                    Haptics.tap()
                                }
                            )
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                // ScrollViewReader wraps the List so we can override macOS's
                // default auto-scroll-to-selected-row behavior. Without this,
                // selecting `.household` (near the bottom of the list) scrolls
                // the top section headers out of view — visually pushing every
                // row "up" and hiding the first 6-8 items behind the titlebar
                // area. We intercept selection changes and reset scroll to the
                // first item instead so the sidebar always starts at the top.
                ScrollViewReader { proxy in
                    List(selection: $router.selectedScreen) {
                        ForEach(SidebarSection.allCases) { section in
                            Section {
                                ForEach(section.screens) { screen in
                                    sidebarItem(for: screen)
                                        .tag(screen)
                                        .id(screen)
                                }
                            } header: {
                                Text(section.displayName)
                                    .font(CentmondTheme.Typography.overline)
                                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                                    .tracking(0.5)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    // Pull the first section's native headroom in tighter —
                    // `.sidebar` style adds a chunky top inset before the
                    // first header which felt like dead space. Negative
                    // content-margin at the scroll-content layer trims it
                    // back to a small breathing gap without affecting
                    // inter-section spacing.
                    .contentMargins(.top, -12, for: .scrollContent)
                    .onChange(of: router.selectedScreen) { _, _ in
                        // Keep the sidebar anchored at the top item when the
                        // user changes screens. Prevents List's auto-scroll
                        // from hiding the first section behind the titlebar
                        // when later items (Household / Settings) are selected.
                        if let first = SidebarSection.allCases.first?.screens.first {
                            withAnimation(nil) {
                                proxy.scrollTo(first, anchor: .top)
                            }
                        }
                    }
                }
            }

            // Toggle button pinned to the bottom — reversible escape
            // hatch so users who turn on compact mode can get back to
            // the full sidebar without hunting for the Settings option
            // again. Also works as a one-click collapse for users who
            // prefer full mode day-to-day but occasionally want more
            // content space.
            Divider().background(CentmondTheme.Colors.strokeSubtle)
            compactToggleButton
                .padding(.horizontal, sidebarIconOnly ? 6 : CentmondTheme.Spacing.md)
                .padding(.vertical, CentmondTheme.Spacing.sm)
        }
        .background(CentmondTheme.Colors.bgSecondary)
        .onContinuousHover { phase in
            // Clear `hoveredScreen` only when the cursor leaves the
            // whole sidebar. Individual rows only SET the value on
            // enter; this handler is the sole place it goes back to
            // nil. Keeps the dock magnification alive across row
            // boundaries and section dividers.
            if case .ended = phase {
                hoveredScreen = nil
            }
        }
        // Note: no `.toolbar(removing: .sidebarToggle)` — keep the
        // native toggle in the toolbar so users always have an
        // escape route if the sidebar accidentally collapses. The
        // in-sidebar `compactToggleButton` toggles between compact
        // and full LAYOUT; the toolbar's sidebarToggle toggles
        // VISIBILITY of the whole column. Both are useful.
        .navigationSplitViewColumnWidth(
            // Compact mode: width must CONTAIN the macOS window
            // control buttons (close/minimize/zoom) at the window's
            // top-left. The three 12pt buttons + 8pt gaps + leading
            // inset span ~72pt horizontally. Earlier 68pt column was
            // narrower than the buttons themselves, so they spilled
            // past the sidebar's right edge into the main content
            // area. 84pt gives the buttons ~6pt of clearance on the
            // right and leaves room for a centered 36pt icon chip
            // below with balanced padding.
            min: sidebarIconOnly ? 84 : 200,
            ideal: sidebarIconOnly ? 84 : CentmondTheme.Sizing.sidebarWidth,
            max: sidebarIconOnly ? 84 : 260
        )
    }

    /// Toggle between compact (icon-only) and full sidebar modes.
    /// Full-width in full mode with icon + label; icon-only in
    /// compact mode. Spring animation on the toggle so the column
    /// width change feels intentional rather than a snap.
    private var compactToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                sidebarIconOnly.toggle()
            }
        } label: {
            if sidebarIconOnly {
                // Compact mode: centered chevron-right hints "expand."
                HStack {
                    Spacer()
                    Image(systemName: "sidebar.left")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(CentmondTheme.Colors.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
                    Spacer()
                }
                .help("Expand sidebar")
            } else {
                // Full mode: icon + "Collapse sidebar" label in the
                // same row style as the section items.
                HStack(spacing: CentmondTheme.Spacing.sm) {
                    Image(systemName: "sidebar.squares.left")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .frame(width: 20)
                    Text("Collapse sidebar")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, CentmondTheme.Spacing.sm)
                .frame(height: 32)
                .help("Collapse to icon-only")
            }
        }
        .buttonStyle(.plainHover)
    }

    // MARK: - Household scope strip (P6)

    private var activeHouseholdMembers: [HouseholdMember] {
        // Tombstone-safe: cloud-prune may delete a member mid-frame;
        // reading .isActive on the dead reference would fault.
        householdMembers
            .filter { $0.modelContext != nil && !$0.isDeleted }
            .filter(\.isActive)
    }

    private var memberScopeStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HOUSEHOLD")
                .font(CentmondTheme.Typography.overline)
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                .tracking(0.5)
            HStack(spacing: 4) {
                scopeAllPill
                ForEach(activeHouseholdMembers) { m in
                    scopeAvatar(m)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Fixed chip size shared by the "All" pill and every member avatar so
    /// the strip doesn't end up with mixed heights (22pt circles next to a
    /// taller text pill). Both render as a 22pt-tall capsule — "All" gets a
    /// bit of horizontal padding for its 3-letter label, avatars stay square.
    private static let scopeChipHeight: CGFloat = 22

    private var scopeAllPill: some View {
        let isActive = router.selectedMemberID == nil
        return Button {
            router.selectedMemberID = nil
        } label: {
            Text("All")
                .font(CentmondTheme.Typography.overlineSemibold)
                .foregroundStyle(isActive ? Color.white : CentmondTheme.Colors.textTertiary)
                .padding(.horizontal, 8)
                .frame(height: Self.scopeChipHeight)
                .background(isActive ? CentmondTheme.Colors.accent : CentmondTheme.Colors.bgTertiary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show everyone")
    }

    private func scopeAvatar(_ m: HouseholdMember) -> some View {
        let isActive = router.selectedMemberID == m.id
        return Button {
            // Click active → clear. Click inactive → scope to this member.
            router.selectedMemberID = isActive ? nil : m.id
        } label: {
            Text(String(m.name.prefix(1)))
                .font(CentmondTheme.Typography.overlineSemibold)
                .foregroundStyle(.white)
                .frame(width: Self.scopeChipHeight, height: Self.scopeChipHeight)
                .background(Color(hex: m.avatarColor))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(isActive ? CentmondTheme.Colors.accent : .clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .help(m.name)
    }

    /// Minimal month navigator for compact mode. No day bubble, no
    /// month/year text — just an accent-colored "jump to today" dot
    /// when the user has navigated away, otherwise a single
    /// day-of-month number for ambient orientation.
    private var compactMonthNavigator: some View {
        VStack(spacing: 4) {
            if router.isCurrentMonth {
                Text("\(Date.now.formatted(.dateTime.day()))")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .contentTransition(.numericText())
                Text(router.selectedMonth.formatted(.dateTime.month(.abbreviated)))
                    .font(CentmondTheme.Typography.micro.weight(.medium))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .textCase(.uppercase)
            } else {
                Button {
                    router.jumpToCurrentMonth()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(CentmondTheme.Typography.captionSmallSemibold.weight(.bold))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .frame(width: 28, height: 28)
                        .background(CentmondTheme.Colors.accentMuted)
                        .clipShape(Circle())
                }
                .buttonStyle(.plainHover)
                .help("Back to today")
                Text(router.selectedMonth.formatted(.dateTime.month(.abbreviated)))
                    .font(CentmondTheme.Typography.micro.weight(.medium))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .textCase(.uppercase)
            }
        }
        .frame(maxWidth: .infinity)
        .help("Currently viewing \(router.selectedMonth.formatted(.dateTime.month(.wide).year()))")
    }

    private var monthNavigator: some View {
        HStack(spacing: CentmondTheme.Spacing.xs) {
            Button {
                // No withAnimation wrapper: it opens a global animation
                // transaction that every dependent view (Dashboard charts,
                // Transactions list, Budget grid) then interpolates across,
                // which is the visible lag when months have data. The
                // `.animation(_:value:)` on the label below still handles
                // the numeric-text transition for just that header.
                router.navigateMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(CentmondTheme.Typography.captionSmallSemibold)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plainHover)
            .help("Previous month")

            Spacer()

            // Combined: today's day number + selected month/year
            HStack(spacing: 6) {
                if router.isCurrentMonth {
                    Text("\(Date.now.formatted(.dateTime.day()))")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .contentTransition(.numericText())
                        .transition(.scale.combined(with: .opacity))
                }

                VStack(alignment: router.isCurrentMonth ? .leading : .center, spacing: 0) {
                    Text(router.selectedMonth.formatted(.dateTime.month(.abbreviated)))
                        .font(router.isCurrentMonth
                              ? CentmondTheme.Typography.bodyMedium
                              : CentmondTheme.Typography.heading3)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .contentTransition(.numericText())
                        .lineLimit(1)

                    Text(router.selectedMonth.formatted(.dateTime.year()))
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .contentTransition(.numericText())
                }
            }
            .animation(CentmondTheme.Motion.numeric, value: router.selectedMonth)

            if !router.isCurrentMonth {
                Button {
                    router.jumpToCurrentMonth()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(CentmondTheme.Typography.overlineSemibold)
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .frame(width: 24, height: 24)
                        .background(CentmondTheme.Colors.accentMuted)
                        .clipShape(Circle())
                }
                .buttonStyle(.plainHover)
                .transition(.scale.combined(with: .opacity))
                .help("Back to today")
            }

            Spacer()

            Button {
                router.navigateMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(CentmondTheme.Typography.captionSmallSemibold)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plainHover)
            .help("Next month")
        }
    }

    @ViewBuilder
    private func sidebarItem(for screen: Screen) -> some View {
        // Full mode only. Compact mode renders `CompactSidebarItem`
        // directly in a VStack (see body above) so the List's sidebar
        // selection chrome doesn't paint over the custom dot indicator.
        Label {
                HStack(spacing: 4) {
                    Text(screen.displayName)
                        .font(CentmondTheme.Typography.bodyMedium)

                    if screen.isBeta {
                        BetaCapsule()
                    }

                    Spacer()

                    if screen == .reviewQueue && router.reviewQueueCount > 0 {
                        Text("\(router.reviewQueueCount)")
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(CentmondTheme.Colors.negative)
                            .clipShape(Capsule())
                    }

                }
            } icon: {
                Image(systemName: screen.iconName)
                    .font(CentmondTheme.Typography.subheading.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
            }
    }
}

// BetaCapsule and BetaBanner are INTERNAL (not fileprivate) so
// AIChatView and AIPredictionView can use them for their header
// banners. Both use the same warning-orange palette so the sidebar
// capsule and the screen-level banner read as the same "beta" motif.

/// Small "BETA" capsule — used in sidebar rows next to beta screens.
/// Warning-orange tint with a subtle stroke: soft caution, not alarm.
struct BetaCapsule: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(CentmondTheme.Colors.warning)
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(CentmondTheme.Colors.warning.opacity(0.14))
            .overlay(
                Capsule()
                    .stroke(CentmondTheme.Colors.warning.opacity(0.35), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}

/// Full-width banner placed at the top of every beta screen body so
/// users know the feature is WIP at the screen level, not just in the
/// sidebar. "Chat / Predictions" title + BETA capsule + a terse one-
/// liner. Padded and visually grouped against the screen's content.
struct BetaBanner: View {
    let title: String
    var body: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            BetaCapsule()
            Text(title)
                .font(CentmondTheme.Typography.captionSmallSemibold)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Text("·")
                .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            Text("This feature is still being polished. Expect rough edges.")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.warning.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CentmondTheme.Colors.warning.opacity(0.3))
                .frame(height: 0.5)
        }
    }
}

// MARK: - Compact Sidebar Item (per-row dock-distance hover)
//
// Each icon row receives its DISTANCE from the currently-hovered row
// (measured in rows, not pixels). Scales progressively:
//   distance 0 (self): 1.30
//   distance 1 (neighbor): 1.15
//   distance 2: 1.05
//   distance ≥ 3: 1.00
// Selected state is a tiny accent dot below the icon (dock's
// "app is currently running" indicator) + accent-tinted icon.
// No filled background box.
fileprivate struct CompactSidebarItem: View {
    let screen: Screen
    let isSelected: Bool
    /// 0 = self-hovered; 1 = immediate neighbor; higher = farther.
    /// `Int.max` when nothing is hovered in the sidebar.
    let dockDistance: Int
    let onHoverChanged: (Bool) -> Void
    let onTap: () -> Void

    @State private var isHovered = false

    private var dockScale: CGFloat {
        switch dockDistance {
        case 0: return 1.30
        case 1: return 1.15
        case 2: return 1.05
        default: return 1.00
        }
    }

    private var iconColor: Color {
        if isSelected { return CentmondTheme.Colors.accent }
        if isHovered  { return CentmondTheme.Colors.textPrimary }
        return CentmondTheme.Colors.textSecondary
    }

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: screen.iconName)
                        .font(CentmondTheme.Typography.subheading.weight(.medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(iconColor)
                        // `.bottom` anchor made the icon grow UPWARD only,
                        // crossing the section-divider line above it on
                        // dock hover. `.center` grows symmetrically (half
                        // up, half down) so the icon stays within its row's
                        // vertical extent.
                        .scaleEffect(dockScale, anchor: .center)

                    // Tiny beta dot on the icon's top-right corner in
                    // compact mode — a full "BETA" capsule wouldn't
                    // fit in the 84pt column. Dot + `.help(...)`
                    // tooltip reveals the beta label on hover.
                    if screen.isBeta {
                        Circle()
                            .fill(CentmondTheme.Colors.warning)
                            .frame(width: 5, height: 5)
                            .overlay(Circle().stroke(CentmondTheme.Colors.bgSecondary, lineWidth: 1))
                            .offset(x: 8, y: -3)
                    }
                }

                Circle()
                    .fill(CentmondTheme.Colors.accent)
                    .frame(width: 4, height: 4)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(height: 32)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering)
            if hovering { Haptics.tick() }
        }
        .help(screen.isBeta ? "\(screen.displayName) (Beta)" : screen.displayName)
        // Smoother ease-in-out curve instead of spring — the previous
        // `.spring(response: 0.25, dampingFraction: 0.7)` had a slight
        // overshoot+settle that read as a "click" rather than a glide.
        // EaseInOut moves straight from one scale to the next without
        // overshoot, matching the silky dock-magnification feel.
        .animation(.easeInOut(duration: 0.22), value: dockDistance)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}
