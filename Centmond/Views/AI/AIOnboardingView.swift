import SwiftUI
import SwiftData

// ============================================================
// MARK: - AI Onboarding View
// ============================================================
//
// Step-by-step onboarding UI with conversational prompts,
// structured cards, and a review screen before apply.
//
// Stages: Welcome -> Path Choice -> Financial Profile ->
//         Accounts -> Recurring -> Budget -> Goals ->
//         AI Preferences -> Review -> Apply -> Complete
//
// macOS Centmond: ModelContext, Double amounts (dollars),
// no UIKeyboardType, Color(.controlBackgroundColor).
//
// ============================================================

struct AIOnboardingView: View {
    @Environment(\.modelContext) private var context
    let onComplete: () -> Void

    private let engine = AIOnboardingEngine.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            DS.Colors.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress bar (except welcome/complete)
                if engine.session.currentStage != .welcome &&
                   engine.session.currentStage != .complete {
                    progressBar
                }

                ScrollView {
                    VStack(spacing: 24) {
                        stageContent
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 500)
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        VStack(spacing: 6) {
            HStack {
                if engine.canGoBack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            engine.goBack()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DS.Colors.subtext)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text(engine.session.currentStage.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.subtext)

                Spacer()

                // Step indicator
                Text("\(engine.session.currentStageIndex + 1)/\(engine.session.totalStages)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.subtext.opacity(0.6))
            }
            .padding(.horizontal, 20)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DS.Colors.subtext.opacity(0.15))
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(DS.Colors.accent)
                        .frame(width: geo.size.width * engine.session.progress, height: 3)
                        .animation(.easeInOut(duration: 0.3), value: engine.session.progress)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 20)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Stage Router

    @ViewBuilder
    private var stageContent: some View {
        switch engine.session.currentStage {
        case .welcome:
            welcomeStage
        case .pathChoice:
            pathChoiceStage
        case .financialProfile:
            financialProfileStage
        case .accountsSetup:
            accountsSetupStage
        case .recurringSetup:
            recurringSetupStage
        case .budgetSetup:
            budgetSetupStage
        case .goalsSetup:
            goalsSetupStage
        case .aiPreferences:
            aiPreferencesStage
        case .review:
            reviewStage
        case .applying:
            applyingStage
        case .complete:
            completeStage
        }
    }

    // ======================================================
    // MARK: - Welcome
    // ======================================================

