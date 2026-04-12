import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os

// ============================================================
// MARK: - AI Chat View
// ============================================================
//
// Chat interface with the AI assistant.
// Supports streaming responses, action cards, and suggested prompts.
//
// macOS Centmond: ModelContext instead of Store, @Observable,
// synchronous execute, amounts in dollars.
//
// ============================================================

private let logger = Logger(subsystem: "com.centmond", category: "AIChatView")

struct AIChatView: View {
    var isEmbedded: Bool = false

    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var conversation = AIConversation()
    @State private var input: String = ""
    @State private var isStreaming: Bool = false
    @State private var streamingText: String = ""
    @State private var showReceiptScanner: Bool = false

    private let aiManager = AIManager.shared
    private let trustManager = AITrustManager.shared
    private let actionHistory = AIActionHistory.shared
    @State private var showDownloadConfirm = false
    @State private var showModelImporter = false
    @FocusState private var isInputFocused: Bool
    @State private var showAIMenu: Bool = false
    @State private var showActivityDashboard: Bool = false
    @State private var showWorkflow: Bool = false
    @State private var showIngestion: Bool = false
    @State private var showProactiveFeed: Bool = false
    @State private var showMemory: Bool = false
    @State private var showOptimizer: Bool = false
    @State private var showModeSettings: Bool = false
    @State private var showOnboarding: Bool = false

    @State private var pendingTrustContext: PendingTrustContext? = nil

    private var isModelLoading: Bool {
        if case .loading = aiManager.status { return true }
        return false
    }

    private var isModelReady: Bool {
        aiManager.status == .ready || aiManager.status == .generating
    }

