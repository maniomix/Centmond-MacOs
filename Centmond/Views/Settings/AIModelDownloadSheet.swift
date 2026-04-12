import SwiftUI

/// Sheet for choosing which AI model to download.
struct AIModelDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let aiManager = AIManager.shared

    @State private var selectedIndex = 0

    private let catalog = AIModelFile.downloadCatalog

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 36))
                        .foregroundStyle(DS.Colors.accent)
                        .symbolEffect(.pulse.wholeSymbol, options: .repeating.speed(0.5))

                    Text("Download AI Model")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Choose a model to run on your Mac. All processing stays on-device — nothing is sent to the cloud.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .padding(.top, 8)

                // Model options
                VStack(spacing: 10) {
                    ForEach(Array(catalog.enumerated()), id: \.element.id) { index, option in
                        let model = option.modelFile
                        let isSelected = index == selectedIndex

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedIndex = index
                            }
                        } label: {
                            HStack(spacing: 12) {
                                // Radio
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

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(model.quantization)
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.primary)

                                        Text(option.sizeLabel)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)

                                        if let rec = model.recommendation {
                                            Text(rec.rawValue)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(rec == .bestBalance ? DS.Colors.positive : (rec == .fastest ? DS.Colors.warning : DS.Colors.accent))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(
                                                    (rec == .bestBalance ? DS.Colors.positive : (rec == .fastest ? DS.Colors.warning : DS.Colors.accent))
                                                        .opacity(0.12),
                                                    in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                )
                                        }

                                        // Installed badge
                                        if aiManager.availableModels.contains(where: { $0.filename == option.filename }) {
                                            Text("INSTALLED")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(DS.Colors.positive)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1.5)
                                                .background(
                                                    DS.Colors.positive.opacity(0.12),
                                                    in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                )
                                        }
                                    }

                                    Text(model.description)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    // Speed/Quality mini bars
                                    HStack(spacing: 16) {
                                        miniBar(label: "Speed", tier: model.speedTier, color: DS.Colors.positive)
                                        miniBar(label: "Quality", tier: model.qualityTier, color: DS.Colors.accent)
                                    }
                                    .padding(.top, 2)
                                }

                                Spacer()
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? DS.Colors.accent.opacity(0.06) : Color(.controlBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(
                                                isSelected ? DS.Colors.accent.opacity(0.4) : Color.clear,
                                                lineWidth: 1.5
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                Spacer()

                // Download button
                Button {
                    let option = catalog[selectedIndex]
                    aiManager.downloadModel(option: option)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 16))
                        Text("Download \(catalog[selectedIndex].modelFile.quantization) (\(catalog[selectedIndex].sizeLabel))")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .padding(.vertical, 12)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(width: 460, height: 480)
    }

    private func miniBar(label: String, tier: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.quaternary)
                .frame(width: 36, alignment: .leading)
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < tier ? color.opacity(0.65) : color.opacity(0.1))
                    .frame(width: 14, height: 3.5)
            }
        }
    }
}
