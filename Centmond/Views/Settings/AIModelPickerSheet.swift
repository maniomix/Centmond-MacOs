import SwiftUI

/// Full model selection sheet — shows all catalog models.
/// Installed models can be selected; others show a download button with live progress.
struct AIModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let aiManager = AIManager.shared

    @State private var selectedFilename: String = AIManager.modelFilename

    private let catalog = AIModelFile.downloadCatalog

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    headerCard

                    ForEach(catalog) { option in
                        let model = option.modelFile
                        let isInstalled = aiManager.availableModels.contains { $0.filename == option.filename }
                        let isDownloading = aiManager.isDownloading && aiManager.downloadingFilename == option.filename

                        catalogCard(option: option, model: model, isInstalled: isInstalled, isDownloading: isDownloading)
                    }

                    importHint
                }
                .padding(20)
            }
            .background(Color(.windowBackgroundColor))
            .navigationTitle("Choose AI Model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        aiManager.switchModel(to: selectedFilename)
                        dismiss()
                    }
                    .disabled(selectedFilename == AIManager.modelFilename)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 520)
        .onAppear {
            aiManager.refreshAvailableModels()
            selectedFilename = AIManager.modelFilename
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(DS.Colors.accent)

            VStack(alignment: .leading, spacing: 3) {
                Text("Model Selection")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Smaller quantizations are faster but slightly less accurate. All models run entirely on your Mac — no data leaves your device.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.accent.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DS.Colors.accent.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Catalog Card

    private func catalogCard(option: AIModelFile.DownloadOption, model: AIModelFile, isInstalled: Bool, isDownloading: Bool) -> some View {
        let isSelected = option.filename == selectedFilename

        return VStack(alignment: .leading, spacing: 10) {
            // Top row
            HStack(spacing: 8) {
                // Radio (only for installed)
                if isInstalled {
                    ZStack {
                        Circle()
                            .strokeBorder(isSelected ? DS.Colors.accent : Color.secondary.opacity(0.3), lineWidth: 2)
                            .frame(width: 18, height: 18)
                        if isSelected {
                            Circle()
                                .fill(DS.Colors.accent)
                                .frame(width: 10, height: 10)
                        }
                    }
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Image(systemName: "arrow.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary.opacity(0.5))
                        )
                }

                Text(model.quantization)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(isInstalled ? .primary : .secondary)

                Text(option.sizeLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                if let rec = model.recommendation {
                    Text(rec.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(recommendationColor(rec))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            recommendationColor(rec).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }

                if isInstalled && option.filename == AIManager.modelFilename {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.Colors.positive)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            DS.Colors.positive.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                } else if isInstalled {
                    Text("INSTALLED")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }

                Spacer()
            }

            // Description
            Text(model.description)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            // Tier bars
            HStack(spacing: 20) {
                tierBar(label: "Speed", tier: model.speedTier, tierLabel: model.speedLabel, color: DS.Colors.positive)
                tierBar(label: "Quality", tier: model.qualityTier, tierLabel: model.qualityLabel, color: DS.Colors.accent)
                tierBar(label: "Memory", tier: memoryTier(model), tierLabel: memoryLabel(model), color: DS.Colors.warning)
            }

            // Download section (if not installed)
            if !isInstalled {
                if isDownloading, case .downloading(let progress, let bytes) = aiManager.status {
                    // Live progress
                    VStack(spacing: 6) {
                        ProgressView(value: progress)
                            .tint(DS.Colors.accent)

                        HStack {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(DS.Colors.accent)

                            Text("·")
                                .foregroundStyle(.quaternary)

                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)

                            Text("of \(option.sizeLabel)")
                                .font(.system(size: 10))
                                .foregroundStyle(.quaternary)

                            Spacer()

                            Button("Cancel") {
                                aiManager.cancelDownload()
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.danger)
                        }
                    }
                    .padding(.top, 4)
                } else {
                    Button {
                        aiManager.downloadModel(option: option)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 13))
                            Text("Download \(option.sizeLabel)")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(aiManager.isDownloading)
                    .opacity(aiManager.isDownloading ? 0.5 : 1)
                    .padding(.top, 4)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected && isInstalled ? DS.Colors.accent.opacity(0.06) : Color(.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected && isInstalled ? DS.Colors.accent.opacity(0.5) : Color.secondary.opacity(0.08),
                            lineWidth: isSelected && isInstalled ? 1.5 : 0.5
                        )
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isInstalled {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedFilename = option.filename
                }
            }
        }
        .opacity(isInstalled ? 1 : 0.85)
    }

    // MARK: - Import Hint

    private var importHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("You can also import custom .gguf models from Settings → AI Assistant")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - Tier Bar

    private func tierBar(label: String, tier: Int, tierLabel: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.quaternary)
                Spacer()
                Text(tierLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(color.opacity(0.8))
            }
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(i < tier ? color.opacity(0.7) : color.opacity(0.1))
                        .frame(height: 4)
                }
            }
        }
    }

    // MARK: - Helpers

    private func memoryTier(_ model: AIModelFile) -> Int {
        guard let size = model.sizeBytes else { return 3 }
        let gb = Double(size) / 1_073_741_824
        if gb < 4 { return 5 }
        if gb < 5 { return 4 }
        if gb < 6 { return 3 }
        if gb < 7.5 { return 2 }
        return 1
    }

    private func memoryLabel(_ model: AIModelFile) -> String {
        guard let size = model.sizeBytes else { return "Unknown" }
        let gb = Double(size) / 1_073_741_824
        if gb < 4 { return "Very Light" }
        if gb < 5 { return "Light" }
        if gb < 6 { return "Moderate" }
        if gb < 7.5 { return "Heavy" }
        return "Very Heavy"
    }

    private func recommendationColor(_ rec: AIModelFile.Recommendation) -> Color {
        switch rec {
        case .bestBalance: return DS.Colors.positive
        case .bestQuality: return DS.Colors.accent
        case .fastest: return DS.Colors.warning
        }
    }
}