    var body: some View {
        NavigationStack {
            messageList
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if !conversation.pendingActions.isEmpty {
                            actionBar
                        }
                        inputBar
                    }
                }
            .background(DS.Colors.bg)
            .toolbar {
                if !isEmbedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DS.Colors.subtext)
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    aiNavigationTitle
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAIMenu = true
                    } label: {
                        Image(systemName: "line.3.horizontal.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(DS.Colors.subtext)
                    }
                }
            }
            .overlay {
                if isModelLoading {
                    modelLoadingOverlay
                }
            }
            .onAppear {
                loadModelIfNeeded()
                if !AIOnboardingEngine.shared.hasCompletedAIOnboarding {
                    showOnboarding = true
                }
            }
            .sheet(isPresented: $showOnboarding) {
                AIOnboardingView()
            }
            .sheet(isPresented: $showReceiptScanner) {
                AIReceiptScannerView()
            }
            .sheet(isPresented: $showAIMenu) {
                aiMenuSheet
            }
            .sheet(isPresented: $showActivityDashboard) {
                AIActivityDashboard()
            }
            .sheet(isPresented: $showWorkflow) {
                AIWorkflowView()
            }
            .sheet(isPresented: $showIngestion) {
                AIIngestionView()
            }
            .sheet(isPresented: $showProactiveFeed) {
                AIProactiveView()
            }
            .sheet(isPresented: $showMemory) {
                AIMemoryView()
            }
            .sheet(isPresented: $showOptimizer) {
                AIOptimizerView()
            }
            .sheet(isPresented: $showModeSettings) {
                AIModeSettingsView()
            }
            .alert("Download AI Model?", isPresented: $showDownloadConfirm) {
                Button("Download (\(AIManager.modelDownloadSizeLabel))", role: .none) {
                    aiManager.downloadModel()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will download the AI model (\(AIManager.modelDownloadSizeLabel)).")
            }
            .fileImporter(
                isPresented: $showModelImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard url.lastPathComponent.hasSuffix(".gguf") else { return }
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    do {
                        try aiManager.importModel(from: url)
                        aiManager.loadModel()
                    } catch {
                        logger.error("Model import failed: \(error.localizedDescription)")
                    }
                case .failure: break
                }
            }
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if conversation.messages.isEmpty && !isStreaming {
                        welcomeCard

                        if isModelReady {
                            AISuggestedPrompts { prompt in
                                sendMessage(prompt)
                            }
                        }
                    }

                    ForEach(conversation.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if isStreaming {
                        streamingBubble
                            .id("streaming")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                if streaming {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Welcome Card

    private var welcomeCard: some View {
        Group {
            if case .downloading(let progress, let bytes) = aiManager.status {
                downloadingCard(progress: progress, downloadedBytes: bytes)
            } else if case .error(let msg) = aiManager.status {
                modelErrorCard(message: msg)
            } else if !aiManager.isModelDownloaded && aiManager.status != .ready {
                modelNotAvailableCard
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(DS.Colors.accent)
                    Text("Centmond AI")
                        .font(DS.Typography.title)
                        .foregroundStyle(DS.Colors.text)
                    Text("Ask me anything about your finances, or tell me to add transactions, set budgets, and more.")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Colors.subtext)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
        }
    }

    private var modelNotAvailableCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 44))
                .foregroundStyle(DS.Colors.accent)

            Text("Setup AI Assistant")
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.text)

            Text("Centmond AI runs entirely on your Mac for maximum privacy. Download or import the language model to get started.")
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.subtext)
                .multilineTextAlignment(.center)

            Button {
                showDownloadConfirm = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18))
                    Text("Download Model (\(AIManager.modelDownloadSizeLabel))")
                        .font(DS.Typography.body)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                showModelImporter = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16))
                    Text("Import from Finder")
                        .font(DS.Typography.body)
                        .fontWeight(.medium)
                }
                .foregroundStyle(DS.Colors.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DS.Colors.accent.opacity(0.3), lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)

            Text("One-time download\nOr drag the .gguf file and tap Import")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.subtext)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private func downloadingCard(progress: Double, downloadedBytes: Int64) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(DS.Colors.surface2, lineWidth: 6)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Colors.text)
                    .contentTransition(.numericText())
            }

            Text("Downloading AI Model…")
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.text)

            Text("\(ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)) / \(AIManager.modelDownloadSizeLabel)")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DS.Colors.subtext)

            ProgressView(value: progress)
                .tint(DS.Colors.accent)
                .padding(.horizontal, 20)

            Button {
                aiManager.cancelDownload()
            } label: {
                Text("Cancel")
                    .font(DS.Typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(DS.Colors.danger)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(DS.Colors.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
    }

    private func modelErrorCard(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(DS.Colors.warning)

            Text("Model Error")
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.text)

            Text(message)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.subtext)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                if aiManager.isModelDownloaded {
                    Button {
                        aiManager.loadModel()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry Loading")
                                .fontWeight(.semibold)
                        }
                        .font(DS.Typography.body)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    aiManager.deleteModel()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Re-download")
                            .fontWeight(.semibold)
                    }
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(DS.Colors.accent, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showModelImporter = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                        Text("Import from Finder")
                            .fontWeight(.medium)
                    }
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.subtext)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
    }

    // MARK: - Message Bubbles

    private func messageBubble(_ message: AIMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                Text(message.content)
                    .font(DS.Typography.body)
                    .foregroundStyle(message.role == .user ? .white : DS.Colors.text)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(message.role == .user
                                  ? DS.Colors.accent
                                  : (colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface))
                    )

                if let actions = message.actions, !actions.isEmpty {
                    let grouped = Self.groupActions(actions)
                    ForEach(grouped, id: \.id) { group in
                        if group.count > 1 {
                            GroupedActionCard(
                                actions: group.actions,
                                onConfirmAll: {
                                    for a in group.actions where a.status == .pending {
                                        confirmAndExecute(a.id)
                                    }
                                },
                                onRejectAll: {
                                    for a in group.actions {
                                        AIMemoryStore.shared.recordApproval(actionType: a.type.rawValue, approved: false)
                                        conversation.rejectAction(a.id)
                                    }
                                }
                            )
                        } else if let action = group.actions.first {
                            AIActionCard(action: action) { id in
                                confirmAndExecute(id)
                            } onReject: { id in
                                if let a = conversation.pendingActions.first(where: { $0.id == id }) {
                                    AIMemoryStore.shared.recordApproval(actionType: a.type.rawValue, approved: false)
                                }
                                conversation.rejectAction(id)
                            }
                        }
                    }
                }
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    private var streamingBubble: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    TypingDotsView()
                    Text(streamingText.isEmpty ? "Thinking…" : streamingText)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Colors.text)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
                )
            }
            Spacer(minLength: 60)
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        let pending = conversation.pendingActions.filter { $0.status == .pending }
        return Group {
            if !pending.isEmpty {
                HStack {
                    Text("\(pending.count) action(s) pending")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.subtext)
                    Spacer()
                    Button("Confirm All (\(pending.count))") {
                        executeAllPending()
                    }
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.accent)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                showReceiptScanner = true
            } label: {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 18))
                    .foregroundStyle(DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .disabled(!isModelReady || isStreaming)

            TextField(isModelReady ? "Ask Centmond AI..." : "Model is loading...",
                      text: $input, axis: .vertical)
                .font(DS.Typography.body)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(colorScheme == .dark ? DS.Colors.surfaceElevated : DS.Colors.surface)
                )
                .disabled(!isModelReady || isStreaming)
                .onSubmit { sendMessage(input) }

            Button {
                sendMessage(input)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(!isModelReady || input.trimmingCharacters(in: .whitespaces).isEmpty || isStreaming
                                    ? DS.Colors.subtext.opacity(0.3)
                                    : DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .disabled(!isModelReady || input.trimmingCharacters(in: .whitespaces).isEmpty || isStreaming)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Model Loading Overlay

    private var modelLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
                    .tint(.white)

                Text("Loading AI Model…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
    }

    // MARK: - Navigation Title with Status

    private var aiNavigationTitle: some View {
        VStack(spacing: 2) {
            Text("Centmond AI")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DS.Colors.text)

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(navStatusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: navStatusColor.opacity(0.6), radius: isModelReady ? 4 : 0)
                        .animation(.easeInOut(duration: 0.5), value: navStatusColor)

                    Text(navStatusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.subtext)
                        .contentTransition(.interpolate)
                }
                .animation(.easeInOut(duration: 0.4), value: navStatusText)

                AIModeIndicator {
                    showModeSettings = true
                }
            }
        }
    }

    private var navStatusColor: Color {
        switch aiManager.status {
        case .ready, .generating: return DS.Colors.positive
        case .loading, .downloading: return DS.Colors.warning
        case .error: return DS.Colors.danger
        case .notLoaded: return DS.Colors.subtext.opacity(0.4)
        }
    }

    private var navStatusText: String {
        switch aiManager.status {
        case .ready: return "Ready"
        case .generating: return "Thinking..."
        case .loading: return "Loading model..."
        case .downloading(let p, _): return "Downloading \(Int(p * 100))%"
        case .error: return "Error"
        case .notLoaded: return aiManager.isModelDownloaded ? "Tap to load" : "No model"
        }
    }

    // MARK: - AI Menu Sheet

    private var aiMenuSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showAIMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showProactiveFeed = true }
                    } label: {
                        Label {
                            HStack {
                                Text("Proactive Feed")
                                if AIProactiveEngine.shared.activeCount > 0 {
                                    Text("\(AIProactiveEngine.shared.activeCount)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(DS.Colors.accent, in: Capsule())
                                }
                            }
                        } icon: { Image(systemName: "bell.badge.fill") }
                    }

                    Button {
                        showAIMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showOptimizer = true }
                    } label: { Label("Optimizer", systemImage: "chart.line.text.clipboard") }

                    Button {
                        showAIMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showWorkflow = true }
                    } label: { Label("Workflows", systemImage: "gearshape.2.fill") }

                    Button {
                        showAIMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showIngestion = true }
                    } label: { Label("Import Data", systemImage: "text.page.badge.magnifyingglass") }

                    Button {
                        showAIMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showActivityDashboard = true }
                    } label: { Label("AI Activity", systemImage: "clock.arrow.circlepath") }

                    Button {
                        showAIMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showMemory = true }
                    } label: {
                        Label {
                            HStack {
                                Text("AI Memory")
                                if AIMemoryStore.shared.totalCount > 0 {
                                    Text("\(AIMemoryStore.shared.totalCount)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(DS.Colors.positive, in: Capsule())
                                }
                            }
                        } icon: { Image(systemName: "brain.head.profile.fill") }
                    }

                    Button {
                        showAIMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showModeSettings = true }
                    } label: {
                        Label {
                            HStack {
                                Text("AI Mode")
                                Text(AIAssistantModeManager.shared.currentMode.title)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(DS.Colors.accent, in: Capsule())
                            }
                        } icon: { Image(systemName: "dial.medium.fill") }
                    }
                }
            }
            .navigationTitle("Centmond AI")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showAIMenu = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 350)
    }

    // MARK: - Actions

    private func loadModelIfNeeded() {
        guard aiManager.status != .ready else { return }
        aiManager.loadModel()
    }

    private func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        conversation.addUserMessage(trimmed)
        input = ""
        isInputFocused = false

        AIUserPreferences.shared.learnFromMessage(trimmed)

        let classification = AIIntentRouter.classify(trimmed)

        let versionManager = AIPromptVersionManager.shared
        versionManager.updateHealth(from: aiManager.status)
        if let fallback = versionManager.fallbackResponse(intentType: classification.intentType) {
            conversation.addAssistantMessage(fallback, actions: nil)
            return
        }

        let modeManager = AIAssistantModeManager.shared

        let clarification = AIClarificationEngine.check(
            classification: classification, rawInput: trimmed
        )

        let auditId = AIAuditLog.shared.beginEntry(
            userMessage: trimmed,
            classification: classification,
            clarification: clarification
        )

        if let shortCircuit = AIIntentRouter.shortCircuitResponse(for: classification) {
            conversation.addAssistantMessage(shortCircuit, actions: nil)
            AIAuditLog.shared.recordResponse(entryId: auditId, responseText: shortCircuit, actions: [])
            return
        }

        let clarificationThreshold = modeManager.currentMode.clarificationThreshold
        if let clarification, classification.confidence < clarificationThreshold {
            conversation.addAssistantMessage(clarification.question, actions: nil)
            AIAuditLog.shared.recordResponse(entryId: auditId, responseText: clarification.question, actions: [])
            versionManager.recordClarification()
            return
        }

        if aiManager.isDownloading {
            conversation.addAssistantMessage("The AI model is still downloading. Please wait.", actions: nil)
            return
        }
        if !aiManager.isModelDownloaded {
            conversation.addAssistantMessage("The AI model needs to be downloaded first. Scroll up and click Download.", actions: nil)
            return
        }
        if case .error(let msg) = aiManager.status {
            conversation.addAssistantMessage("Model error: \(msg). Scroll up to retry or re-download.", actions: nil)
            return
        }

        isStreaming = true
        streamingText = ""

        Task { @MainActor in
            defer {
                isStreaming = false
                streamingText = ""
            }

            let financialContext: String
            switch classification.contextHint {
            case .budgetOnly:
                financialContext = AIContextBuilder.buildBudgetOnly(context: context)
            case .transactionsOnly:
                financialContext = AIContextBuilder.buildTransactionsOnly(context: context)
            case .goalsOnly:
                financialContext = AIContextBuilder.buildGoalsOnly(context: context)
            case .subscriptionsOnly:
                financialContext = AIContextBuilder.buildSubscriptionsOnly(context: context)
            case .accountsOnly:
                financialContext = AIContextBuilder.build(context: context)
            case .minimal, .none:
                financialContext = ""
            case .full:
                financialContext = AIContextBuilder.build(context: context)
            }

            var systemPrompt = AISystemPrompt.build(context: financialContext.isEmpty ? nil : financialContext)

            let merchantContext = AIMerchantMemory.shared.contextSummary()
            if !merchantContext.isEmpty {
                systemPrompt += "\n\n" + merchantContext
            }

            if classification.contextHint == .full || classification.contextHint == .budgetOnly {
                let sts = AISafeToSpend.shared.calculate(context: context)
                systemPrompt += "\n\nSAFE-TO-SPEND\n=============\n\(sts.summary())"
            }

            let recurringContext = AIRecurringDetector.shared.summary(context: context)
            if !recurringContext.isEmpty {
                systemPrompt += "\n\n" + recurringContext
            }

            if let clarification {
                let hint = clarification.missingFields.joined(separator: ", ")
                systemPrompt += "\n\nCLARIFICATION HINT: The user's message may be ambiguous. Missing: \(hint). Ask a short clarifying question if needed."
            }

            let historyCount = classification.contextHint == .full ? 10 : 6
            let history = conversation.messages.suffix(historyCount).map { msg -> AIMessage in
                if msg.role == .assistant {
                    let textOnly: String
                    if let range = msg.content.range(of: "---ACTIONS---") {
                        textOnly = String(msg.content[msg.content.startIndex..<range.lowerBound])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        textOnly = msg.content
                    }
                    return AIMessage(role: .assistant, content: textOnly)
                }
                return msg
            }

            var fullResponse = ""

            for await token in aiManager.stream(messages: history, systemPrompt: systemPrompt) {
                fullResponse += token
                let display: String
                if let range = fullResponse.range(of: "---ACTIONS---") {
                    display = String(fullResponse[fullResponse.startIndex..<range.lowerBound])
                } else {
                    display = fullResponse
                }
                streamingText = Self.cleanModelResponse(display, userMessage: trimmed)
            }

            fullResponse = Self.cleanModelResponse(fullResponse, userMessage: trimmed)

            if fullResponse.isEmpty {
                fullResponse = "Sorry, something went wrong. Please try again."
            }

            let parsed = AIActionParser.parse(fullResponse)

            if parsed.actions.isEmpty && parsed.text.contains("---ACTIONS---") == false {
                versionManager.recordParseFailure()
            } else {
                versionManager.recordSuccess(responseLength: fullResponse.count)
            }

            AIAuditLog.shared.recordResponse(entryId: auditId, responseText: parsed.text, actions: parsed.actions)

            if let failure = AIClarificationEngine.validateActions(parsed.actions) {
                let errorMsg = failure.userMessage
                conversation.addAssistantMessage(errorMsg, actions: nil)
                AIAuditLog.shared.recordError(entryId: auditId, error: errorMsg)
                return
            }

            var finalActions = Self.applyMultiplier(parsed.actions, userMessage: trimmed)

            if !finalActions.isEmpty {
                let conflicts = AIConflictDetector.detect(actions: finalActions, context: context)

                if conflicts.isBlocked {
                    for block in conflicts.blocks {
                        if let idx = block.actionIndex, idx < finalActions.count {
                            finalActions[idx].status = .rejected
                        }
                    }
                }

                if !conflicts.warnings.isEmpty {
                    // Warnings are included via the conflict result
                }
            }

            if !finalActions.isEmpty {
                let analysisTypes: Set<AIAction.ActionType> = [.analyze, .compare, .forecast, .advice]

                for i in finalActions.indices {
                    if analysisTypes.contains(finalActions[i].type) {
                        finalActions[i].status = .executed
                    }
                }

                let mutationActions = finalActions.filter { !analysisTypes.contains($0.type) }

                if !mutationActions.isEmpty {
                    let classified = trustManager.classify(
                        mutationActions,
                        classification: classification,
                        mode: modeManager.currentMode
                    )

                    let groupId = mutationActions.count > 1 ? UUID() : nil
                    let groupLabel = mutationActions.count > 1 ? String(trimmed.prefix(60)) : nil

                    var blockMessages: [String] = []
                    for (action, decision) in classified.blocked {
                        if let idx = finalActions.firstIndex(where: { $0.id == decision.id }) {
                            finalActions[idx].status = .rejected
                        }
                        if let msg = decision.blockMessage {
                            blockMessages.append(msg)
                        }
                        actionHistory.recordBlocked(
                            action: action,
                            trustDecision: decision,
                            classification: classification,
                            groupId: groupId,
                            groupLabel: groupLabel
                        )
                    }

                    var displayText = Self.buildActionSummary(mutationActions) ?? parsed.text
                    if !blockMessages.isEmpty {
                        displayText += "\n\n" + blockMessages.joined(separator: "\n")
                    }
                    conversation.addAssistantMessage(displayText, actions: finalActions)

                    let trustDecisions = classified.allDecisions.map { decision in
                        AuditTrustDecision(
                            actionType: decision.actionType.rawValue,
                            trustLevel: decision.level.rawValue,
                            riskScore: decision.riskScore.value,
                            riskLevel: decision.riskScore.level.rawValue,
                            reason: decision.reason,
                            confidenceUsed: decision.confidenceUsed,
                            preferenceInfluenced: decision.preferenceInfluenced,
                            userDecision: nil
                        )
                    }
                    AIAuditLog.shared.recordTrustDecisions(entryId: auditId, decisions: trustDecisions)

                    let decisionsByActionId: [UUID: TrustDecision] = {
                        var map: [UUID: TrustDecision] = [:]
                        for (action, decision) in classified.auto { map[action.id] = decision }
                        for (action, decision) in classified.confirm { map[action.id] = decision }
                        return map
                    }()

                    self.pendingTrustContext = PendingTrustContext(
                        decisionsByActionId: decisionsByActionId,
                        classification: classification,
                        groupId: groupId,
                        groupLabel: groupLabel
                    )

                    // Auto-execute trusted actions (synchronous on macOS)
                    if !classified.auto.isEmpty {
                        var execResults: [AuditExecutionResult] = []
                        for (action, decision) in classified.auto {
                            conversation.confirmAction(action.id)
                            let result = AIActionExecutor.execute(action, context: context)
                            execResults.append(AuditExecutionResult(
                                actionType: action.type.rawValue,
                                success: result.success,
                                summary: result.summary,
                                undoable: AIConflictDetector.isReversible(action.type)
                            ))
                            if result.success {
                                if let idx = conversation.pendingActions.firstIndex(where: { $0.id == action.id }) {
                                    conversation.pendingActions[idx].status = .executed
                                }
                                actionHistory.record(
                                    action: action,
                                    result: result,
                                    trustDecision: decision,
                                    classification: classification,
                                    groupId: groupId,
                                    groupLabel: groupLabel,
                                    isAutoExecuted: true
                                )
                                if action.type == .addTransaction {
                                    AIEventBus.shared.postTransactionAdded(
                                        amount: action.params.amount ?? 0,
                                        category: action.params.category ?? "other",
                                        note: action.params.note ?? "",
                                        type: action.params.transactionType ?? "expense"
                                    )
                                }
                                if action.type == .addTransaction,
                                   let note = action.params.note, !note.isEmpty {
                                    AIMerchantMemory.shared.learnFromTransaction(
                                        note: note,
                                        category: action.params.category ?? "other",
                                        amount: action.params.amount ?? 0
                                    )
                                }
                            }
                        }
                        try? context.save()
                        AIAuditLog.shared.recordExecution(entryId: auditId, results: execResults)
                    }
                } else {
                    conversation.addAssistantMessage(parsed.text, actions: finalActions)
                }
            } else {
                conversation.addAssistantMessage(parsed.text, actions: nil)
            }
        }
    }

    private func confirmAndExecute(_ id: UUID) {
        guard let action = conversation.pendingActions.first(where: { $0.id == id && $0.status == .pending }) else { return }

        conversation.confirmAction(id)
        AIMemoryStore.shared.recordApproval(actionType: action.type.rawValue, approved: true)

        let result = AIActionExecutor.execute(action, context: context)

        if result.success {
            try? context.save()
            conversation.markExecuted(id)

            let ctx = pendingTrustContext
            actionHistory.record(
                action: action,
                result: result,
                trustDecision: ctx?.decisionsByActionId[action.id],
                classification: ctx?.classification,
                groupId: ctx?.groupId,
                groupLabel: ctx?.groupLabel,
                isAutoExecuted: false
            )

            conversation.addAssistantMessage("Done: \(result.summary)", actions: nil)

            if action.type == .addTransaction {
                AIEventBus.shared.postTransactionAdded(
                    amount: action.params.amount ?? 0,
                    category: action.params.category ?? "other",
                    note: action.params.note ?? "",
                    type: action.params.transactionType ?? "expense"
                )
            }
            if action.type == .addTransaction,
               let note = action.params.note, !note.isEmpty {
                AIMerchantMemory.shared.learnFromTransaction(
                    note: note,
                    category: action.params.category ?? "other",
                    amount: action.params.amount ?? 0
                )
            }
        } else {
            conversation.addAssistantMessage("Failed: \(result.summary)", actions: nil)
        }
    }

    private func executeAllPending() {
        let pending = conversation.pendingActions.filter { $0.status == .pending }
        guard !pending.isEmpty else { return }
        conversation.confirmAll()

        let ctx = pendingTrustContext
        let results = AIActionExecutor.executeAll(pending, context: context)
        try? context.save()

        var summaries: [String] = []
        for result in results where result.success {
            conversation.markExecuted(result.action.id)
            actionHistory.record(
                action: result.action,
                result: result,
                trustDecision: ctx?.decisionsByActionId[result.action.id],
                classification: ctx?.classification,
                groupId: ctx?.groupId,
                groupLabel: ctx?.groupLabel,
                isAutoExecuted: false
            )
            summaries.append("Done: \(result.summary)")
        }
        if !summaries.isEmpty {
            conversation.addAssistantMessage(summaries.joined(separator: "\n"), actions: nil)
        }
    }

    // MARK: - Pending Trust Context

    struct PendingTrustContext {
        let decisionsByActionId: [UUID: TrustDecision]
        let classification: IntentClassification?
        let groupId: UUID?
        let groupLabel: String?
    }

    // MARK: - Action Grouping

    struct ActionGroup: Identifiable {
        let id: String
        let actions: [AIAction]
        var count: Int { actions.count }
    }

    static func groupActions(_ actions: [AIAction]) -> [ActionGroup] {
        var groups: [(key: String, actions: [AIAction])] = []

        for action in actions {
            let key = "\(action.type.rawValue)|\(action.params.amount ?? 0)|\(action.params.category ?? "")|\(action.params.budgetAmount ?? 0)"
            if let idx = groups.firstIndex(where: { $0.key == key }) {
                groups[idx].actions.append(action)
            } else {
                groups.append((key: key, actions: [action]))
            }
        }

        return groups.map { ActionGroup(id: $0.key, actions: $0.actions) }
    }

    private static func applyMultiplier(_ actions: [AIAction], userMessage: String) -> [AIAction] {
        let msg = normalizePersianDigits(userMessage.lowercased())

        let count = extractCount(from: msg)
        guard let n = count, n > 1 else { return actions }

        let dates = extractDateRange(from: msg, count: n)

        if actions.count == 1, let template = actions.first, template.type == .addTransaction {
            return (0..<n).map { i in
                var params = template.params
                if i < dates.count { params.date = dates[i] }
                return AIAction(type: template.type, params: params)
            }
        }

        if actions.count == n, let firstDate = actions.first?.params.date,
           actions.allSatisfy({ $0.params.date == firstDate }), !dates.isEmpty {
            return actions.enumerated().map { i, action in
                var params = action.params
                if i < dates.count { params.date = dates[i] }
                return AIAction(type: action.type, params: params)
            }
        }

        if actions.isEmpty {
            if let amt = extractAmount(from: msg) {
                return (0..<n).map { i in
                    let params = AIAction.ActionParams(
                        amount: amt,
                        category: "other",
                        date: i < dates.count ? dates[i] : "today",
                        transactionType: "expense"
                    )
                    return AIAction(type: .addTransaction, params: params)
                }
            }
        }

        return actions
    }

    // MARK: - Multiplier Helpers

    private static func normalizePersianDigits(_ text: String) -> String {
        text.replacingOccurrences(of: "۰", with: "0")
            .replacingOccurrences(of: "۱", with: "1")
            .replacingOccurrences(of: "۲", with: "2")
            .replacingOccurrences(of: "۳", with: "3")
            .replacingOccurrences(of: "۴", with: "4")
            .replacingOccurrences(of: "۵", with: "5")
            .replacingOccurrences(of: "۶", with: "6")
            .replacingOccurrences(of: "۷", with: "7")
            .replacingOccurrences(of: "۸", with: "8")
            .replacingOccurrences(of: "۹", with: "9")
    }

    private static func extractCount(from msg: String) -> Int? {
        let patterns: [String] = [
            #"(\d+)\s*[x×]\s*(?:expense|expence|transaction|payment|item)"#,
            #"(\d+)\s*(?:expense|expence|transaction|payment|item)"#,
            #"(?:add|create)\s+(\d+)\s*(?:expense|expence|transaction|payment|item)"#,
            #"(\d+)\s*(?:تا|عدد|دونه|بار)"#,
        ]
        for pattern in patterns {
            if let n = firstCaptureInt(pattern: pattern, in: msg), n > 1, n <= 50 {
                return n
            }
        }
        return nil
    }

    private static func extractAmount(from msg: String) -> Double? {
        let patterns: [String] = [
            #"[\$€£¥₹]\s*(\d+(?:\.\d+)?)"#,
            #"(\d+(?:\.\d+)?)\s*[\$€£¥₹]"#,
            #"(\d+(?:\.\d+)?)\s*(?:dollar|euro|pound)"#,
            #"هر\s*(?:کدوم|کدام)?\s*(\d+)"#,
            #"each\s+(?:for\s+)?[\$€£¥₹]?\s*(\d+)"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)) {
                for i in 1..<match.numberOfRanges {
                    if let range = Range(match.range(at: i), in: msg),
                       let a = Double(String(msg[range])), a > 0 {
                        return a
                    }
                }
            }
        }
        return nil
    }

    private static func extractDateRange(from msg: String, count: Int) -> [String] {
        let monthMap: [String: Int] = [
            "jan": 1, "january": 1, "feb": 2, "february": 2,
            "mar": 3, "march": 3, "apr": 4, "april": 4,
            "may": 5, "jun": 6, "june": 6,
            "jul": 7, "july": 7, "aug": 8, "august": 8,
            "sep": 9, "september": 9, "oct": 10, "october": 10,
            "nov": 11, "november": 11, "dec": 12, "december": 12,
            "فروردین": 1, "اردیبهشت": 2, "خرداد": 3,
            "تیر": 4, "مرداد": 5, "شهریور": 6,
            "مهر": 7, "آبان": 8, "آذر": 9,
            "دی": 10, "بهمن": 11, "اسفند": 12,
        ]

        let rangePatterns: [String] = [
            #"from\s+(\d{1,2})[\.\s]*([a-z]+)\s+to\s+(\d{1,2})[\.\s]*([a-z]+)"#,
            #"از\s+(\d{1,2})\s*([^\s]+)\s+تا\s+(\d{1,2})\s*([^\s]+)"#,
        ]

        for pattern in rangePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)) {
                guard match.numberOfRanges >= 5,
                      let r1 = Range(match.range(at: 1), in: msg),
                      let r2 = Range(match.range(at: 2), in: msg),
                      let r3 = Range(match.range(at: 3), in: msg),
                      let r4 = Range(match.range(at: 4), in: msg),
                      let startDay = Int(String(msg[r1])),
                      let endDay = Int(String(msg[r3])) else { continue }

                let startMonthStr = String(msg[r2]).lowercased().trimmingCharacters(in: .punctuationCharacters)
                let endMonthStr = String(msg[r4]).lowercased().trimmingCharacters(in: .punctuationCharacters)

                guard let startMonth = monthMap[startMonthStr],
                      let endMonth = monthMap[endMonthStr] else { continue }

                let year = Calendar.current.component(.year, from: Date())
                return generateDateList(startDay: startDay, startMonth: startMonth,
                                        endDay: endDay, endMonth: endMonth,
                                        year: year, maxCount: count)
            }
        }

        let startPatterns: [String] = [
            #"(?:starting\s+)?from\s+(\d{1,2})[\.\s]*([a-z]+)"#,
            #"از\s+(\d{1,2})\s*([^\s]+)"#,
        ]

        for pattern in startPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)) {
                guard match.numberOfRanges >= 3,
                      let r1 = Range(match.range(at: 1), in: msg),
                      let r2 = Range(match.range(at: 2), in: msg),
                      let startDay = Int(String(msg[r1])) else { continue }

                let monthStr = String(msg[r2]).lowercased().trimmingCharacters(in: .punctuationCharacters)
                guard let month = monthMap[monthStr] else { continue }

                let year = Calendar.current.component(.year, from: Date())
                return generateConsecutiveDates(startDay: startDay, month: month, year: year, count: count)
            }
        }

        return []
    }

    private static func generateDateList(startDay: Int, startMonth: Int, endDay: Int, endMonth: Int, year: Int, maxCount: Int) -> [String] {
        let cal = Calendar.current
        guard let startDate = cal.date(from: DateComponents(year: year, month: startMonth, day: startDay)),
              let endDate = cal.date(from: DateComponents(year: year, month: endMonth, day: endDay)),
              endDate >= startDate else { return [] }

        var dates: [String] = []
        var current = startDate
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        while current <= endDate && dates.count < maxCount {
            dates.append(formatter.string(from: current))
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return dates
    }

    private static func generateConsecutiveDates(startDay: Int, month: Int, year: Int, count: Int) -> [String] {
        let cal = Calendar.current
        guard let startDate = cal.date(from: DateComponents(year: year, month: month, day: startDay)) else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        return (0..<count).compactMap { i in
            guard let date = cal.date(byAdding: .day, value: i, to: startDate) else { return nil }
            return formatter.string(from: date)
        }
    }

    private static func firstCaptureInt(pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for i in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: i), in: text), let n = Int(String(text[range])) {
                return n
            }
        }
        return nil
    }

    static func cleanModelResponse(_ raw: String, userMessage: String) -> String {
        var text = raw
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "<start_of_turn>model", with: "")
            .replacingOccurrences(of: "<start_of_turn>user", with: "")
            .replacingOccurrences(of: "<start_of_turn>system", with: "")
            .replacingOccurrences(of: "<start_of_turn>", with: "")

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerText = trimmedText.lowercased()
        let lowerUser = userMessage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !lowerUser.isEmpty && lowerText.hasPrefix(lowerUser) {
            text = String(trimmedText.dropFirst(userMessage.trimmingCharacters(in: .whitespacesAndNewlines).count))
        }

        let lines = text.components(separatedBy: .newlines)
        let filtered = lines.filter { line in
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped == "-" || stripped == "–" || stripped == "—" || stripped == "•" || stripped == "*" {
                return false
            }
            if stripped.count >= 2 {
                let unique = Set(stripped)
                if unique.count == 1 && ["=", "-", "*", "─", "━", "·"].contains(stripped.first!) {
                    return false
                }
            }
            return true
        }
        text = filtered.joined(separator: "\n")

        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildActionSummary(_ actions: [AIAction]) -> String? {
        guard !actions.isEmpty else { return nil }

        let groups = groupActions(actions)
        let lines: [String] = groups.compactMap { group in
            let action = group.actions[0]
            let count = group.count
            let p = action.params
            switch action.type {
            case .addTransaction:
                let type = p.transactionType == "income" ? "income" : "expense"
                let amt = fmtDollarsStatic(p.amount)
                if count > 1 {
                    let total = fmtDollarsStatic((p.amount ?? 0) * Double(count))
                    var s = "I'll add \(count)x \(amt) \(type) (total: \(total))"
                    if let cat = p.category { s += " in \(cat)" }
                    return s + "."
                }
                var s = "I'll add a \(amt) \(type)"
                if let cat = p.category { s += " in \(cat)" }
                if let note = p.note { s += " (\(note))" }
                if let date = p.date, date != "today" { s += " on \(date)" }
                return s + "."
            case .editTransaction: return "I'll update that transaction for you."
            case .deleteTransaction: return "I'll delete that transaction."
            case .splitTransaction:
                let amt = fmtDollarsStatic(p.amount)
                return "I'll split \(amt) with \(p.splitWith ?? "your partner")."
            case .setBudget, .adjustBudget:
                let amt = fmtDollarsStatic(p.budgetAmount)
                var s = "I'll set your monthly budget to \(amt)"
                if let m = p.budgetMonth { s += " for \(m)" }
                return s + "."
            case .setCategoryBudget:
                let amt = fmtDollarsStatic(p.budgetAmount)
                return "I'll set the \(p.budgetCategory ?? "category") budget to \(amt)."
            case .createGoal:
                let target = fmtDollarsStatic(p.goalTarget)
                return "I'll create a goal \"\(p.goalName ?? "Goal")\" with target \(target)."
            case .addContribution:
                let amt = fmtDollarsStatic(p.contributionAmount)
                return "I'll add \(amt) to \"\(p.goalName ?? "goal")\"."
            case .updateGoal: return "I'll update the goal \"\(p.goalName ?? "Goal")\"."
            case .addSubscription:
                let amt = fmtDollarsStatic(p.subscriptionAmount)
                return "I'll add subscription \"\(p.subscriptionName ?? "")\" at \(amt)."
            case .cancelSubscription: return "I'll cancel the subscription \"\(p.subscriptionName ?? "")\"."
            case .transfer:
                let amt = fmtDollarsStatic(p.amount)
                return "I'll transfer \(amt) from \(p.fromAccount ?? "?") to \(p.toAccount ?? "?")."
            case .addRecurring:
                let amt = fmtDollarsStatic(p.amount)
                return "I'll add recurring \"\(p.recurringName ?? "")\" at \(amt)/\(p.recurringFrequency ?? "month")."
            case .editRecurring: return "I'll update recurring \"\(p.recurringName ?? p.subscriptionName ?? "")\"."
            case .cancelRecurring: return "I'll cancel recurring \"\(p.recurringName ?? p.subscriptionName ?? "")\"."
            case .updateBalance: return "I'll update \(p.accountName ?? "account") balance."
            case .analyze, .compare, .forecast, .advice: return nil
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func fmtDollarsStatic(_ dollars: Double?) -> String {
        guard let dollars else { return "$0.00" }
        return String(format: "$%.2f", dollars)
    }
}
