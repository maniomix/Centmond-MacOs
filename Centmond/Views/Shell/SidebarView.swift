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
                    .frame(width: 24, height: 24)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 1) {
                Text(router.selectedMonth.formatted(.dateTime.month(.wide)))
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .contentTransition(.numericText())

                Text(router.selectedMonth.formatted(.dateTime.year()))
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .contentTransition(.numericText())
            }
            .animation(CentmondTheme.Motion.default, value: router.selectedMonth)

            if !router.isCurrentMonth {
                Button {
                    withAnimation(CentmondTheme.Motion.default) {
                        router.jumpToCurrentMonth()
                    }
                } label: {
                    Text("Now")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CentmondTheme.Colors.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(CentmondTheme.Colors.accentMuted)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
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
                    .frame(width: 24, height: 24)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
            }
            .buttonStyle(.plain)
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
