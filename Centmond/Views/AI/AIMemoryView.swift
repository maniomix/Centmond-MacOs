import SwiftUI

// ============================================================
// MARK: - AI Memory Management View
// ============================================================
//
// Lets the user inspect and manage what the AI has learned.
// Shows learned merchant preferences, tags, approval patterns,
// and assistant preferences with ability to delete/reset.
//
// macOS Centmond: @Observable singletons, category name strings.
//
// ============================================================

struct AIMemoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private let memoryStore = AIMemoryStore.shared
    private let merchantMemory = AIMerchantMemory.shared

    @State private var selectedType: AIMemoryType? = nil
    @State private var showResetConfirm: Bool = false
    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            List {
                summarySection
                preferencesSection
                merchantMemorySection

                ForEach(filteredTypes, id: \.self) { type in
                    memoryTypeSection(type)
                }

                resetSection
            }
            .searchable(text: $searchText, prompt: "Search memories…")
            .navigationTitle("AI Memory")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .automatic) {
                    Text("\(totalEntryCount) learned")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.subtext)
                }
            }
            .alert("Reset All Memory?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    memoryStore.clearAll()
                    merchantMemory.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all learned preferences, merchant associations, and patterns. This cannot be undone.")
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Personalization Memory")
                        .font(DS.Typography.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(DS.Colors.text)
                    Text("The AI learns from your corrections, preferences, and patterns to give better suggestions.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)

            let counts = memoryStore.countsByType
            let merchantCount = merchantMemory.merchants.count
            LazyVGrid(columns: [
                GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
            ], spacing: 8) {
                statBadge(count: merchantCount, label: "Merchants", icon: "storefront.fill")
                statBadge(count: counts[.merchantTag, default: 0], label: "Tags", icon: "number")
                statBadge(count: counts[.approvalPattern, default: 0], label: "Patterns", icon: "checkmark.shield.fill")
            }
        }
    }

    private func statBadge(count: Int, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(CentmondTheme.Typography.captionSmall)
                Text("\(count)")
                    .font(DS.Typography.callout)
                    .fontWeight(.bold)
            }
            .foregroundStyle(DS.Colors.accent)
            Text(label)
                .font(CentmondTheme.Typography.overlineRegular)
                .foregroundStyle(DS.Colors.subtext)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(DS.Colors.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: CentmondTheme.Radius.mdLoose, style: .continuous))
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section("Assistant Preferences") {
            HStack {
                Label("Clarifications", systemImage: "questionmark.bubble.fill")
                    .font(DS.Typography.callout)
                Spacer()
                Picker("", selection: Binding(
                    get: { memoryStore.clarificationStyle },
                    set: { memoryStore.clarificationStyle = $0 }
                )) {
                    ForEach(ClarificationStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Label("Response Tone", systemImage: "text.bubble.fill")
                    .font(DS.Typography.callout)
                Spacer()
                Picker("", selection: Binding(
                    get: { memoryStore.assistantTone },
                    set: { memoryStore.assistantTone = $0 }
                )) {
                    ForEach(AssistantTone.allCases, id: \.self) { tone in
                        Text(tone.displayName).tag(tone)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Label("Automation", systemImage: "gearshape.fill")
                    .font(DS.Typography.callout)
                Spacer()
                Picker("", selection: Binding(
                    get: { memoryStore.automationLevel },
                    set: { memoryStore.automationLevel = $0 }
                )) {
                    ForEach(AutomationComfort.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Merchant Memory

    private var merchantMemorySection: some View {
        let profiles = filteredMerchantProfiles
        return Group {
            if !profiles.isEmpty {
                Section {
                    ForEach(profiles.prefix(20)) { profile in
                        merchantRow(profile)
                    }
                    if profiles.count > 20 {
                        Text("+\(profiles.count - 20) more")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.subtext)
                    }
                } header: {
                    HStack {
                        Text("Merchant → Category")
                        Spacer()
                        Text("\(profiles.count)")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.subtext)
                    }
                }
            }
        }
    }

    private func merchantRow(_ profile: MerchantProfile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.text)
                HStack(spacing: 6) {
                    Text(profile.category)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.accent)
                    if profile.correctionCount > 0 {
                        Text("corrected \(profile.correctionCount)x")
                            .font(CentmondTheme.Typography.overlineRegular)
                            .foregroundStyle(DS.Colors.subtext)
                    }
                }
            }

            Spacer()

            confidenceBadge(profile.confidence)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                merchantMemory.forget(profile.merchantKey)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Memory Type Sections

    @ViewBuilder
    private func memoryTypeSection(_ type: AIMemoryType) -> some View {
        let items = filteredEntries(for: type)
        if !items.isEmpty {
            Section {
                ForEach(items) { entry in
                    memoryEntryRow(entry)
                }
            } header: {
                HStack {
                    Label(type.displayName, systemImage: type.icon)
                    Spacer()
                    Text("\(items.count)")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.subtext)
                }
            }
        }
    }

    private func memoryEntryRow(_ entry: AIMemoryEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.explanation)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.text)
                HStack(spacing: 6) {
                    Text(entry.source.displayName)
                        .font(CentmondTheme.Typography.overlineRegular)
                        .foregroundStyle(DS.Colors.subtext)
                    if entry.strength > 1 {
                        Text("x\(entry.strength)")
                            .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
                            .foregroundStyle(DS.Colors.accent)
                    }
                }
            }

            Spacer()

            confidenceBadge(entry.confidence)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                withAnimation {
                    memoryStore.deleteEntry(entry.id)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("Reset All Memory", systemImage: "trash.fill")
                    .foregroundStyle(DS.Colors.danger)
            }
        } footer: {
            Text("Removes all learned preferences, merchant associations, and behavior patterns.")
                .font(DS.Typography.caption)
        }
    }

    // MARK: - Helpers

    private func confidenceBadge(_ confidence: Double) -> some View {
        let pct = Int(confidence * 100)
        let color: Color = confidence >= 0.8 ? DS.Colors.positive
            : (confidence >= 0.5 ? DS.Colors.accent : DS.Colors.subtext)
        return Text("\(pct)%")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var filteredTypes: [AIMemoryType] {
        let preferenceTypes: Set<AIMemoryType> = [.clarificationStyle, .assistantTone, .automationLevel, .budgetHandling]
        let excluded = preferenceTypes.union([.merchantCategory])
        return AIMemoryType.allCases.filter { type in
            !excluded.contains(type) && !filteredEntries(for: type).isEmpty
        }
    }

    private func filteredEntries(for type: AIMemoryType) -> [AIMemoryEntry] {
        memoryStore.entriesByType(type).filter { entry in
            if searchText.isEmpty { return true }
            let q = searchText.lowercased()
            return entry.explanation.lowercased().contains(q)
                || entry.key.lowercased().contains(q)
                || entry.value.lowercased().contains(q)
                || (entry.merchantRef?.lowercased().contains(q) ?? false)
        }
    }

    private var filteredMerchantProfiles: [MerchantProfile] {
        let profiles = merchantMemory.topMerchants(limit: 100)
        if searchText.isEmpty { return profiles }
        let q = searchText.lowercased()
        return profiles.filter {
            $0.displayName.lowercased().contains(q)
                || $0.merchantKey.contains(q)
                || $0.category.contains(q)
        }
    }

    private var totalEntryCount: Int {
        memoryStore.totalCount + merchantMemory.merchants.count
    }
}
