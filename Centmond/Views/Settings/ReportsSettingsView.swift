import SwiftUI

struct ReportsSettingsView: View {
    @Bindable private var telemetry = ReportsTelemetry.shared

    @AppStorage("reports.defaultFormat") private var defaultFormatRaw: String = ReportExportFormat.pdf.rawValue
    @AppStorage("reports.csvIncludeRawTransactions") private var csvIncludeRaw = false
    @AppStorage("reports.autoSummarize") private var autoSummarize = false

    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Export defaults") {
                Picker("Default format", selection: $defaultFormatRaw) {
                    ForEach(ReportExportFormat.allCases) { f in
                        Text(f.displayName).tag(f.rawValue)
                    }
                }

                Toggle("Include raw transactions in CSV", isOn: $csvIncludeRaw)

                Toggle("Auto-generate AI narrative on open", isOn: $autoSummarize)
            }

            Section("Your activity") {
                HStack {
                    Text("Reports opened")
                    Spacer()
                    Text("\(telemetry.totalRuns())")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Files exported")
                    Spacer()
                    Text("\(telemetry.totalExports())")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if !telemetry.topKinds().isEmpty {
                    DisclosureGroup("Most used templates") {
                        ForEach(telemetry.topKinds(limit: 5), id: \.0.rawValue) { kind, count in
                            HStack {
                                Label(kind.title, systemImage: kind.symbol)
                                Spacer()
                                Text("\(count)×")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Reset activity counters", systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text("Activity data is stored locally and never leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset activity counters?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { telemetry.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears run and export counts. Saved presets and generated files are not affected.")
        }
    }
}
