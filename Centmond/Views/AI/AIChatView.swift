import SwiftUI
import SwiftData
import MarkdownUI
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
    @State private var currentSession: ChatSession?
    @State private var input: String = ""
    @State private var isStreaming: Bool = false
    @State private var streamingSessionId: UUID? = nil  // Which session owns the active stream
    @State private var streamingText: String = ""
    @State private var streamingInsights: [FinancialInsight]? = nil
    @State private var streamingPhase: StreamingPhase = .thinking
    @State private var showReceiptScanner: Bool = false
    @State private var cursorVisible: Bool = false
    @State private var glowPhase: Bool = false

    private let aiManager = AIManager.shared
    private let trustManager = AITrustManager.shared
    private let actionHistory = AIActionHistory.shared
    @State private var showDownloadConfirm = false
    @State private var showModelPicker = false
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
    @State private var chatSessions: [ChatSession] = []
    @State private var isChatSidebarVisible: Bool = true
    @State private var renamingSession: ChatSession? = nil
    @State private var renameText: String = ""

    private var isModelLoading: Bool {
        if case .loading = aiManager.status { return true }
        return false
    }

    private var isModelReady: Bool {
        aiManager.status == .ready || aiManager.status == .generating
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Chat History Sidebar
            if isChatSidebarVisible {
                chatHistorySidebar
                    .frame(width: 220)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // MARK: - Main Chat Area
            NavigationStack {
                messageList
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            if !conversation.pendingActions.isEmpty {
                                actionBar
                            }
                            if isModelReady && !isStreaming && !conversation.messages.isEmpty {
                                suggestionsStrip
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
                            isChatSidebarVisible.toggle()
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 15))
                                .foregroundStyle(isChatSidebarVisible ? DS.Colors.accent : DS.Colors.subtext)
                        }
                        .help("Toggle Chat History")
                    }
                    ToolbarItem(placement: .automatic) {
                        AIModeIndicator {
                            showModeSettings = true
                        }
                        .padding(.leading, 10)
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            startNewChat()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 16))
                                .foregroundStyle(DS.Colors.subtext)
                        }
                        .help("New Chat")
                        .disabled(conversation.messages.isEmpty || isStreaming)
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showAIMenu = true
                        } label: {
                            Image(systemName: "line.3.horizontal.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(DS.Colors.subtext)
                        }
                        .padding(.trailing, 4)
                    }
                }
                .overlay {
                    if isModelLoading {
                        modelLoadingOverlay
                    }
                }
                .onAppear {
                    loadModelIfNeeded()
                    loadChatHistory()
                    if !AIOnboardingEngine.shared.hasCompletedAIOnboarding {
                        showOnboarding = true
                    }
                }
                .onDisappear {
                    // User navigated away from chat — schedule a fast unload
                    // so Gemma's ~5 GB residency doesn't sit around. Cancelled
                    // automatically by `cancelIdleUnload` if they come back
                    // and start a new message before the timer fires.
                    aiManager.requestUnloadSoon()
                }
            .sheet(isPresented: $showOnboarding) {
                AIOnboardingView { showOnboarding = false }
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
            .sheet(isPresented: $showModelPicker) {
                AIModelPickerSheet()
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
        } // NavigationStack
        } // HStack
        .animation(.easeInOut(duration: 0.25), value: isChatSidebarVisible)
    }

    // MARK: - Chat History Sidebar

    private var chatHistorySidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Chat History")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.subtext)
                Spacer()
                Button {
                    startNewChat()
                    refreshSessions()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(isStreaming ? DS.Colors.subtext : DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .help("New Chat")
                .disabled(isStreaming)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.3)

            // Session list
            if chatSessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 28))
                        .foregroundStyle(DS.Colors.subtext.opacity(0.4))
                    Text("No conversations yet")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.subtext.opacity(0.5))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(chatSessions, id: \.id) { session in
                            chatSessionRow(session)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(DS.Colors.bg.opacity(0.6))
    }

    private func chatSessionRow(_ session: ChatSession) -> some View {
        let isSelected = currentSession?.id == session.id
        let isRenaming = renamingSession?.id == session.id
        let isSessionStreaming = isStreaming && streamingSessionId == session.id

        return Button {
            if !isRenaming {
                switchToSession(session)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    HStack(spacing: 4) {
                        TextField("Chat name", text: $renameText)
                            .font(.system(size: 12))
                            .textFieldStyle(.plain)
                            .onSubmit {
                                commitRename(session)
                            }

                        Button {
                            commitRename(session)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(DS.Colors.accent)
                        }
                        .buttonStyle(.plain)

                        Button {
                            renamingSession = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(DS.Colors.subtext)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text(session.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.text)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    Text(relativeDate(session.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.subtext.opacity(0.6))

                    Text("\(session.messages.count) messages")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.subtext.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? DS.Colors.accent.opacity(0.12) : Color.clear)
            )
            .overlay {
                if isSessionStreaming {
                    ShimmerOverlay()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .contextMenu {
            Button {
                renameText = session.title
                renamingSession = session
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button(role: .destructive) {
                deleteSession(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .opacity(isStreaming && !isSessionStreaming ? 0.45 : 1)
    }

    private func commitRename(_ session: ChatSession) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            session.title = trimmed
            try? context.save()
        }
        renamingSession = nil
        refreshSessions()
    }

    private func switchToSession(_ session: ChatSession) {
        guard session.id != currentSession?.id else { return }
        // Block switching while AI is generating — prevents state corruption
        guard !isStreaming else { return }

        currentSession = session
        conversation = ChatPersistenceManager.shared.loadConversation(from: session)
    }

    private func deleteSession(_ session: ChatSession) {
        ChatPersistenceManager.shared.deleteSession(session, context: context)
        if session.id == currentSession?.id {
            // Switch to the latest remaining session or create new
            let remaining = ChatPersistenceManager.shared.fetchSessions(context: context)
            if let first = remaining.first {
                switchToSession(first)
            } else {
                startNewChat()
            }
        }
        refreshSessions()
    }

    private func refreshSessions() {
        chatSessions = ChatPersistenceManager.shared.fetchSessions(context: context)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    }

                    if isStreaming {
                        streamingBubble
                            .id("streaming")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 8)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
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
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 44))
                        .foregroundStyle(DS.Colors.accent)
                        .symbolEffect(.pulse.wholeSymbol, options: .repeating.speed(0.5))

                    Text("Centmond AI")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Colors.text)

                    Text("Your private, on-device finance assistant.")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Colors.subtext)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(DS.Colors.surfaceElevated.opacity(0.5))
                )
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
                showModelPicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18))
                    Text("Download Model")
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
                    showModelPicker = true
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
        ChatBubbleView(
            message: message,
            colorScheme: colorScheme,
            groupActions: { Self.groupActions($0) },
            onConfirm: { id in confirmAndExecute(id) },
            onReject: { id in
                if let a = conversation.pendingActions.first(where: { $0.id == id }) {
                    AIMemoryStore.shared.recordApproval(actionType: a.type.rawValue, approved: false)
                }
                conversation.rejectAction(id)
            },
            onEditMessage: { id, newText in
                editAndResend(messageId: id, newText: newText)
            }
        )
    }

    private var streamingBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            if streamingText.isEmpty {
                TypingDotsView(streamingPhase: streamingPhase)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            } else {
                // Header strip (matches ChatBubbleView)
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Colors.accent)
                        .symbolEffect(.pulse.wholeSymbol, options: .repeating.speed(0.3))
                    Text("Generating…")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Colors.accent.opacity(0.7))
                    Spacer()

                    // Blinking cursor
                    Circle()
                        .fill(DS.Colors.accent)
                        .frame(width: 6, height: 6)
                        .opacity(cursorVisible ? 1 : 0.2)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: cursorVisible)
                        .onAppear { cursorVisible = true }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()
                    .opacity(0.3)
                    .padding(.horizontal, 12)

                // Markdown with inline capsules — sanitizer closes dangling markers
                CapsuleMarkdownView(text: StreamingMarkdownSanitizer.sanitize(streamingText), insights: streamingInsights)
                    .textSelection(.disabled)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, streamingPhase == .buildingInsights || streamingPhase == .buildingActions ? 8 : 14)

                // Show building indicator when model is generating JSON blocks
                if streamingPhase == .buildingInsights || streamingPhase == .buildingActions {
                    Divider()
                        .opacity(0.2)
                        .padding(.horizontal, 12)

                    HStack(spacing: 8) {
                        Image(systemName: streamingPhase.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Colors.accent)
                            .symbolEffect(.pulse.wholeSymbol, options: .repeating.speed(0.5))

                        Text(streamingPhase.label + "…")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Colors.accent.opacity(0.7))

                        Spacer()

                        // Animated dots
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(DS.Colors.accent.opacity(0.5))
                                    .frame(width: 4, height: 4)
                                    .scaleEffect(glowPhase ? 1.2 : 0.6)
                                    .opacity(glowPhase ? 1.0 : 0.3)
                                    .animation(
                                        .easeInOut(duration: 0.5)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(i) * 0.15),
                                        value: glowPhase
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            DS.Colors.accent.opacity(0.25),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity
        ))
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

    // MARK: - Suggestions Strip

    private let suggestions: [(icon: String, text: String)] = [
        ("cart", "Add a $15 lunch expense"),
        ("chart.pie", "How much did I spend on dining this month?"),
        ("target", "Create a vacation savings goal for $2000"),
        ("arrow.triangle.branch", "Split a $80 dinner with Sara"),
        ("chart.bar", "Show me my spending breakdown"),
        ("banknote", "Set my monthly budget to $3000"),
        ("lightbulb", "Any tips to save more money?"),
        ("repeat.circle", "What subscriptions do I have?"),
    ]

    private var suggestionsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.text) { suggestion in
                    Button {
                        sendMessage(suggestion.text)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: suggestion.icon)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(DS.Colors.accent)
                            Text(suggestion.text)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DS.Colors.text)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(DS.Colors.accent.opacity(0.1), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
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
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isStreaming
                                ? DS.Colors.accent.opacity(glowPhase ? 0.7 : 0.2)
                                : (isInputFocused ? DS.Colors.accent.opacity(0.5) : Color.clear),
                            lineWidth: isStreaming ? 2 : 1.5
                        )
                        .animation(.easeInOut(duration: 0.2), value: isInputFocused)
                )
                .shadow(
                    color: isStreaming ? DS.Colors.accent.opacity(glowPhase ? 0.3 : 0.0) : .clear,
                    radius: isStreaming ? 8 : 0
                )
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: glowPhase)
                .onChange(of: isStreaming) { _, streaming in
                    if streaming {
                        glowPhase = true
                    } else {
                        glowPhase = false
                        cursorVisible = false
                    }
                }
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
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 32))
                    .foregroundStyle(DS.Colors.accent)
                    .symbolEffect(.pulse.wholeSymbol, options: .repeating.speed(0.5))

                Text("Loading AI Model…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                ModelLoadingHintView()

                VStack(alignment: .leading, spacing: 8) {
                    skeletonLoadingLine(width: 220)
                    skeletonLoadingLine(width: 180)
                    skeletonLoadingLine(width: 140)
                    skeletonLoadingLine(width: 100)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
    }

    private func skeletonLoadingLine(width: CGFloat) -> some View {
        // CPU note: 30 fps shimmer × N skeleton lines = expensive while llama
        // is also running. 12 fps still reads as a smooth shimmer.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let offset = CGFloat((t.truncatingRemainder(dividingBy: 1.5)) / 1.5)
            let shimmerX = -width + (width * 2.5 * offset)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.15))
                .frame(width: width, height: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(0.2), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width * 0.5)
                        .offset(x: shimmerX)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    // MARK: - Navigation Title with Status

    @State private var showModelInfo = false

    private var aiNavigationTitle: some View {
        HStack(spacing: 10) {
            Text("Centmond AI")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.text)

            if let active = aiManager.availableModels.first(where: { $0.filename == (aiManager.loadedModelFilename.isEmpty ? AIManager.modelFilename : aiManager.loadedModelFilename) }) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showModelInfo.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(active.quantization)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(DS.Colors.accent)
                        Image(systemName: showModelInfo ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(DS.Colors.accent.opacity(0.6))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        DS.Colors.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showModelInfo, arrowEdge: .bottom) {
                    modelInfoPopover(active)
                }
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(navStatusColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: navStatusColor.opacity(0.6), radius: isModelReady ? 4 : 0)
                    .scaleEffect(aiManager.status == .generating && glowPhase ? 1.4 : 1.0)
                    .opacity(aiManager.status == .generating ? (glowPhase ? 1.0 : 0.5) : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: glowPhase)
                    .animation(.easeInOut(duration: 0.5), value: navStatusColor)

                Text(navStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.subtext)
                    .contentTransition(.numericText())
            }
            .animation(.easeInOut(duration: 0.3), value: navStatusText)
        }
        .padding(.horizontal, 15)
    }

    private func modelInfoPopover(_ model: AIModelFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Model name
            HStack(spacing: 6) {
                Text(model.displayName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)

                if let rec = model.recommendation {
                    Text(rec.rawValue)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(rec == .bestBalance ? DS.Colors.positive : (rec == .fastest ? DS.Colors.warning : DS.Colors.accent))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(
                            (rec == .bestBalance ? DS.Colors.positive : (rec == .fastest ? DS.Colors.warning : DS.Colors.accent))
                                .opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                        )
                }
            }

            // Description
            Text(model.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Stats
            HStack(spacing: 14) {
                popoverStat(icon: "gauge.medium", label: "Speed", value: model.speedLabel, color: DS.Colors.positive)
                popoverStat(icon: "star.fill", label: "Quality", value: model.qualityLabel, color: DS.Colors.accent)
                popoverStat(icon: "memorychip", label: "RAM", value: estimatedRAM(model), color: DS.Colors.warning)
            }

            Divider()

            Text("You can change the model from Settings → AI Assistant")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 280)
    }

    private func popoverStat(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity)
    }

    private func estimatedRAM(_ model: AIModelFile) -> String {
        guard let size = model.sizeBytes else { return "?" }
        let ramBytes = Double(size) * 1.1 // ~10% overhead for context + buffers
        let gb = ramBytes / 1_073_741_824
        return String(format: "~%.1f GB", gb)
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
        case .generating: return streamingPhase.label + "..."
        case .loading: return "Loading \(AIManager.modelFilename.replacingOccurrences(of: ".gguf", with: ""))..."
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

    // MARK: - Chat Persistence

    private func loadChatHistory() {
        // Always start a new, empty chat when the AI view opens — the user
        // explicitly does NOT want to land on a half-finished prior thread.
        // Past conversations remain accessible via the sidebar (populated by
        // `refreshSessions`); clicking one calls `switchToSession` which
        // hydrates that thread on demand.
        //
        // Optimization: if the most-recent session is already empty (e.g. the
        // user opened the chat last time but never sent a message), reuse it
        // rather than spawning a fresh "New Chat" record every appearance.
        let pm = ChatPersistenceManager.shared
        conversation.clear()
        let sessions = pm.fetchSessions(context: context)
        if let latest = sessions.first, latest.messages.isEmpty {
            currentSession = latest
        } else {
            currentSession = pm.createSession(context: context)
        }
        refreshSessions()
    }

    private func persistUserMessage(_ text: String) {
        let pm = ChatPersistenceManager.shared
        if currentSession == nil {
            currentSession = pm.createSession(context: context)
        }
        guard let session = currentSession else { return }
        pm.saveUserMessage(text, session: session, context: context)
    }

    private func persistAssistantMessage(_ text: String, actions: [AIAction]?) {
        let pm = ChatPersistenceManager.shared
        if currentSession == nil {
            currentSession = pm.createSession(context: context)
        }
        guard let session = currentSession else { return }
        pm.saveAssistantMessage(text, actions: actions, session: session, context: context)
    }

    private func startNewChat() {
        conversation.clear()
        currentSession = ChatPersistenceManager.shared.createSession(context: context)
        refreshSessions()
    }

    /// Wrapper: adds assistant message to conversation AND persists to SwiftData
    private func addAndPersistAssistantMessage(_ text: String, actions: [AIAction]? = nil) {
        conversation.addAssistantMessage(text, actions: actions)
        persistAssistantMessage(text, actions: actions)
        refreshSessions()
    }

    /// Edit a user message: update text, remove subsequent messages, re-send to AI
    private func editAndResend(messageId: UUID, newText: String) {
        // Update in-memory conversation (removes all messages after the edited one)
        conversation.editUserMessage(messageId, newContent: newText)

        // Update persistence: delete messages after the edited one and update its text
        if let session = currentSession {
            let sorted = session.sortedMessages
            if let recordIdx = sorted.firstIndex(where: { $0.id == messageId }) {
                // Update the record text
                sorted[recordIdx].content = newText

                // Delete all records after it
                let toDelete = sorted.suffix(from: sorted.index(after: recordIdx))
                for record in toDelete {
                    context.delete(record)
                }
                session.messages.removeAll { record in
                    toDelete.contains(where: { $0.id == record.id })
                }
                try? context.save()
            }
        }
        refreshSessions()

        // Re-send the edited message to AI (message already exists, skip adding)
        sendMessage(newText, isResend: true)
    }

    private func sendMessage(_ text: String, isResend: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !isResend {
            conversation.addUserMessage(trimmed)
            persistUserMessage(trimmed)
        }
        input = ""
        isInputFocused = false

        AIUserPreferences.shared.learnFromMessage(trimmed)

        let classification = AIIntentRouter.classify(trimmed)

        let versionManager = AIPromptVersionManager.shared
        versionManager.updateHealth(from: aiManager.status)
        if let fallback = versionManager.fallbackResponse(intentType: classification.intentType) {
            addAndPersistAssistantMessage(fallback, actions: nil)
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
            addAndPersistAssistantMessage(shortCircuit, actions: nil)
            AIAuditLog.shared.recordResponse(entryId: auditId, responseText: shortCircuit, actions: [])
            return
        }

        // Don't short-circuit with canned clarification — let the AI model handle it.
        // The model understands typos, context, and nuance far better than regex.
        // Clarification is passed as a HINT to the system prompt, not shown directly.

        if aiManager.isDownloading {
            addAndPersistAssistantMessage("The AI model is still downloading. Please wait.", actions: nil)
            return
        }
        if !aiManager.isModelDownloaded {
            addAndPersistAssistantMessage("The AI model needs to be downloaded first. Scroll up and click Download.", actions: nil)
            return
        }
        if case .error(let msg) = aiManager.status {
            addAndPersistAssistantMessage("Model error: \(msg). Scroll up to retry or re-download.", actions: nil)
            return
        }

        isStreaming = true
        streamingText = ""
        streamingInsights = nil
        streamingSessionId = currentSession?.id

        Task { @MainActor in
            defer {
                isStreaming = false
                streamingText = ""
                streamingInsights = nil
                streamingPhase = .thinking
                streamingSessionId = nil
            }

            // Yield once so SwiftUI renders the TypingDotsView before we
            // block for SwiftData queries.
            streamingPhase = .thinking
            try? await Task.sleep(for: .milliseconds(1))

            // Build context (SwiftData requires MainActor)
            // For follow-up messages in an ongoing conversation, always include
            // financial context so the model can answer questions about spending.
            let isFollowUp = conversation.messages.count > 2
            let effectiveHint = (isFollowUp && (classification.contextHint == .minimal || classification.contextHint == .none))
                ? .full
                : classification.contextHint

            let financialContext: String
            switch effectiveHint {
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

            if effectiveHint == .full || effectiveHint == .budgetOnly {
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

            // Always send enough history so the model keeps conversational context.
            // Compact assistant messages: strip ---ACTIONS--- and ---INSIGHTS--- blocks
            // to save tokens but keep the readable text.
            let historyCount = 15
            let history = conversation.messages.suffix(historyCount).map { msg -> AIMessage in
                if msg.role == .assistant {
                    var textOnly = msg.content
                    // Strip ---INSIGHTS--- block
                    if let r = textOnly.range(of: "---INSIGHTS---", options: .caseInsensitive) {
                        let before = String(textOnly[textOnly.startIndex..<r.lowerBound])
                        // Find end of JSON array
                        let after = String(textOnly[r.upperBound...])
                        if let jsonEnd = after.range(of: "]") {
                            textOnly = before + String(after[jsonEnd.upperBound...])
                        } else {
                            textOnly = before
                        }
                    }
                    // Strip ---ACTIONS--- block
                    if let r = textOnly.range(of: "---ACTIONS---", options: .caseInsensitive) {
                        textOnly = String(textOnly[textOnly.startIndex..<r.lowerBound])
                    }
                    return AIMessage(role: .assistant, content: textOnly.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return msg
            }

            // Switch to analyzing phase after context is built
            streamingPhase = .analyzing

            // Consume tokens on a background task — only send batched
            // snapshots to MainActor every ~100ms so the UI thread stays free.
            let tokenStream = aiManager.stream(messages: history, systemPrompt: systemPrompt)

            let batchedSnapshots = AsyncStream<String> { continuation in
                Task.detached(priority: .background) {
                    var accumulated = ""
                    var lastYield = ContinuousClock.now
                    let interval: Duration = .milliseconds(200)

                    for await token in tokenStream {
                        accumulated += token
                        let now = ContinuousClock.now
                        if now - lastYield >= interval {
                            continuation.yield(accumulated)
                            lastYield = now
                        }
                    }
                    // Flush remaining tokens
                    continuation.yield(accumulated)
                    continuation.finish()
                }
            }

            // MainActor loop — runs only ~10 times/sec instead of 100+
            var rawResponse = ""
            for await snapshot in batchedSnapshots {
                rawResponse = snapshot
                let cleaned = Self.cleanStreamingText(snapshot)
                streamingText = cleaned

                // Update streaming phase based on raw content (before cleaning strips blocks)
                if cleaned.isEmpty {
                    // Still in prompt processing
                } else if snapshot.contains("---ACTION") {
                    streamingPhase = .buildingActions
                } else if snapshot.contains("---INSIGHT") {
                    streamingPhase = .buildingInsights
                    // Try to parse partial insights from raw snapshot for live capsules
                    streamingInsights = Self.parsePartialInsights(from: snapshot)
                } else if cleaned.count > 20 {
                    streamingPhase = .composing
                }
            }

            // Brief review phase before finalizing
            streamingPhase = .reviewing

            // Parse actions FIRST from the raw response (before cleaning strips ---ACTIONS---)
            let rawCleaned = rawResponse
                .replacingOccurrences(of: "<|turn|>", with: "")
                .replacingOccurrences(of: "<|turn>model", with: "")
                .replacingOccurrences(of: "<|turn>user", with: "")
                .replacingOccurrences(of: "<|turn>system", with: "")
                .replacingOccurrences(of: "<|turn>", with: "")
                .replacingOccurrences(of: "<end_of_turn>", with: "")
                .replacingOccurrences(of: "<start_of_turn>model", with: "")
                .replacingOccurrences(of: "<start_of_turn>user", with: "")
                .replacingOccurrences(of: "<start_of_turn>system", with: "")
                .replacingOccurrences(of: "<start_of_turn>", with: "")
            let parsed = AIActionParser.parse(rawCleaned)

            // Now clean the text portion for display
            var fullResponse = Self.cleanModelResponse(rawResponse, userMessage: trimmed)

            if fullResponse.isEmpty {
                fullResponse = parsed.text.isEmpty
                    ? "Sorry, something went wrong. Please try again."
                    : parsed.text
            }

            if parsed.actions.isEmpty && parsed.text.contains("---ACTIONS---") == false {
                versionManager.recordParseFailure()
            } else {
                versionManager.recordSuccess(responseLength: fullResponse.count)
            }

            AIAuditLog.shared.recordResponse(entryId: auditId, responseText: parsed.text, actions: parsed.actions)

            if let failure = AIClarificationEngine.validateActions(parsed.actions) {
                let errorMsg = failure.userMessage
                addAndPersistAssistantMessage(errorMsg, actions: nil)
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

                // Remove analysis actions — insight cards already display this data
                finalActions.removeAll { analysisTypes.contains($0.type) }

                let mutationActions = finalActions

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

                    var displayText = Self.buildActionSummary(mutationActions) ?? fullResponse
                    if !blockMessages.isEmpty {
                        displayText += "\n\n" + blockMessages.joined(separator: "\n")
                    }
                    addAndPersistAssistantMessage(displayText, actions: finalActions)

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

                    // Never auto-execute mutations — always require user confirmation
                    // Action cards will be shown for the user to approve/reject
                    if !classified.auto.isEmpty {
                        // Move auto-approved actions to pending (show action card)
                        for (action, _) in classified.auto {
                            if let idx = finalActions.firstIndex(where: { $0.id == action.id }) {
                                finalActions[idx].status = .pending
                            }
                        }
                    }

                    // Keep this block disabled — no auto-execution
                    if false, !classified.auto.isEmpty {
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
                    addAndPersistAssistantMessage(fullResponse, actions: finalActions)
                }
            } else {
                addAndPersistAssistantMessage(fullResponse, actions: nil)
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

            addAndPersistAssistantMessage("Done: \(result.summary)", actions: nil)

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
            addAndPersistAssistantMessage("Failed: \(result.summary)", actions: nil)
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
            addAndPersistAssistantMessage(summaries.joined(separator: "\n"), actions: nil)
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

    /// Lightweight cleaner for streaming display — only strips control tokens.
    /// Avoids expensive line filtering and regex during rapid token updates.
    static func cleanStreamingText(_ raw: String) -> String {
        var text = raw
        // Strip Gemma 4/3 control tokens only
        for marker in ["<|turn|>", "<|turn>model", "<|turn>user", "<|turn>system", "<|turn>",
                        "<end_of_turn>", "<start_of_turn>model", "<start_of_turn>user",
                        "<start_of_turn>system", "<start_of_turn>"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        // Strip insights block — partial match for streaming (tokens may split the separator)
        if let range = text.range(of: "---INSIGHT", options: .caseInsensitive) {
            text = String(text[text.startIndex..<range.lowerBound])
        }
        // Strip actions block — partial match
        if let range = text.range(of: "---ACTION", options: .caseInsensitive) {
            text = String(text[text.startIndex..<range.lowerBound])
        }
        // Fallback: strip raw JSON that leaked through (e.g. [{"category" or {"category")
        if let range = text.range(of: "[{\"") {
            text = String(text[text.startIndex..<range.lowerBound])
        } else if let range = text.range(of: "{\"category\"") {
            text = String(text[text.startIndex..<range.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Try to parse insights from raw streaming snapshot (may be incomplete JSON).
    /// Extracts whatever complete JSON objects are available so far.
    static func parsePartialInsights(from raw: String) -> [FinancialInsight]? {
        // Find the insights JSON block
        guard let separatorRange = raw.range(of: "---INSIGHT", options: .caseInsensitive) else {
            return nil
        }

        var jsonPart = String(raw[separatorRange.upperBound...])

        // Strip the rest of the separator (e.g. "S---" from "---INSIGHTS---")
        if let endDashes = jsonPart.range(of: "---") {
            jsonPart = String(jsonPart[endDashes.upperBound...])
        } else if let newline = jsonPart.firstIndex(of: "\n") {
            jsonPart = String(jsonPart[newline...])
        }

        // Strip ---ACTIONS--- and everything after
        if let actionsRange = jsonPart.range(of: "---ACTION", options: .caseInsensitive) {
            jsonPart = String(jsonPart[jsonPart.startIndex..<actionsRange.lowerBound])
        }

        jsonPart = jsonPart
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !jsonPart.isEmpty else { return nil }

        // Try parsing as-is first (complete JSON)
        if let data = jsonPart.data(using: .utf8),
           let insights = try? JSONDecoder().decode([FinancialInsight].self, from: data),
           !insights.isEmpty {
            return insights
        }

        // Incomplete JSON — try to close it
        // Find all complete objects by looking for }
        var fixedJSON = jsonPart
        // Remove trailing incomplete object (after last })
        if let lastBrace = fixedJSON.range(of: "}", options: .backwards) {
            fixedJSON = String(fixedJSON[fixedJSON.startIndex..<lastBrace.upperBound])
        }
        // Close the array if needed
        if !fixedJSON.hasSuffix("]") {
            // Remove trailing comma if present
            fixedJSON = fixedJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if fixedJSON.hasSuffix(",") {
                fixedJSON = String(fixedJSON.dropLast())
            }
            fixedJSON += "]"
        }

        if let data = fixedJSON.data(using: .utf8),
           let insights = try? JSONDecoder().decode([FinancialInsight].self, from: data),
           !insights.isEmpty {
            return insights
        }

        return nil
    }

    static func cleanModelResponse(_ raw: String, userMessage: String) -> String {
        var text = raw
            // Gemma 4 tokens
            .replacingOccurrences(of: "<|turn|>", with: "")
            .replacingOccurrences(of: "<|turn>model", with: "")
            .replacingOccurrences(of: "<|turn>user", with: "")
            .replacingOccurrences(of: "<|turn>system", with: "")
            .replacingOccurrences(of: "<|turn>", with: "")
            // Gemma 3 fallback
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

        // Remove ---ACTIONS--- and everything after (should have been split by parser, but clean up anyway)
        if let actionsRange = text.range(of: "---ACTIONS---", options: .caseInsensitive) {
            text = String(text[text.startIndex..<actionsRange.lowerBound])
        }

        let lines = text.components(separatedBy: .newlines)
        let filtered = lines.filter { line in
            let stripped = line.trimmingCharacters(in: .whitespaces)
            // Remove standalone punctuation/decoration lines
            if stripped.isEmpty { return true }
            if stripped == "-" || stripped == "–" || stripped == "—" || stripped == "•" || stripped == "*" {
                return false
            }
            if stripped.count >= 2 {
                let unique = Set(stripped)
                if unique.count == 1 && ["=", "-", "*", "─", "━", "·", "_"].contains(stripped.first!) {
                    return false
                }
            }
            return true
        }
        text = filtered.joined(separator: "\n")

        // Trim trailing punctuation-only characters (leftover dashes, bullets)
        while text.hasSuffix("-") || text.hasSuffix("–") || text.hasSuffix("—") || text.hasSuffix("•") || text.hasSuffix("*") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        text = enhanceMarkdown(text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Auto-enhance markdown: bold dollar amounts, bold bullet titles, ensure spacing
    private static func enhanceMarkdown(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        for i in lines.indices {
            var line = lines[i]

            // Auto-bold dollar amounts that aren't already bold: $123.45 → **$123.45**
            // Match $amount NOT preceded by ** and NOT followed by **
            let dollarPattern = #"(?<!\*\*)\$[\d,]+\.?\d*(?!\*\*)"#
            if let regex = try? NSRegularExpression(pattern: dollarPattern) {
                let range = NSRange(line.startIndex..., in: line)
                line = regex.stringByReplacingMatches(in: line, range: range, withTemplate: "**$0**")
            }

            // Auto-bold bullet titles: "• Word Word — rest" → "• **Word Word** — rest"
            // Also handles "- Word Word:" pattern
            let bulletPatterns = [
                (#"^(\s*[•\-\*]\s+)([A-Z][A-Za-z\s]{1,30})\s*(—|–|-|:)\s*"#, "$1**$2** $3 "),
            ]
            for (pattern, replacement) in bulletPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(line.startIndex..., in: line)
                    // Only apply if not already bold
                    if !line.contains("**") || !line.hasPrefix("•") && !line.hasPrefix("-") && !line.hasPrefix("*") {
                        let newLine = regex.stringByReplacingMatches(in: line, range: range, withTemplate: replacement)
                        if newLine != line { line = newLine }
                    }
                }
            }

            // Fix double-bold: ****text**** → **text**
            while line.contains("****") {
                line = line.replacingOccurrences(of: "****", with: "**")
            }

            lines[i] = line
        }

        return lines.joined(separator: "\n")
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
            case .assignMember: return "I'll assign \(p.memberName ?? "member") to that transaction."
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

// ============================================================
// MARK: - Shimmer Overlay (Skeleton Loading Effect)
// ============================================================

private struct ShimmerOverlay: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Color.clear,
                    DS.Colors.accent.opacity(0.12),
                    DS.Colors.accent.opacity(0.2),
                    DS.Colors.accent.opacity(0.12),
                    Color.clear,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 1.5)
            .offset(x: phase * geo.size.width)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 1.5
                }
            }
        }
        .allowsHitTesting(false)
    }
}
