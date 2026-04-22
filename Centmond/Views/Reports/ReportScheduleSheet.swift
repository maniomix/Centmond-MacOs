import SwiftUI
import SwiftData
import AppKit

// Creates (or creates-and-saves-preset-then-creates) a ScheduledReport
// for the currently-open ReportDefinition. A schedule always rides on a
// SavedReport so the runner has a stable, user-named definition to
// reference; if the user opened an unsaved template we create one on
// the fly using the report title.

struct ReportScheduleSheet: View {
    let definition: ReportDefinition
    let defaultName: String
    let onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var savedReports: [SavedReport]

    @State private var selectedSavedID: UUID?
    @State private var presetName: String = ""
    @State private var format: ReportExportFormat = .pdf
    @State private var cadence: ScheduledReportCadence = .monthly
    @State private var destinationPath: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Schedule export")
                    .font(CentmondTheme.Typography.heading2)
                Text(definition.kind.title)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Form {
                Section("Preset") {
                    if matchingSaved != nil {
                        Text("Reusing existing saved preset.")
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Preset name", text: $presetName)
                    }
                }

                Section("Schedule") {
                    Picker("Cadence", selection: $cadence) {
                        ForEach(ScheduledReportCadence.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }

                    Picker("Format", selection: $format) {
                        ForEach(ReportExportFormat.allCases) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                }

                Section("Destination folder") {
                    HStack {
                        Text(destinationPath.isEmpty ? "Not selected" : destinationPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(destinationPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { pickDestination() }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(SecondaryChipButtonStyle())
                Button {
                    saveSchedule()
                } label: {
                    Label("Save schedule", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSave)
            }
        }
        .padding(CentmondTheme.Spacing.xxl)
        .frame(width: 500)
        .onAppear {
            presetName = defaultName
            if let existing = matchingSaved {
                selectedSavedID = existing.id
            }
        }
    }

    // MARK: - Derived

    private var matchingSaved: SavedReport? {
        savedReports.first { $0.definition == definition }
    }

    private var canSave: Bool {
        !destinationPath.isEmpty &&
        (matchingSaved != nil || !presetName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - Actions

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a folder for scheduled exports"
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }

    private func saveSchedule() {
        errorMessage = nil

        let savedReport: SavedReport = {
            if let existing = matchingSaved { return existing }
            let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
            let newSaved = SavedReport(name: trimmed, definition: definition)
            context.insert(newSaved)
            return newSaved
        }()

        let schedule = ScheduledReport(
            savedReportID: savedReport.id,
            format: format,
            cadence: cadence,
            destinationPath: destinationPath,
            nextFireDate: cadence.nextFire(after: .now)
        )
        context.insert(schedule)

        do {
            try context.save()
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
