import SwiftUI
import SwiftData

/// Grid card for a single Subscription. Designed to stay equal-height across
/// a row by pinning the structure: icon row (fixed), name/cadence row (fixed),
/// sparkline (fixed slot), amount row (fixed). Variable content lives in the
/// badge row which wraps.
///
/// Visual tiers by status:
/// - `.active` → standard dark card
/// - `.trial` → accent-tinted border + "TRIAL" badge
/// - `.paused` → dimmed (0.6 opacity) + "PAUSED" badge
/// - `.cancelled` → heavily dimmed (0.4) + strikethrough name
///
/// The badge row shows at most three chips so the card doesn't shift height
/// between rows — anything beyond three is summarised as "+N".
struct SubscriptionCard: View {
    let subscription: Subscription
    let isSelected: Bool
    var onTap: () -> Void

    var body: some View {
        // Guard against tombstoned SwiftData models. When a
        // Subscription is deleted (e.g. by the cloud-prune step
        // running after iOS deletes a sub on the other device),
        // there's a frame where the @Query parent view's body
        // still holds a reference to the now-detached instance.
        // Reading any persisted attribute on it (.status, .amount,
        // .serviceName, …) faults with "This backing data was
        // detached from a context without resolving attribute
        // faults." Render nothing for that frame; @Query will
        // republish on the next runloop and the row drops out.
        if subscription.modelContext == nil || subscription.isDeleted {
            return AnyView(EmptyView())
        }
        return AnyView(
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                    headerRow
                    nameRow
                    sparklineRow
                    badgeRow
                    Spacer(minLength: 0)
                    amountRow
                }
                .padding(CentmondTheme.Spacing.lg)
                .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                .background(cardBackground)
                .overlay(cardBorder)
                .contentShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
                .opacity(cardOpacity)
            }
            .buttonStyle(.plain)
        )
    }

    // MARK: - Rows

    private var headerRow: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            iconBadge
            Spacer()
            if subscription.autoDetected {
                Image(systemName: "wand.and.stars")
                    .font(CentmondTheme.Typography.overlineSemibold)
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .help("Auto-detected")
            }
            statusPill
        }
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .fill(iconTint.opacity(0.18))
            Image(systemName: subscription.iconSymbol ?? "arrow.triangle.2.circlepath")
                .font(CentmondTheme.Typography.bodyMedium.weight(.semibold))
                .foregroundStyle(iconTint)
        }
        .frame(width: 30, height: 30)
    }

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subscription.serviceName)
                .font(CentmondTheme.Typography.heading3)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .lineLimit(1)
                .strikethrough(subscription.status == .cancelled)
            Text(cadenceLabel)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .lineLimit(1)
        }
    }

    private var sparklineRow: some View {
        SubscriptionPriceSparkline(
            amounts: sparklineValues,
            tint: sparklineTint
        )
    }

    private var badgeRow: some View {
        // `allBadges` traverses the SwiftData `charges` and `priceHistory`
        // relationships (each access can fault). Was computed three times
        // per body render via `visibleBadges` (prefix) + `overflowBadgeCount`
        // (count) + the original `allBadges`. Compute once, slice locally.
        let badges = allBadges
        let visible = Array(badges.prefix(3))
        let overflow = max(0, badges.count - 3)
        return HStack(spacing: 6) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, badge in
                badgeChip(badge)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(CentmondTheme.Typography.micro.weight(.semibold).monospacedDigit())
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(CentmondTheme.Colors.bgQuaternary, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18) // reserve slot so cards without badges still align
    }

    private var amountRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(CurrencyFormat.standard(subscription.amount))
                .font(CentmondTheme.Typography.monoLarge)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Text(cycleSuffix)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Spacer()
            nextChargeInline
        }
    }

    private var nextChargeInline: some View {
        let daysOut = Calendar.current.dateComponents([.day], from: .now, to: subscription.nextPaymentDate).day ?? 0
        let label: String = {
            if subscription.isPastDue { return "Past due" }
            if daysOut == 0 { return "Today" }
            if daysOut == 1 { return "Tomorrow" }
            if daysOut < 0 { return "Late" }
            return "in \(daysOut)d"
        }()
        let tint: Color = subscription.isPastDue
            ? CentmondTheme.Colors.negative
            : (daysOut <= 2 ? CentmondTheme.Colors.warning : CentmondTheme.Colors.textTertiary)
        return Text(label)
            .font(CentmondTheme.Typography.caption)
            .foregroundStyle(tint)
    }

    // MARK: - Badges

    /// Derived list of status chips. Order matters — urgent things first so
    /// the three-slot truncation keeps them visible.
    private var visibleBadges: [Badge] {
        Array(allBadges.prefix(3))
    }

    private var overflowBadgeCount: Int {
        max(0, allBadges.count - 3)
    }

    private var allBadges: [Badge] {
        var out: [Badge] = []

        if subscription.isPastDue {
            out.append(Badge(icon: "exclamationmark.triangle.fill",
                             text: "Past due",
                             tint: CentmondTheme.Colors.negative))
        }

        if subscription.charges.contains(where: { $0.isFlaggedDuplicate }) {
            out.append(Badge(icon: "exclamationmark.2",
                             text: "Dup",
                             tint: CentmondTheme.Colors.negative))
        }

        if let change = subscription.priceHistory
            .filter({ !$0.acknowledged })
            .max(by: { $0.date < $1.date }) {
            let pct = Int(abs(change.changePercent) * 100)
            let up = change.changePercent >= 0
            out.append(Badge(
                icon: up ? "arrow.up.right" : "arrow.down.right",
                text: "\(up ? "+" : "-")\(pct)%",
                tint: up ? CentmondTheme.Colors.warning : CentmondTheme.Colors.positive
            ))
        }

        if subscription.isTrial, let end = subscription.trialEndsAt {
            let days = Calendar.current.dateComponents([.day], from: .now, to: end).day ?? Int.max
            if days >= 0 && days <= 7 {
                out.append(Badge(icon: "clock.fill",
                                 text: "Ends \(days)d",
                                 tint: CentmondTheme.Colors.accent))
            }
        }

        return out
    }

    private func badgeChip(_ badge: Badge) -> some View {
        HStack(spacing: 3) {
            Image(systemName: badge.icon).font(CentmondTheme.Typography.microBold)
            Text(badge.text).font(CentmondTheme.Typography.micro.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(badge.tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(badge.tint.opacity(0.12), in: Capsule())
    }

    private struct Badge {
        let icon: String
        let text: String
        let tint: Color
    }

    // MARK: - Status pill

    private var statusPill: some View {
        let (text, tint) = statusPillData
        return Text(text)
            .font(CentmondTheme.Typography.overline)
            .foregroundStyle(tint)
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var statusPillData: (String, Color) {
        switch subscription.status {
        case .active:    return ("ACTIVE", CentmondTheme.Colors.positive)
        case .trial:     return ("TRIAL", CentmondTheme.Colors.accent)
        case .paused:    return ("PAUSED", CentmondTheme.Colors.warning)
        case .cancelled: return ("CANCELLED", CentmondTheme.Colors.textTertiary)
        }
    }

    // MARK: - Helpers

    private var sparklineValues: [Double] {
        // Combine historical prices + the current amount so a subscription
        // with no price-change history still renders as a flat line — better
        // than an empty slot that makes some cards taller than others.
        var values: [Double] = []
        let sorted = subscription.priceHistory.sorted { $0.date < $1.date }
        if let first = sorted.first {
            values.append((first.oldAmount as NSDecimalNumber).doubleValue)
        }
        for change in sorted {
            values.append((change.newAmount as NSDecimalNumber).doubleValue)
        }
        values.append((subscription.amount as NSDecimalNumber).doubleValue)
        return values
    }

    private var sparklineTint: Color {
        let recent = subscription.priceHistory
            .filter { !$0.acknowledged }
            .max(by: { $0.date < $1.date })
        if let r = recent, r.changePercent >= 0.05 { return CentmondTheme.Colors.warning }
        if let r = recent, r.changePercent <= -0.05 { return CentmondTheme.Colors.positive }
        return CentmondTheme.Colors.accent
    }

    private var iconTint: Color {
        if let hex = subscription.colorHex {
            return Color(hex: hex)
        }
        return CentmondTheme.Colors.accent
    }

    private var cadenceLabel: String {
        if subscription.billingCycle == .custom, let days = subscription.customCadenceDays {
            return "Every \(days) days"
        }
        return subscription.billingCycle.displayName
    }

    private var cycleSuffix: String {
        switch subscription.billingCycle {
        case .weekly: return "/wk"
        case .biweekly: return "/2wk"
        case .monthly: return "/mo"
        case .quarterly: return "/qtr"
        case .semiannual: return "/6mo"
        case .annual: return "/yr"
        case .custom: return "/cycle"
        }
    }

    private var cardOpacity: Double {
        switch subscription.status {
        case .active, .trial: return 1.0
        case .paused: return 0.6
        case .cancelled: return 0.4
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
            .fill(CentmondTheme.Colors.bgSecondary)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
            .stroke(borderColor, lineWidth: isSelected ? 1.5 : 1)
    }

    private var borderColor: Color {
        if isSelected { return CentmondTheme.Colors.accent }
        if subscription.status == .trial { return CentmondTheme.Colors.accent.opacity(0.35) }
        if subscription.isPastDue { return CentmondTheme.Colors.negative.opacity(0.4) }
        return CentmondTheme.Colors.strokeSubtle
    }
}
