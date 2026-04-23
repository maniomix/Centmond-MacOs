import SwiftUI
import SwiftData

/// First-run 6-step overlay.
///
/// Design rule: each step is composed from scratch — no shared header /
/// row template. Steps earn their own layout so the flow feels
/// handmade. Shell chrome (progress, dismiss, navigation) is the only
/// shared surface.
struct OnboardingOverlay: View {
    @Environment(AppRouter.self) private var router
    @State private var store = OnboardingStore()
    @State private var appeared = false

    private let cardWidth: CGFloat = 560
    private let cardHeight: CGFloat = 520

    var body: some View {
        ZStack {
            dim
            card
                .scaleEffect(appeared ? 1 : 0.97)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { appeared = true }
        }
    }

    // MARK: - Dim

    private var dim: some View {
        Rectangle()
            .fill(.black.opacity(0.55))
            .background(.ultraThinMaterial)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { /* swallow */ }
            .opacity(appeared ? 1 : 0)
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            topRail
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            navRow
        }
        .frame(width: cardWidth, height: cardHeight)
        .background {
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                .fill(CentmondTheme.Colors.bgSecondary)
                .overlay {
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.xl, style: .continuous)
                        .strokeBorder(CentmondTheme.Colors.strokeSubtle, lineWidth: 0.5)
                }
                .centmondShadow(4)
        }
    }

    // MARK: - Top rail (progress + skip)

    /// Progress bar moved to the top: full-width, single-pixel height
    /// track + fill sliver. Feels like document progress, not UI chrome.
    private var topRail: some View {
        ZStack(alignment: .topLeading) {
            // Track
            Rectangle()
                .fill(CentmondTheme.Colors.strokeSubtle)
                .frame(height: 1)
            // Fill
            GeometryReader { geo in
                Rectangle()
                    .fill(CentmondTheme.Colors.accent)
                    .frame(width: geo.size.width * progress, height: 1)
                    .animation(.spring(response: 0.55, dampingFraction: 0.85), value: store.currentStep)
            }
            .frame(height: 1)

            HStack {
                Text("\(store.currentStep + 1)")
                    .font(CentmondTheme.Typography.captionSmallSemibold.monospacedDigit())
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                    .contentTransition(.numericText())
                Text("/ \(OnboardingStore.stepCount)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                Spacer()
                Button("Skip") { complete(skipped: true) }
                    .buttonStyle(.plainHover)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
        }
    }

    private var progress: CGFloat {
        CGFloat(store.currentStep + 1) / CGFloat(OnboardingStore.stepCount)
    }

    // MARK: - Step body

    @ViewBuilder
    private var stepBody: some View {
        Group {
            switch store.currentStep {
            case 0: WelcomeStep()
            case 1: DataImportStep(store: store, onAdvance: { advance() })
            case 2: BudgetStep(store: store, onSaved: { advance() })
            case 3: GoalStep(store: store, onAdvance: { advance() })
            case 4: SubscriptionScanStep(
                store: store,
                onAdvance: { advance() },
                onFinishEarly: { skipped in complete(skipped: skipped) }
            )
            case 5:
                if store.step6ShowingShortcuts {
                    ShortcutsCheatsheet()
                } else {
                    MeetAIStep()
                }
            default: EmptyView()
            }
        }
        .id("\(store.currentStep)-\(store.step6ShowingShortcuts)")
        .transition(.opacity)
    }

    // MARK: - Nav row (back + primary, no progress bar here anymore)

    private var navRow: some View {
        HStack(spacing: 12) {
            Button(action: handleBack) {
                Image(systemName: "chevron.left")
                    .font(CentmondTheme.Typography.captionSmallSemibold)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background {
                        Circle().fill(CentmondTheme.Colors.bgTertiary)
                    }
            }
            .buttonStyle(.plainHover)
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)

            Spacer()

            if let secondary = secondaryAction {
                Button(secondary.label, action: secondary.handler)
                    .buttonStyle(.plainHover)
                    .font(CentmondTheme.Typography.captionMedium)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }

            Button(action: primaryAction) {
                Text(primaryLabel)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - CTA policy

    private var canGoBack: Bool {
        if store.currentStep == 5 && store.step6ShowingShortcuts { return true }
        return !store.isFirstStep
    }

    private var primaryLabel: String {
        switch store.currentStep {
        case 0: return "Begin"
        case 1: return "Not now"
        case 2, 3: return "Skip"
        case 4: return "Continue"
        case 5: return store.step6ShowingShortcuts ? "Done" : "Open AI"
        default: return "Next"
        }
    }

    private func primaryAction() {
        switch store.currentStep {
        case 0, 1, 2, 3, 4: advance()
        case 5:
            if store.step6ShowingShortcuts {
                complete(skipped: false)
            } else {
                complete(skipped: false)
                router.navigate(to: .aiChat)
            }
        default: break
        }
    }

    private struct SecondaryAction { let label: String; let handler: () -> Void }

    private var secondaryAction: SecondaryAction? {
        if store.currentStep == 5 && !store.step6ShowingShortcuts {
            return SecondaryAction(label: "Shortcuts") {
                withAnimation(.easeInOut(duration: 0.24)) { store.step6ShowingShortcuts = true }
            }
        }
        return nil
    }

    private func handleBack() {
        if store.currentStep == 5 && store.step6ShowingShortcuts {
            withAnimation(.easeInOut(duration: 0.24)) { store.step6ShowingShortcuts = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.24)) { store.back() }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.24)) { store.advance() }
    }

    private func complete(skipped: Bool) {
        router.completeOnboarding(skipped: skipped, atStep: store.currentStep)
    }
}

// MARK: - Reusable: staggered appear

/// Tiny helper that stages content appearing in order. Each step uses
/// it lightly so hero text lands first, then supporting content, then
/// the call-to-action. Not a component — just a per-step signature.
private struct StaggeredAppear<Content: View>: View {
    let delay: Double
    @ViewBuilder let content: () -> Content
    @State private var appeared = false

    var body: some View {
        content()
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(delay)) {
                    appeared = true
                }
            }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STEP 0 — Welcome
// Wordmark + quiet promises. No box, no chip, no tinted-square icon.
// ═══════════════════════════════════════════════════════════════════════════

private struct WelcomeStep: View {
    @State private var dotPulse: CGFloat = 0.6

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            StaggeredAppear(delay: 0.05) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Centmond")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    // Breathing accent dot — a single detail, not decoration.
                    Circle()
                        .fill(CentmondTheme.Colors.accent)
                        .frame(width: 6, height: 6)
                        .scaleEffect(dotPulse)
                        .opacity(Double(dotPulse))
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                                dotPulse = 1.0
                            }
                        }
                }
            }

            StaggeredAppear(delay: 0.14) {
                Text("A quiet home for your money.")
                    .font(.system(size: 15))
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .padding(.top, 8)
            }

            Spacer()

            StaggeredAppear(delay: 0.22) {
                VStack(alignment: .leading, spacing: 14) {
                    promise("Nothing leaves this Mac.")
                    promise("No telemetry, no account, no cloud.")
                    promise("The AI runs on your chip.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 80)
            }

            Spacer()
        }
        .padding(.vertical, 28)
    }

    private func promise(_ text: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(CentmondTheme.Colors.positive)
                .frame(width: 4, height: 4)
            Text(text)
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STEP 1 — Import
// Two tiles, weighted. Primary = accent-tinted. No sample data path.
// ═══════════════════════════════════════════════════════════════════════════

private struct DataImportStep: View {
    @Bindable var store: OnboardingStore
    let onAdvance: () -> Void

    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [Transaction]
    @State private var baselineCount: Int = 0
    @State private var awaitingSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StaggeredAppear(delay: 0.05) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bring in your data.")
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("Pick one — you can add more later.")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }

            StaggeredAppear(delay: 0.14) {
                HStack(spacing: 14) {
                    importTile(
                        primary: true,
                        icon: "doc.text",
                        heading: "Import CSV",
                        hint: "From a bank export"
                    ) { launchSheet(.importCSV) }

                    importTile(
                        primary: false,
                        icon: "pencil.line",
                        heading: "Add manually",
                        hint: "One by one"
                    ) { launchSheet(.newTransaction) }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .onAppear { baselineCount = transactions.count }
        .onChange(of: router.activeSheet?.id) { _, new in
            guard awaitingSheet, new == nil else { return }
            awaitingSheet = false
            if transactions.count > baselineCount { store.hasImported = true }
            onAdvance()
        }
    }

    private func importTile(primary: Bool, icon: String, heading: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: primary ? 26 : 22, weight: .semibold))
                    .foregroundStyle(primary ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textSecondary)
                Spacer(minLength: 16)
                Text(heading)
                    .font(CentmondTheme.Typography.heading3.weight(.semibold))
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(hint)
                    .font(CentmondTheme.Typography.captionSmall)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                    .fill(
                        primary
                            ? CentmondTheme.Colors.accent.opacity(0.09)
                            : CentmondTheme.Colors.bgTertiary.opacity(0.55)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                            .strokeBorder(
                                primary
                                    ? CentmondTheme.Colors.accent.opacity(0.28)
                                    : CentmondTheme.Colors.strokeSubtle,
                                lineWidth: 0.5
                            )
                    }
            }
        }
        .buttonStyle(.plainHover)
    }

    private func launchSheet(_ sheet: SheetType) {
        awaitingSheet = true
        baselineCount = transactions.count
        router.showSheet(sheet)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STEP 2 — Budget
// The number IS the hero. Oversized input, underline-as-field.
// ═══════════════════════════════════════════════════════════════════════════

private struct BudgetStep: View {
    @Bindable var store: OnboardingStore
    let onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Query private var totalBudgets: [MonthlyTotalBudget]

    @State private var input: String = ""
    @State private var saved: Bool = false
    @FocusState private var focused: Bool

    private var y: Int { Calendar.current.component(.year, from: router.selectedMonth) }
    private var m: Int { Calendar.current.component(.month, from: router.selectedMonth) }
    private var parsed: Decimal? { DecimalInput.parsePositive(input) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            StaggeredAppear(delay: 0.05) {
                VStack(spacing: 6) {
                    Text("Cap your month.")
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("One total for \(monthLabel). Break it out later.")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }

            StaggeredAppear(delay: 0.14) {
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("$")
                            .font(.system(size: 30, weight: .light, design: .rounded))
                            .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        TextField("0", text: $input)
                            .textFieldStyle(.plain)
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 240)
                            .focused($focused)
                            .onSubmit(save)
                    }

                    Rectangle()
                        .fill(focused ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault)
                        .frame(width: 220, height: 1)
                        .animation(.easeInOut(duration: 0.2), value: focused)

                    Text("per month")
                        .font(CentmondTheme.Typography.overline)
                        .foregroundStyle(CentmondTheme.Colors.textQuaternary)
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .padding(.top, 4)
                }
                .padding(.top, 24)
            }

            StaggeredAppear(delay: 0.24) {
                Button(action: save) {
                    HStack(spacing: 6) {
                        if saved {
                            Image(systemName: "checkmark")
                                .font(CentmondTheme.Typography.captionSmallSemibold.weight(.bold))
                        }
                        Text(saved ? "Saved" : "Save")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(parsed == nil || saved)
                .opacity((parsed == nil || saved) ? 0.5 : 1)
                .padding(.top, 24)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true }
        }
    }

    private var monthLabel: String {
        router.selectedMonth.formatted(.dateTime.month(.wide))
    }

    private func save() {
        guard let amount = parsed else { return }
        if let existing = totalBudgets.first(where: { $0.year == y && $0.month == m }) {
            existing.amount = amount
        } else {
            modelContext.insert(MonthlyTotalBudget(year: y, month: m, amount: amount))
        }
        modelContext.persist()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { onSaved() }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STEP 3 — Goal
// Two distinct portrait tiles; custom as a text link beneath.
// ═══════════════════════════════════════════════════════════════════════════

private struct GoalStep: View {
    @Bindable var store: OnboardingStore
    let onAdvance: () -> Void

    @Environment(AppRouter.self) private var router
    @Query private var goals: [Goal]
    @State private var baseline: Int = 0
    @State private var awaitingSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StaggeredAppear(delay: 0.05) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What are you working toward?")
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("Every income suggests how much to put aside.")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }

            StaggeredAppear(delay: 0.14) {
                HStack(spacing: 14) {
                    goalTile(
                        tint: CentmondTheme.Colors.negative,
                        icon: "heart.fill",
                        name: "Emergency fund",
                        caption: "Three months of\nbreathing room."
                    ) { launch(name: "Emergency fund", icon: "heart.fill") }

                    goalTile(
                        tint: CentmondTheme.Colors.accent,
                        icon: "airplane",
                        name: "A trip",
                        caption: "Somewhere you\nactually want to go."
                    ) { launch(name: "Vacation", icon: "airplane") }
                }
            }

            StaggeredAppear(delay: 0.24) {
                Button {
                    launch(name: nil, icon: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(CentmondTheme.Typography.captionSmallSemibold)
                        Text("Name something else")
                            .underline()
                    }
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
                .buttonStyle(.plainHover)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .onAppear { baseline = goals.count }
        .onChange(of: router.activeSheet?.id) { _, new in
            guard awaitingSheet, new == nil else { return }
            awaitingSheet = false
            onAdvance()
        }
    }

    private func goalTile(tint: Color, icon: String, name: String, caption: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint)
                    .opacity(0.95)

                Spacer(minLength: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(CentmondTheme.Typography.heading3.weight(.semibold))
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text(caption)
                        .font(CentmondTheme.Typography.captionSmall)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.14), tint.opacity(0.015)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                            .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
                    }
            }
        }
        .buttonStyle(.plainHover)
    }

    private func launch(name: String?, icon: String?) {
        let d = UserDefaults.standard
        if let name, !name.isEmpty { d.set(name, forKey: "onboarding.goalPreset.name") } else { d.removeObject(forKey: "onboarding.goalPreset.name") }
        if let icon, !icon.isEmpty { d.set(icon, forKey: "onboarding.goalPreset.icon") } else { d.removeObject(forKey: "onboarding.goalPreset.icon") }
        awaitingSheet = true
        baseline = goals.count
        router.showSheet(.newGoal)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STEP 4 — Subscription scan
// Pulse-ring scanner → large gradient number. No chips.
// ═══════════════════════════════════════════════════════════════════════════

private struct SubscriptionScanStep: View {
    @Bindable var store: OnboardingStore
    let onAdvance: () -> Void
    let onFinishEarly: (_ skipped: Bool) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Query private var transactions: [Transaction]

    @State private var isScanning = false
    @State private var didScan = false
    @State private var subCount = 0
    @State private var recCount = 0
    @State private var ringScale: CGFloat = 0.9

    private var totalFound: Int { subCount + recCount }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            scannerOrResult
                .frame(height: 128)

            StaggeredAppear(delay: 0.08) {
                VStack(spacing: 6) {
                    Text(headline)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(subcopy)
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
                .padding(.top, 20)
            }

            StaggeredAppear(delay: 0.18) {
                Group {
                    if didScan && totalFound > 0 {
                        Button("Open the review queue") {
                            onFinishEarly(false)
                            router.navigate(to: .subscriptions)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    } else if !didScan {
                        Button(action: scan) {
                            HStack(spacing: 6) {
                                if isScanning { ProgressView().controlSize(.small).tint(.white) }
                                Text(isScanning ? "Scanning" : "Scan my transactions")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isScanning)
                    }
                }
                .padding(.top, 24)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .onAppear {
            if transactions.isEmpty && !store.hasImported { onAdvance() }
        }
    }

    @ViewBuilder
    private var scannerOrResult: some View {
        if didScan {
            VStack(spacing: 4) {
                Text("\(totalFound)")
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        totalFound > 0
                            ? AnyShapeStyle(LinearGradient(
                                colors: [CentmondTheme.Colors.accent, CentmondTheme.Colors.projected],
                                startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(CentmondTheme.Colors.textSecondary)
                    )
                    .contentTransition(.numericText())
                if totalFound > 0 {
                    Text(legend)
                        .font(CentmondTheme.Typography.overlineSemibold)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                        .textCase(.uppercase)
                        .tracking(1.4)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        } else {
            ZStack {
                Circle()
                    .strokeBorder(CentmondTheme.Colors.accent.opacity(isScanning ? 0.4 : 0.2), lineWidth: 1)
                    .frame(width: 110, height: 110)
                    .scaleEffect(ringScale)
                Circle()
                    .fill(CentmondTheme.Colors.accent.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(CentmondTheme.Colors.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: isScanning)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    ringScale = 1.08
                }
            }
        }
    }

    private var headline: String {
        if !didScan { return "Find recurring charges." }
        return totalFound > 0 ? "Found some patterns." : "Nothing spotted — yet."
    }

    private var subcopy: String {
        if !didScan {
            return "We'll scan your transactions. You review — nothing is created automatically."
        }
        if totalFound > 0 {
            return "Open the queue to confirm which ones belong."
        }
        return "Re-run later once more transactions are in."
    }

    private var legend: String {
        var parts: [String] = []
        if subCount > 0 { parts.append("\(subCount) sub\(subCount == 1 ? "" : "s")") }
        if recCount > 0 { parts.append("\(recCount) recurring") }
        return parts.joined(separator: " · ")
    }

    private func scan() {
        isScanning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            let subs = SubscriptionDetector.detect(context: modelContext)
            let rec = RecurringDetector.detect(context: modelContext)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                subCount = subs.count
                recCount = rec.count
                isScanning = false
                didScan = true
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STEP 5 — Meet the AI
// Two portrait cards with MOOD label + example prompt.
// ═══════════════════════════════════════════════════════════════════════════

private struct MeetAIStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StaggeredAppear(delay: 0.05) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Two voices, on your Mac.")
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("Both run locally. Pick the one that fits the moment.")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }

            StaggeredAppear(delay: 0.14) {
                HStack(spacing: 14) {
                    personaTile(
                        tint: CentmondTheme.Colors.accent,
                        mood: "calm",
                        name: "Chat",
                        line: "Where did my money go last week?"
                    )
                    personaTile(
                        tint: CentmondTheme.Colors.projected,
                        mood: "direct",
                        name: "Predictions",
                        line: "You overspend at 10 PM. Let's fix that."
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func personaTile(tint: Color, mood: String, name: String, line: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(mood)
                .font(CentmondTheme.Typography.overlineSemibold)
                .foregroundStyle(tint)
                .textCase(.uppercase)
                .tracking(1.6)

            Text(name)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
                .padding(.top, 2)

            Spacer(minLength: 20)

            // Quote rendered as copy with a leading accent-tint bar —
            // feels like a pull-quote, not an italicized sentence.
            HStack(spacing: 10) {
                Rectangle()
                    .fill(tint.opacity(0.7))
                    .frame(width: 2)
                Text(line)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: 36)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.16), tint.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.xlTight, style: .continuous)
                        .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
                }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STEP 5 (alt) — Shortcuts
// Pressed-keycap visuals in a clean column.
// ═══════════════════════════════════════════════════════════════════════════

private struct ShortcutsCheatsheet: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let keys: [String]
        let label: String
    }

    private let entries: [Entry] = [
        .init(keys: ["⌘", "K"],   label: "Command palette"),
        .init(keys: ["⌘", "N"],   label: "New transaction"),
        .init(keys: ["⌘", "I"],   label: "Inspector"),
        .init(keys: ["⌘", "1…9"], label: "Jump to a screen"),
        .init(keys: ["Esc"],       label: "Close panels"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StaggeredAppear(delay: 0.05) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Skip the mouse.")
                        .font(CentmondTheme.Typography.heading1)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("A few chords cover the rest of the app.")
                        .font(CentmondTheme.Typography.body)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }
            }

            StaggeredAppear(delay: 0.14) {
                VStack(spacing: 10) {
                    ForEach(entries) { entry in
                        HStack(spacing: 14) {
                            HStack(spacing: 4) {
                                ForEach(entry.keys, id: \.self) { k in keycap(k) }
                            }
                            .frame(width: 104, alignment: .leading)

                            Text(entry.label)
                                .font(CentmondTheme.Typography.body)
                                .foregroundStyle(CentmondTheme.Colors.textSecondary)

                            Spacer()
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(CentmondTheme.Colors.textPrimary)
            .frame(minWidth: label.count > 2 ? 36 : 24, minHeight: 22)
            .padding(.horizontal, label.count > 2 ? 6 : 0)
            .background {
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                    .fill(CentmondTheme.Colors.bgTertiary)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                            .fill(LinearGradient(
                                colors: [.white.opacity(0.06), .clear],
                                startPoint: .top, endPoint: .center
                            ))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                            .strokeBorder(CentmondTheme.Colors.strokeDefault, lineWidth: 0.5)
                    }
                    .centmondShadow(1)
            }
    }
}
