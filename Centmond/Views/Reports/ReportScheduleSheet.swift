import SwiftUI
import SwiftData
import AppKit

// Creates a ScheduledReport from the parent ReportsView's current
// range/filter/sections selection. The parent passes them in verbatim so
// the user schedules exactly what they see on screen.

struct ReportScheduleSheet: View {
    let range: ReportDateRange
    let filter: ReportFilter
    let sections: Set<ReportSection>
    let onClose: () -> Void

    @Environment(\.modelContext) private var context

    @State private var name: String = "Centmond Report"
    @State private var format: ReportExportFormat = .pdf
    @State private var cadence: ScheduledReportCadence = .monthly
    @State private var destinationPath: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Schedule export")
                    .font(CentmondTheme.Typography.heading2)
                Text(summaryLine)
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Form {
                Section("Name") {
                    TextField("Report name", text: $name)
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
                        Text(errorMessage).foregroundStyle(.red)
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
    }

    // MARK: - Derived

    private var canSave: Bool {
        !destinationPath.isEmpty &&
        !sections.isEmpty &&
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var summaryLine: String {
        let count = sections.count
        let sectionWord = count == 1 ? "section" : "sections"
        let ranged: String = {
            let (s, e) = range.resolve()
            let df = DateFormatter(); df.dateFormat = "MMM d, yyyy"
            return "\(df.string(from: s)) — \(df.string(from: e))"
        }()
        return "\(count) \(sectionWord) · \(ranged)"
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = ScheduledReport(
            name: trimmed,
            sections: sections,
            range: range,
            filter: filter,
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
