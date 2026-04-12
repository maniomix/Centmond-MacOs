import SwiftUI
import SwiftData

// ============================================================
// MARK: - AI Ingestion Review View (Phase 5)
// ============================================================
//
// Allows the user to:
//   - paste text (statement rows, receipt, transaction list)
//   - review parsed candidates with confidence/flags
//   - approve or reject individual items
//   - batch-approve safe items
//   - import approved items into the store
//
// macOS Centmond: ModelContext instead of Store, @Observable,
// Double amounts (dollars), no presentation detents,
// macOS toolbar placements, categoryName instead of category enum.
//
// ============================================================

struct AIIngestionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private let engine = AIIngestionEngine.shared

    @State private var inputText: String = ""
    @State private var sourceType: IngestionSourceType = .pastedTransactions
    @State private var showImportResult: Bool = false
    @State private var importResult: IngestionImportResult?

    var body: some View {
        NavigationStack {
            Group {
                if let session = engine.activeSession, session.status != .failed || !session.candidates.isEmpty {
                    reviewContent(session)
                } else {
                    inputContent
                }
            }
            .background(DS.Colors.bg)
            .navigationTitle("Import Data")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if engine.activeSession != nil {
                            engine.dismiss()
                        } else {
                            dismiss()
                        }
                    } label: {
                        if engine.activeSession != nil {
                            Image(systemName: "chevron.left")
                                .foregroundStyle(DS.Colors.accent)
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DS.Colors.subtext)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .alert("Import Complete", isPresented: $showImportResult) {
                Button("Done") {
                    engine.dismiss()
                    dismiss()
                }
            } message: {
                Text(importResult?.summary ?? "")
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // ======================================================
    // MARK: - Input Content
    // ======================================================

    private var inputContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Source type picker
                VStack(alignment: .leading, spacing: 10) {
                    Text("Source Type")
                        .font(DS.Typography.section)
                        .foregroundStyle(DS.Colors.text)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(IngestionSourceType.allCases) { type in
                                Button {
                                    sourceType = type
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: type.icon)
                                            .font(.system(size: 12))
                                        Text(type.title)
                                            .font(DS.Typography.caption)
                                    }
                                    .foregroundStyle(sourceType == type ? .white : DS.Colors.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule().fill(sourceType == type
                                                       ? DS.Colors.accent
                                                       : DS.Colors.accent.opacity(0.1))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
                )

                // Text input
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paste Data")
                        .font(DS.Typography.section)
                        .foregroundStyle(DS.Colors.text)

                    Text(placeholderText)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.subtext)

                    TextEditor(text: $inputText)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 160)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DS.Colors.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(DS.Colors.subtext.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
                )

                // Parse button
                Button {
                    parseInput()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("Parse & Review")
                    }
                    .font(DS.Typography.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  ? DS.Colors.subtext
                                  : DS.Colors.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
    }

    private var placeholderText: String {
        switch sourceType {
        case .pastedStatement:
            return "Paste bank statement rows (CSV, tab-separated, or plain text)"
        case .pastedTransactions:
            return "Paste transaction lines, e.g.:\nStarbucks 5.50 2026-04-08\nUber 18.20 2026-04-08"
        case .receiptText:
            return "Paste receipt text with merchant, items, and total"
        case .genericText:
            return "Paste any text containing transaction data"
        }
    }

    private func parseInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = engine.ingest(rawText: trimmed, sourceType: sourceType, context: context)
    }

    // ======================================================
    // MARK: - Review Content
    // ======================================================

    private func reviewContent(_ session: IngestionSession) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                // Stats bar
                statsBar(session)

                // Parse errors
                if !session.parseErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DS.Colors.danger)
                            Text("Parse Issues")
                                .font(DS.Typography.section)
                                .foregroundStyle(DS.Colors.text)
                        }
                        ForEach(session.parseErrors, id: \.self) { error in
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Colors.subtext)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
                    )
                }

                // Batch actions
                if !session.candidates.isEmpty && session.status == .staged {
                    batchActions(session)
                }

                // Candidate list
                ForEach(session.candidates) { candidate in
                    candidateRow(candidate)
                }

                // Import button
                if session.status == .staged && session.approvedCount > 0 {
                    importButton(session)
                }

                // Completion
                if session.status == .completed {
                    completionCard(session)
                }
            }
            .padding()
        }
    }

    // MARK: Stats Bar

    private func statsBar(_ session: IngestionSession) -> some View {
        HStack(spacing: 0) {
            statPill("\(session.candidates.count)", "Parsed", DS.Colors.accent)
            Spacer()
            statPill("\(session.approvedCount)", "Approved", DS.Colors.positive)
            Spacer()
            statPill("\(session.flaggedCount)", "Flagged", DS.Colors.warning)
            Spacer()
            statPill("\(session.duplicateCount)", "Dupes", DS.Colors.danger)
        }
    }

    private func statPill(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.subtext)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Batch Actions

    private func batchActions(_ session: IngestionSession) -> some View {
        HStack(spacing: 10) {
            let safeCount = session.safeToAutoApprove.count
            if safeCount > 0 {
                Button {
                    engine.autoApproveSafe()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                        Text("Approve \(safeCount) Safe")
                            .font(DS.Typography.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(DS.Colors.positive, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                approveAll()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14))
                    Text("Approve All")
                        .font(DS.Typography.caption)
                }
                .foregroundStyle(DS.Colors.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(DS.Colors.accent.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Candidate Row

    private func candidateRow(_ candidate: CandidateTransaction) -> some View {
        Button {
            engine.toggleApproval(candidate.id)
        } label: {
            HStack(spacing: 10) {
                // Approval checkbox
                Image(systemName: approvalIcon(candidate.approval))
                    .font(.system(size: 20))
                    .foregroundStyle(approvalColor(candidate.approval))

                // Content
                VStack(alignment: .leading, spacing: 3) {
                    // Merchant + amount
                    HStack {
                        Text(candidate.normalizedMerchant)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(DS.Colors.text)
                            .lineLimit(1)

                        Spacer()

                        Text(fmtDollars(candidate.amount))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(candidate.transactionType == .income
                                             ? DS.Colors.positive : DS.Colors.text)
                    }

                    // Date + category
                    HStack(spacing: 6) {
                        Text(fmtDate(candidate.date))
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.subtext)

                        if let catName = candidate.categoryName {
                            Text(catName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(DS.Colors.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(DS.Colors.accent.opacity(0.1), in: Capsule())
                        }

                        Spacer()

                        // Confidence
                        confidenceBadge(candidate.confidence)
                    }

                    // Flags
                    flagsRow(candidate)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(candidateBackground(candidate))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(candidateBorder(candidate), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func flagsRow(_ candidate: CandidateTransaction) -> some View {
        let flags = buildFlags(candidate)
        return Group {
            if !flags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(flags, id: \.text) { flag in
                        HStack(spacing: 2) {
                            Image(systemName: flag.icon)
                                .font(.system(size: 9))
                            Text(flag.text)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(flag.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(flag.color.opacity(0.1), in: Capsule())
                    }
                }
            }
        }
    }

    struct FlagInfo: Hashable {
        let icon: String
        let text: String
        let color: Color

        func hash(into hasher: inout Hasher) {
            hasher.combine(text)
        }

        static func == (lhs: FlagInfo, rhs: FlagInfo) -> Bool {
            lhs.text == rhs.text
        }
    }

    private func buildFlags(_ c: CandidateTransaction) -> [FlagInfo] {
        var flags: [FlagInfo] = []
        if c.isDuplicateSuspect {
            flags.append(FlagInfo(icon: "doc.on.doc", text: "Duplicate", color: DS.Colors.danger))
        }
        if c.isSubscriptionSuspect {
            flags.append(FlagInfo(icon: "repeat", text: "Subscription", color: DS.Colors.accent))
        } else if c.isRecurringSuspect {
            flags.append(FlagInfo(icon: "arrow.clockwise", text: "Recurring", color: DS.Colors.accent))
        }
        if c.isTransferSuspect {
            flags.append(FlagInfo(icon: "arrow.left.arrow.right", text: "Transfer", color: DS.Colors.warning))
        }
        return flags
    }

    // MARK: Import Button

    private func importButton(_ session: IngestionSession) -> some View {
        Button {
            Task {
                let result = await engine.importApproved(context: context)
                importResult = result
                showImportResult = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.fill")
                Text("Import \(session.approvedCount) Transaction(s)")
            }
            .font(DS.Typography.callout)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Completion Card

    private func completionCard(_ session: IngestionSession) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(DS.Colors.positive)
            Text("Import Complete")
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.text)
            Text("\(session.approvedCount) transaction(s) imported")
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.subtext)

            Button {
                engine.dismiss()
                dismiss()
            } label: {
                Text("Done")
                    .font(DS.Typography.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
        )
    }

    // ======================================================
    // MARK: - Helpers
    // ======================================================

    private func approveAll() {
        guard let session = engine.activeSession else { return }
        for c in session.candidates where c.approval == .pending {
            engine.setApproval(c.id, to: .approved)
        }
    }

    private func approvalIcon(_ status: CandidateTransaction.ApprovalStatus) -> String {
        switch status {
        case .pending:  return "circle"
        case .approved: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        }
    }

    private func approvalColor(_ status: CandidateTransaction.ApprovalStatus) -> Color {
        switch status {
        case .pending:  return DS.Colors.subtext.opacity(0.4)
        case .approved: return DS.Colors.positive
        case .rejected: return DS.Colors.danger
        }
    }

    private func confidenceBadge(_ conf: Double) -> some View {
        let pct = Int(conf * 100)
        let color: Color = conf >= 0.75 ? DS.Colors.positive
            : conf >= 0.5 ? DS.Colors.warning
            : DS.Colors.danger

        return Text("\(pct)%")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func candidateBackground(_ c: CandidateTransaction) -> Color {
        switch c.approval {
        case .approved: return DS.Colors.positive.opacity(0.04)
        case .rejected: return DS.Colors.danger.opacity(0.04)
        case .pending:  return DS.Colors.surface
        }
    }

    private func candidateBorder(_ c: CandidateTransaction) -> Color {
        if c.isDuplicateSuspect { return DS.Colors.danger.opacity(0.3) }
        if c.isTransferSuspect { return DS.Colors.warning.opacity(0.3) }
        if c.requiresReview { return DS.Colors.warning.opacity(0.2) }
        return Color.clear
    }

    private func fmtDollars(_ dollars: Double) -> String {
        String(format: "$%.2f", dollars)
    }

    private func fmtDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy"
        return df.string(from: date)
    }
}
