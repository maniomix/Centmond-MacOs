import SwiftUI

struct SidebarView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            monthNavigator
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .padding(.vertical, CentmondTheme.Spacing.sm)

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            List(selection: $router.selectedScreen) {
                ForEach(SidebarSection.allCases) { section in
                    Section {
                        ForEach(section.screens) { screen in
                            sidebarItem(for: screen)
                                .tag(screen)
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
        }
        .background(CentmondTheme.Colors.bgSecondary)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(
            min: 200,
            ideal: CentmondTheme.Sizing.sidebarWidth,
            max: 260
        )
    }

    private var monthNavigator: some View {
        HStack(spacing: CentmondTheme.Spacing.xs) {
            Button {
                withAnimation(CentmondTheme.Motion.default) {
                    router.navigateMonth(by: -1)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
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
                    withAnimation(CentmondTheme.Motion.default) {
                        router.jumpToCurrentMonth()
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
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
                withAnimation(CentmondTheme.Motion.default) {
                    router.navigateMonth(by: 1)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
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
        Label {
            HStack {
                Text(screen.displayName)
                    .font(CentmondTheme.Typography.bodyMedium)

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

                if screen.requiresPro {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }
        } icon: {
            Image(systemName: screen.iconName)
                .font(.system(size: 16, weight: .medium))
                .symbolRenderingMode(.hierarchical)
        }
    }
}
