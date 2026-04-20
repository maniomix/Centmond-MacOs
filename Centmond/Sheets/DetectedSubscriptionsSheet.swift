import SwiftUI
import SwiftData

/// Review queue for subscriptions the detector found but the user hasn't
/// confirmed yet. Mirrors `AllocationPreviewSheet`'s role for goal rules: we
/// never auto-create subscriptions from detection — the user has to see every
/// candidate and say yes. Confirm mints a `Subscription` + `SubscriptionCharge`
/// rows via `SubscriptionDetector.confirm`; dismiss writes a
/// `DismissedDetection` so the row doesn't re-surface.
struct DetectedSubscriptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var candidates: [DetectedSubscriptionCandidate] = []
    @State private var selected: Set<UUID> = []
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(CentmondTheme.Colors.strokeSubtle)

            if candidates.isEmpty && hasLoaded {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                    .padding(.horizontal, CentmondTheme.Spacing.lg)
                    .padding(.vertical, CentmondTheme.Spacing.md)
                }
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)
            footer
        }
        .frame(height: 560)
        .background(CentmondTheme.Colors.bgPrimary)
        .onAppear(perform: load)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CentmondTheme.Colors.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Detected subscriptions")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(CentmondTheme.Colors.bgQuaternary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plainHover)
        }
        .padding(CentmondTheme.Spacing.lg)
    }

    private var subtitle: String {
        if !hasLoaded { return "Scanning transactions…" }
        if candidates.isEmpty { return "No new recurring patterns found." }
        return "\(candidates.count) candidate\(candidates.count == 1 ? "" : "s") — review before anything is created."
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: CentmondTheme.Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundStyle(CentmondTheme.Colors.positive.opacity(0.7))
            Text("All caught up")
                .font(CentmondTheme.Typography.heading3)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Text("Detector found no new subscription patterns.\nRe-run after you import more transactions.")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row

    private func candidateRow(_ candidate: DetectedSubscriptionCandidate) -> some View {
        let isOn = selected.contains(candidate.id)
        return HStack(spacing: CentmondTheme.Spacing.sm) {
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    if newValue { selected.insert(candidate.id) }
                    else { selected.remove(candidate.id) }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(CentmondTheme.Colors.accent)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.displayName)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .lineLimit(1)
                    if candidate.hasPriceChange, let pct = candidate.priceChangePercent {
                        priceChangeBadge(pct)
                    }
                }
                Text(rowSubtitle(candidate))
                    .font(.system(size: 10))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: CentmondTheme.Spacing.sm)

            confidenceChip(candidate.confidence)

            Text(CurrencyFormat.standard(candidate.amount))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .frame(width: 84, alignment: .trailing)

            Button {
                dismissCandidate(candidate)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(CentmondTheme.Colors.bgQuaternary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plainHover)
            .help("Don't show this again")
        }
        .frame(height: 48)
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgSecondary)
        .opacity(isOn ? 1 : 0.65)
    }

    private func rowSubtitle(_ c: DetectedSubscriptionCandidate) -> String {
        let cadence = cadenceLabel(c)
        let next = c.nextPredictedDate.formatted(.dateTime.month(.abbreviated).day())
        return "\(cadence) · \(c.chargeCount) charges · next ~\(next)"
    }

    private func cadenceLabel(_ c: DetectedSubscriptionCandidate) -> String {
        if c.billingCycle == .custom, let days = c.customCadenceDays {
            return "Every \(days) days"
        }
        return c.billingCycle.displayName
    }

    private func confidenceChip(_ value: Double) -> some View {
        let pct = Int((value * 100).rounded())
        let tint: Color = value >= 0.8
            ? CentmondTheme.Colors.positive
            : (value >= 0.6 ? CentmondTheme.Colors.accent : CentmondTheme.Colors.warning)
        return Text("\(pct)%")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func priceChangeBadge(_ pct: Double) -> some View {
        let up = pct >= 0
        let sign = up ? "+" : ""
        return HStack(spacing: 3) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 8, weight: .bold))
            Text("\(sign)\(Int((pct * 100).rounded()))%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(up ? CentmondTheme.Colors.warning : CentmondTheme.Colors.positive)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background((up ? CentmondTheme.Colors.warning : CentmondTheme.Colors.positive).opacity(0.12), in: Capsule())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            if !candidates.isEmpty {
                Button(selected.count == candidates.count ? "Deselect all" : "Select all") {
                    if selected.count == candidates.count {
                        selected.removeAll()
                    } else {
                        selected = Set(candidates.map(\.id))
                    }
                }
                .buttonStyle(.plainHover)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .font(CentmondTheme.Typography.caption)
            }

            Spacer()

            Button("Close") {
                dismiss()
            }
            .buttonStyle(SecondaryButtonStyle())

            if !candidates.isEmpty {
                Button("Add \(selected.count) subscription\(selected.count == 1 ? "" : "s")") {
                    confirmSelected()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.4 : 1)
            }
        }
        .padding(CentmondTheme.Spacing.lg)
    }

    // MARK: - Actions

    private func load() {
        guard !hasLoaded else { return }
        // P9: consume any hinted keys stashed by the last CSV import so those
        // merchants surface with a confidence boost + lowered threshold. Pops
        // on first read — the next open starts from a clean slate.
        let hints = SubscriptionDetector.consumeHintedKeys()
        candidates = SubscriptionDetector.detect(context: modelContext, hintedMerchantKeys: hints)
        // Pre-select high-confidence candidates — anything the detector is
        // confident about, the user almost always wants to keep. They can
        // still deselect individually.
        selected = Set(candidates.filter { $0.confidence >= 0.75 }.map(\.id))
        hasLoaded = true
    }

    private func dismissCandidate(_ candidate: DetectedSubscriptionCandidate) {
        Haptics.impact()
        SubscriptionDetector.dismiss(candidate, context: modelContext)
        candidates.removeAll { $0.id == candidate.id }
        selected.remove(candidate.id)
    }

    private func confirmSelected() {
        Haptics.impact()
        let keep = candidates.filter { selected.contains($0.id) }
        for candidate in keep {
            SubscriptionDetector.confirm(candidate, context: modelContext)
        }
        dismiss()
    }
}