    private var welcomeStage: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 40)

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(DS.Colors.accent)

            VStack(spacing: 8) {
                Text("Welcome to Centmond")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Colors.text)

                Text("Let's set up your finances together.\nI'll guide you through it -- it only takes a minute.")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Colors.subtext)
                    .multilineTextAlignment(.center)
            }

            Spacer().frame(height: 24)

            Button {
                withAnimation { engine.goToStage(.pathChoice) }
            } label: {
                Text("Let's Go")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DS.PrimaryButton())

            Button {
                engine.skipOnboarding()
                onComplete()
            } label: {
                Text("Skip setup -- I'll do it myself")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Colors.subtext)
            }
            .buttonStyle(.plain)
        }
    }

    // ======================================================
    // MARK: - Path Choice
    // ======================================================

    private var pathChoiceStage: some View {
        VStack(spacing: 20) {
            stageHeader(
                icon: "arrow.triangle.branch",
                title: "How would you like to set up?",
                subtitle: "Choose your pace. You can always change things later."
            )

            ForEach([OnboardingPath.quickStart, .guided], id: \.rawValue) { path in
                pathCard(path)
            }
        }
    }

    private func pathCard(_ path: OnboardingPath) -> some View {
        Button {
            withAnimation {
                engine.startSession(path: path)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: path.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(path == .quickStart ? DS.Colors.accent : DS.Colors.positive)
                    .frame(width: 44, height: 44)
                    .background(
                        (path == .quickStart ? DS.Colors.accent : DS.Colors.positive).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(path.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.Colors.text)

                    Text(path.description)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.subtext.opacity(0.5))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
    }

    // ======================================================
    // MARK: - Financial Profile
    // ======================================================

    private var financialProfileStage: some View {
        VStack(spacing: 20) {
            stageHeader(
                icon: "person.text.rectangle.fill",
                title: "Tell me about your finances",
                subtitle: "Just a rough idea -- we'll refine things later."
            )

            // Monthly income (dollars)
            inputCard(
                label: "What's your monthly income?",
                hint: "Approximate is fine",
                icon: "dollarsign.circle.fill",
                value: Binding(
                    get: { engine.session.answers.monthlyIncome.map { String(Int($0)) } ?? "" },
                    set: { engine.session.answers.monthlyIncome = Double($0) }
                )
            )

            nextButton {
                engine.advanceToNextStage()
            }

            skipButton()
        }
    }

    // ======================================================
    // MARK: - Accounts Setup (Guided only)
    // ======================================================

    private var accountsSetupStage: some View {
        VStack(spacing: 20) {
            stageHeader(
                icon: "building.columns.fill",
                title: "What accounts do you have?",
                subtitle: "Tap the ones you use. We'll add them for you."
            )

            accountToggle("Checking Account", isOn: $engine.session.answers.hasCheckingAccount.defaultFalse)
            if engine.session.answers.hasCheckingAccount == true {
                balanceInput("Checking balance",
                             value: $engine.session.answers.checkingBalance)
            }

            accountToggle("Savings Account", isOn: $engine.session.answers.hasSavingsAccount.defaultFalse)
            if engine.session.answers.hasSavingsAccount == true {
                balanceInput("Savings balance",
                             value: $engine.session.answers.savingsBalance)
            }

            accountToggle("Credit Card", isOn: $engine.session.answers.hasCreditCard.defaultFalse)
            if engine.session.answers.hasCreditCard == true {
                balanceInput("Amount owed",
                             value: $engine.session.answers.creditCardBalance)
            }

            nextButton {
                engine.advanceToNextStage()
            }

            skipButton()
        }
    }

    private func accountToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DS.Colors.text)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(DS.Colors.accent)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.controlBackgroundColor))
        )
    }

    private func balanceInput(_ label: String, value: Binding<Double?>) -> some View {
        HStack {
            Text("$")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DS.Colors.subtext)

            TextField(label, text: Binding(
                get: { value.wrappedValue.map { String(Int($0)) } ?? "" },
                set: { value.wrappedValue = Double($0) }
            ))
            .font(.system(size: 15))
            .foregroundStyle(DS.Colors.text)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.controlBackgroundColor).opacity(0.6))
        )
        .padding(.horizontal, 8)
    }

    // ======================================================
    // MARK: - Recurring & Subscriptions (Guided only)
    // ======================================================

    private var recurringSetupStage: some View {
        VStack(spacing: 20) {
            stageHeader(
                icon: "repeat",
                title: "Any recurring bills?",
                subtitle: "Add your regular bills and subscriptions. Click + to add."
            )

            // Quick-add common bills
            let commonBills = ["Rent", "Electric", "Internet", "Phone", "Insurance"]
            let commonSubs = ["Netflix", "Spotify", "YouTube", "iCloud", "Gym"]

            Text("Common bills")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.subtext)
                .frame(maxWidth: .infinity, alignment: .leading)

            FlowLayout(spacing: 8) {
                ForEach(commonBills, id: \.self) { name in
                    quickAddChip(name: name, category: name == "Rent" ? "rent" : "bills", isRecurring: true)
                }
            }

            Text("Common subscriptions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.subtext)
                .frame(maxWidth: .infinity, alignment: .leading)

            FlowLayout(spacing: 8) {
                ForEach(commonSubs, id: \.self) { name in
                    quickAddChip(name: name, category: "bills", isRecurring: false)
                }
            }

            // Show added items
            if !engine.session.answers.recurringBills.isEmpty || !engine.session.answers.subscriptions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Added")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Colors.subtext)

                    ForEach(engine.session.answers.recurringBills) { bill in
                        addedItemRow(name: bill.name, amount: bill.amount, onRemove: {
                            engine.session.answers.recurringBills.removeAll { $0.id == bill.id }
                        })
                    }
                    ForEach(engine.session.answers.subscriptions) { sub in
                        addedItemRow(name: sub.name, amount: sub.amount, onRemove: {
                            engine.session.answers.subscriptions.removeAll { $0.id == sub.id }
                        })
                    }
                }
            }

            nextButton {
                engine.advanceToNextStage()
            }

            skipButton()
        }
    }

    @State private var chipAmountName: String = ""
    @State private var chipAmountValue: String = ""
    @State private var chipAmountCategory: String = "bills"
    @State private var chipIsRecurring: Bool = true
    @State private var showChipAmount: Bool = false

    private func quickAddChip(name: String, category: String, isRecurring: Bool) -> some View {
        let isAdded = isRecurring
            ? engine.session.answers.recurringBills.contains(where: { $0.name == name })
            : engine.session.answers.subscriptions.contains(where: { $0.name == name })

        return Button {
            if isAdded {
                if isRecurring {
                    engine.session.answers.recurringBills.removeAll { $0.name == name }
                } else {
                    engine.session.answers.subscriptions.removeAll { $0.name == name }
                }
            } else {
                chipAmountName = name
                chipAmountCategory = category
                chipIsRecurring = isRecurring
                chipAmountValue = ""
                showChipAmount = true
            }
        } label: {
            HStack(spacing: 4) {
                if isAdded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(name)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isAdded ? .white : DS.Colors.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isAdded ? DS.Colors.accent : Color(.controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
        .alert("How much is \(chipAmountName)?", isPresented: $showChipAmount) {
            TextField("Amount ($)", text: $chipAmountValue)
            Button("Add") {
                let dollars = Double(chipAmountValue) ?? 0
                if dollars > 0 {
                    if chipIsRecurring {
                        engine.session.answers.recurringBills.append(
                            RecurringBillAnswer(name: chipAmountName, amount: dollars, frequency: "monthly", category: chipAmountCategory)
                        )
                    } else {
                        engine.session.answers.subscriptions.append(
                            SubscriptionAnswer(name: chipAmountName, amount: dollars, frequency: "monthly")
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the monthly amount in dollars")
        }
    }

    private func addedItemRow(name: String, amount: Double, onRemove: @escaping () -> Void) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Colors.text)
            Spacer()
            Text(fmtDollars(amount))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.Colors.accent)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(DS.Colors.subtext.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.controlBackgroundColor))
        )
    }

    // ======================================================
    // MARK: - Budget Setup
    // ======================================================

    private var budgetSetupStage: some View {
        VStack(spacing: 20) {
            stageHeader(
                icon: "chart.bar.fill",
                title: "Set your monthly budget",
                subtitle: engine.session.answers.monthlyIncome != nil
                    ? "Based on your income, we suggest \(fmtDollars(suggestedBudget))."
                    : "How much do you want to spend per month?"
            )

            inputCard(
                label: "Monthly budget",
                hint: suggestedBudget > 0 ? "\(Int(suggestedBudget))" : "e.g. 3000",
                icon: "dollarsign.circle.fill",
                value: Binding(
                    get: { engine.session.answers.monthlyBudget.map { String(Int($0)) } ?? "" },
                    set: { engine.session.answers.monthlyBudget = Double($0) }
                )
            )

            if engine.session.answers.monthlyBudget != nil || suggestedBudget > 0 {
                // Use suggested if user hasn't entered custom
                let _ = {
                    if engine.session.answers.monthlyBudget == nil && suggestedBudget > 0 {
                        engine.session.answers.monthlyBudget = suggestedBudget
                    }
                }()

                HStack {
                    Text("Auto-create category budgets?")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.Colors.text)
                    Spacer()
                    Toggle("", isOn: $engine.session.answers.wantAutoBudget.defaultTrue)
                        .labelsHidden()
                        .tint(DS.Colors.accent)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.controlBackgroundColor))
                )
            }

            nextButton {
                // Apply suggested budget if none entered
                if engine.session.answers.monthlyBudget == nil && suggestedBudget > 0 {
                    engine.session.answers.monthlyBudget = suggestedBudget
                }
                engine.advanceToNextStage()
            }

            skipButton()
        }
    }

    private var suggestedBudget: Double {
        guard let income = engine.session.answers.monthlyIncome, income > 0 else { return 0 }
        return income * 0.7
    }

    // ======================================================
    // MARK: - Goals Setup
    // ======================================================

    private var goalsSetupStage: some View {
        VStack(spacing: 20) {
            stageHeader(
                icon: "target",
                title: "Any savings goals?",
                subtitle: "What are you saving for? Even one goal helps."
            )

            // Goal 1
            inputCard(
                label: "Goal name",
                hint: "e.g. Emergency Fund, Vacation",
                icon: "target",
                value: $engine.session.answers.goalName.defaultEmpty
            )

            if !(engine.session.answers.goalName ?? "").isEmpty {
                inputCard(
                    label: "Target amount",
                    hint: "e.g. 5000",
                    icon: "dollarsign.circle.fill",
                    value: Binding(
                        get: { engine.session.answers.goalAmount.map { String(Int($0)) } ?? "" },
                        set: { engine.session.answers.goalAmount = Double($0) }
                    )
                )
            }

            // Optional second goal (guided path)
            if engine.session.path == .guided && !(engine.session.answers.goalName ?? "").isEmpty {
                inputCard(
                    label: "Another goal? (optional)",
                    hint: "e.g. New Laptop",
                    icon: "star.fill",
                    value: $engine.session.answers.secondGoalName.defaultEmpty
                )

                if !(engine.session.answers.secondGoalName ?? "").isEmpty {
                    inputCard(
                        label: "Target amount",
                        hint: "e.g. 1500",
                        icon: "dollarsign.circle.fill",
                        value: Binding(
                            get: { engine.session.answers.secondGoalAmount.map { String(Int($0)) } ?? "" },
                            set: { engine.session.answers.secondGoalAmount = Double($0) }
                        )
                    )
                }
            }

            nextButton {
                engine.advanceToNextStage()
            }

            skipButton()
        }
    }

    // ======================================================
    // MARK: - AI Preferences
    // ======================================================

    private var aiPreferencesStage: some View {
        VStack(spacing: 20) {
            stageHeader(
                icon: "dial.medium.fill",
                title: "How should the AI behave?",
                subtitle: "Choose your comfort level. You can always change this later."
            )

            ForEach(AssistantMode.allCases) { mode in
                modeCard(mode)
            }

            Divider().padding(.vertical, 4)

            HStack {
                Text("Proactive alerts")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.Colors.text)
                Spacer()
                Toggle("", isOn: $engine.session.answers.wantsProactiveAlerts)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.controlBackgroundColor))
            )

            HStack {
                Text("Ask before most actions")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.Colors.text)
                Spacer()
                Toggle("", isOn: $engine.session.answers.prefersMoreConfirmation)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.controlBackgroundColor))
            )

            nextButton {
                engine.generateSetupPlan()
                engine.goToStage(.review)
            }
        }
    }

    private func modeCard(_ mode: AssistantMode) -> some View {
        let isSelected = engine.session.answers.selectedMode == mode

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                engine.session.answers.selectedMode = mode
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? .white : modeColor(mode))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isSelected ? modeColor(mode) : modeColor(mode).opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Colors.text)
                    Text(mode.tagline)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.subtext)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(modeColor(mode))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected
                          ? modeColor(mode).opacity(colorScheme == .dark ? 0.12 : 0.06)
                          : Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? modeColor(mode) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func modeColor(_ mode: AssistantMode) -> Color {
        switch mode {
        case .advisor:   return .blue
        case .assistant:  return DS.Colors.accent
        case .autopilot:  return .orange
        case .cfo:        return .purple
        }
    }

    // ======================================================
    // MARK: - Review
    // ======================================================

    private var reviewStage: some View {
        VStack(spacing: 20) {
            stageHeader(
                icon: "checkmark.shield.fill",
                title: "Review your setup",
                subtitle: "Here's what we'll create. Toggle off anything you don't want."
            )

            // Group items by category
            let grouped = Dictionary(grouping: engine.setupPlan, by: { $0.category })
            let order: [OnboardingSetupItem.SetupCategory] = [
                .account, .budget, .categoryBudget, .recurring, .subscription, .goal, .aiPreference
            ]

            ForEach(order, id: \.rawValue) { cat in
                if let items = grouped[cat], !items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(cat.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Colors.subtext)

                        ForEach(items) { item in
                            reviewItemRow(item)
                        }
                    }
                }
            }

            let includedCount = engine.setupPlan.filter(\.isIncluded).count

            // Apply button
            Button {
                withAnimation {
                    engine.goToStage(.applying)
                }
                Task {
                    await engine.applySetupPlan(context: context)
                }
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Apply Setup (\(includedCount) items)")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DS.PrimaryButton())
            .disabled(includedCount == 0)

            Button {
                engine.goBack()
            } label: {
                Text("Go back and edit")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Colors.subtext)
            }
            .buttonStyle(.plain)
        }
    }

    private func reviewItemRow(_ item: OnboardingSetupItem) -> some View {
        let index = engine.setupPlan.firstIndex(where: { $0.id == item.id })

        return HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 16))
                .foregroundStyle(item.isIncluded ? DS.Colors.accent : DS.Colors.subtext.opacity(0.4))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(item.isIncluded ? DS.Colors.text : DS.Colors.subtext)

                Text(item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.subtext)
            }

            Spacer()

            if let idx = index {
                Toggle("", isOn: $engine.setupPlan[idx].isIncluded)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.controlBackgroundColor))
        )
    }

    // ======================================================
    // MARK: - Applying
    // ======================================================

    private var applyingStage: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 60)

            ProgressView()
                .scaleEffect(1.5)

            Text("Setting up your finances...")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.Colors.text)

            ProgressView(value: engine.applyProgress)
                .progressViewStyle(.linear)
                .tint(DS.Colors.accent)
                .frame(maxWidth: 250)

            Text("\(Int(engine.applyProgress * 100))%")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.Colors.subtext)

            Spacer()
        }
        .onChange(of: engine.session.isComplete) { _, isComplete in
            if isComplete {
                withAnimation(.easeInOut(duration: 0.5)) {
                    // Stage will change to .complete via engine
                }
            }
        }
    }

    // ======================================================
    // MARK: - Complete
    // ======================================================

    private var completeStage: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 40)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(DS.Colors.positive)

            VStack(spacing: 8) {
                Text("You're all set!")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Colors.text)

                Text("Your finances are ready. Here are some things you can do next:")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Colors.subtext)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                nextStepRow(icon: "chart.bar.fill", title: "Review your budget", subtitle: "See how your budget is structured")
                nextStepRow(icon: "plus.circle.fill", title: "Add recent transactions", subtitle: "Start tracking your spending")
                nextStepRow(icon: "text.page.badge.magnifyingglass", title: "Import statement text", subtitle: "Paste bank statement text to bulk-import")
                nextStepRow(icon: "sparkles", title: "Chat with Centmond AI", subtitle: "Ask anything about your finances")
            }

            Spacer().frame(height: 16)

            Button {
                onComplete()
            } label: {
                Text("Start Using Centmond")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DS.PrimaryButton())
        }
    }

    private func nextStepRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Colors.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.subtext)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.controlBackgroundColor))
        )
    }

    // ======================================================
    // MARK: - Shared Components
    // ======================================================

    private func stageHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(DS.Colors.accent)

            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.text)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(DS.Colors.subtext)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 8)
    }

    private func inputCard(
        label: String,
        hint: String,
        icon: String,
        value: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colors.subtext)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(DS.Colors.accent)

                TextField(hint, text: value)
                    .font(.system(size: 16))
                    .foregroundStyle(DS.Colors.text)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.controlBackgroundColor))
            )
        }
    }

    private func nextButton(action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                action()
            }
        } label: {
            Text("Continue")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(DS.PrimaryButton())
    }

    private func skipButton() -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                engine.advanceToNextStage()
            }
        } label: {
            Text("Skip this step")
                .font(.system(size: 14))
                .foregroundStyle(DS.Colors.subtext)
        }
        .buttonStyle(.plain)
    }

    private func fmtDollars(_ value: Double) -> String {
        let isNeg = value < 0
        let str = String(format: "$%.0f", abs(value))
        return isNeg ? "-\(str)" : str
    }
}

// FlowLayout is defined in AISuggestedPrompts.swift -- reused here.

// ======================================================
// MARK: - Binding Helpers
// ======================================================

private extension Binding where Value == Bool? {
    var defaultFalse: Binding<Bool> {
        Binding<Bool>(
            get: { self.wrappedValue ?? false },
            set: { self.wrappedValue = $0 }
        )
    }

    var defaultTrue: Binding<Bool> {
        Binding<Bool>(
            get: { self.wrappedValue ?? true },
            set: { self.wrappedValue = $0 }
        )
    }
}

private extension Binding where Value == String? {
    var defaultEmpty: Binding<String> {
        Binding<String>(
            get: { self.wrappedValue ?? "" },
            set: { self.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
