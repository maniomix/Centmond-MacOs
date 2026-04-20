import SwiftUI
import SwiftData

/// Review queue for recurring transactions the detector found below the
/// auto-confirm threshold. High-confidence patterns mint templates
/// silently in `RecurringScheduler.tick`; everything between
/// `minOccurrenceCount` and `autoConfirmThreshold` lands here so the
/// user can decide.
struct DetectedRecurringSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var candidates: [DetectedRecurringCandidate] = []
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
                Text("Detected recurring")
                    .font(CentmondTheme.Typography.heading3)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
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
        if candidates.isEmpty { return "Nothing new to review — high-confidence patterns were added automatically." }
        return "\(candidates.count) candidate\(candidates.count == 1 ? "" : "s") — confirm or dismiss."
    }

    // MARK: - Row

    private func candidateRow(_ c: DetectedRecurringCandidate) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            Image(systemName: c.isIncome ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(c.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative)

            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayName)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(c.frequency.displayName)
                    Text("•")
                    Text("\(c.occurrenceCount)× seen")
                    if let cat = c.suggestedCategoryName {
                        Text("•")
                        Text(cat).lineLimit(1)
                    }
                }
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(CurrencyFormat.compact(c.amount))
                    .font(CentmondTheme.Typography.mono)
                    .foregroundStyle(c.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.textPrimary)
                    .monospacedDigit()
                Text("\(Int(c.confidence * 100))% match")
                    .font(.system(size: 10))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
            }
            .frame(width: 110, alignment: .trailing)

            HStack(spacing: 6) {
                Button {
                    RecurringDetector.dismiss(c, in: modelContext)
                    candidates.removeAll { $0.id == c.id }
                    Haptics.tap()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(CentmondTheme.Colors.bgQuaternary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plainHover)
                .help("Dismiss — won't suggest again")

                Button {
                    RecurringDetector.confirm(c, in: modelContext)
                    candidates.removeAll { $0.id == c.id }
                    Haptics.impact()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(CentmondTheme.Colors.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plainHover)
                .help("Add as recurring")
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous))
    }

    // MARK: - Empty + Footer

    private var emptyState: some View {
        VStack(spacing: CentmondTheme.Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28))
                .foregroundStyle(CentmondTheme.Colors.positive)
            Text("All caught up")
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Text("Nothing to review. The detector adds high-confidence patterns automatically.")
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CentmondTheme.Spacing.xxl)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.md)
    }

    // MARK: - Load

    private func load() {
        guard !hasLoaded else { return }
        // Detect returns ALL candidates (including auto-confirmable).
        // Filter to the user-review band so the sheet only shows what
        // the scheduler did NOT already mint silently.
        candidates = RecurringDetector.detect(context: modelContext)
            .filter { $0.confidence < RecurringDetector.effectiveAutoConfirmThreshold }
        hasLoaded = true
    }
}
