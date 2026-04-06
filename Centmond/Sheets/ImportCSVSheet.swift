import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Import Step

enum ImportStep {
    case dropZone
    case preview
    case confirmMode        // Replace vs Merge (only if existing transactions exist)
    case confirmCategories  // New categories found in CSV
    case importing
    case success
}

enum ImportMode {
    case merge
    case replace
}

// MARK: - Sheet View

struct ImportCSVSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var existingTransactions: [Transaction]
    @Query private var existingCategories: [BudgetCategory]

    @State private var step: ImportStep = .dropZone
    @State private var isDragOver = false
    @State private var selectedFileURL: URL?
    @State private var parsedRows: [CSVRow] = []
    @State private var importError: String?
    @State private var importMode: ImportMode = .merge
    @State private var newCategoryNames: [String] = []       // categories in CSV not in DB
    @State private var categoriesToAdd: Set<String> = []     // user-selected ones to create
    @State private var importedCount = 0

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: stepTitle) { dismiss() }
            Divider().background(CentmondTheme.Colors.strokeSubtle)

            contentView

            Divider().background(CentmondTheme.Colors.strokeSubtle)
            footerView
        }
        .frame(minHeight: 460)
        .background(CentmondTheme.Colors.bgPrimary)
    }

    private var stepTitle: String {
        switch step {
        case .dropZone:      return "Import CSV"
        case .preview:       return "Import CSV"
        case .confirmMode:   return "Import Mode"
        case .confirmCategories: return "New Categories"
        case .importing:     return "Importing…"
        case .success:       return "Import Complete"
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch step {
        case .dropZone:          dropZoneView
        case .preview:           previewView
        case .confirmMode:       confirmModeView
        case .confirmCategories: confirmCategoriesView
        case .importing:         importingView
        case .success:           importSuccessView
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            if let importError {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.negative)
                    Text(importError)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                        .lineLimit(2)
                }
            }

            Spacer()

            switch step {
            case .dropZone:
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())

            case .preview:
                Button("Back") { goBack() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Continue") { advanceFromPreview() }
                    .buttonStyle(PrimaryButtonStyle())

            case .confirmMode:
                Button("Back") { goBack() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Continue") { advanceFromMode() }
                    .buttonStyle(PrimaryButtonStyle())

            case .confirmCategories:
                Button("Back") { goBack() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Continue") { startImport() }
                    .buttonStyle(PrimaryButtonStyle())

            case .importing:
                EmptyView()

            case .success:
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, CentmondTheme.Spacing.lg)
        .padding(.vertical, CentmondTheme.Spacing.lg)
        .animation(CentmondTheme.Motion.default, value: step)
    }

    // MARK: - Navigation

    private func goBack() {
        withAnimation(CentmondTheme.Motion.default) {
            importError = nil
            switch step {
            case .preview:           step = .dropZone; parsedRows = []; selectedFileURL = nil
            case .confirmMode:       step = .preview
            case .confirmCategories: step = existingTransactions.isEmpty ? .preview : .confirmMode
            default: break
            }
        }
    }

    private func advanceFromPreview() {
        if !existingTransactions.isEmpty {
            withAnimation(CentmondTheme.Motion.default) { step = .confirmMode }
        } else {
            advanceFromMode()
        }
    }

    private func advanceFromMode() {
        let existingNames = Set(existingCategories.map { $0.name.lowercased() })
        let csvNames = Set(parsedRows.compactMap { $0.category?.lowercased() })
        let newOnes = csvNames.subtracting(existingNames)
            .map { $0.capitalized }
            .sorted()

        newCategoryNames = newOnes
        categoriesToAdd = Set(newOnes)

        if !newOnes.isEmpty {
            withAnimation(CentmondTheme.Motion.default) { step = .confirmCategories }
        } else {
            startImport()
        }
    }

    private func startImport() {
        withAnimation(CentmondTheme.Motion.default) { step = .importing }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            performImport()
        }
    }
}

// MARK: - Drop Zone

extension ImportCSVSheet {

    private var dropZoneView: some View {
        VStack(spacing: CentmondTheme.Spacing.xl) {
            Spacer()

            VStack(spacing: CentmondTheme.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(isDragOver ? CentmondTheme.Colors.accentSubtle : CentmondTheme.Colors.bgTertiary)
                        .frame(width: 72, height: 72)
                    Image(systemName: "doc.badge.arrow.up")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(isDragOver ? CentmondTheme.Colors.accent : CentmondTheme.Colors.textTertiary)
                }
                .scaleEffect(isDragOver ? 1.08 : 1.0)
                .animation(CentmondTheme.Motion.default, value: isDragOver)

                VStack(spacing: CentmondTheme.Spacing.xs) {
                    Text("Drop your CSV file here")
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                    Text("or click to browse")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textTertiary)
                }

                Button {
                    browseFiles()
                } label: {
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .medium))
                        Text("Browse Files")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .fill(isDragOver ? CentmondTheme.Colors.accentSubtle.opacity(0.4) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isDragOver ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault,
                        style: StrokeStyle(lineWidth: isDragOver ? 2 : 1, dash: [8, 5])
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture { browseFiles() }
            .onDrop(of: [.commaSeparatedText, .fileURL], isTargeted: $isDragOver) { handleDrop($0) }
            .padding(.horizontal, CentmondTheme.Spacing.lg)

            // Column hint tags
            HStack(spacing: CentmondTheme.Spacing.xs) {
                ForEach(["Date", "Amount", "Description", "Category"], id: \.self) { label in
                    Text(label)
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.textSecondary)
                        .padding(.horizontal, CentmondTheme.Spacing.sm)
                        .padding(.vertical, 3)
                        .background(CentmondTheme.Colors.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
                }
                Text("auto-detected")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }

            Spacer()
        }
    }
}

// MARK: - Preview Table

extension ImportCSVSheet {

    private var previewView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File info bar
            if let url = selectedFileURL {
                let income = parsedRows.filter { $0.isIncome }.reduce(Decimal.zero) { $0 + $1.amount }
                let expense = parsedRows.filter { !$0.isIncome }.reduce(Decimal.zero) { $0 + $1.amount }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CentmondTheme.Colors.accent)
                        Text(url.lastPathComponent)
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(parsedRows.count) rows")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    }
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        if income > 0 {
                            summaryBadge(label: "+\(CurrencyFormat.compact(income))", color: CentmondTheme.Colors.positive)
                        }
                        if expense > 0 {
                            summaryBadge(label: "-\(CurrencyFormat.compact(expense))", color: CentmondTheme.Colors.negative)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .padding(.vertical, CentmondTheme.Spacing.sm)
                .background(CentmondTheme.Colors.bgSecondary)
            }

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Header row
            previewHeaderRow
                .padding(.horizontal, CentmondTheme.Spacing.md)
                .padding(.vertical, CentmondTheme.Spacing.sm)
                .background(CentmondTheme.Colors.bgSecondary.opacity(0.5))

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(parsedRows.enumerated()), id: \.offset) { index, row in
                        previewRow(row)
                            .padding(.horizontal, CentmondTheme.Spacing.md)
                            .padding(.vertical, CentmondTheme.Spacing.sm)
                            .background(index % 2 == 0 ? Color.clear : CentmondTheme.Colors.bgSecondary.opacity(0.3))
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private var previewHeaderRow: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Text("Date").frame(width: 44, alignment: .leading)
            Text("Description").frame(maxWidth: .infinity, alignment: .leading)
            Text("Category").frame(width: 68, alignment: .leading)
            Text("Amount").frame(width: 80, alignment: .trailing)
        }
        .font(CentmondTheme.Typography.captionMedium)
        .foregroundStyle(CentmondTheme.Colors.textTertiary)
    }

    private func previewRow(_ row: CSVRow) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Text(row.displayDate)
                .frame(width: 44, alignment: .leading)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(row.payee)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Text(row.category?.capitalized ?? "—")
                .frame(width: 68, alignment: .leading)
                .lineLimit(1)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Text(row.amountString)
                .frame(width: 80, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(row.isIncome ? CentmondTheme.Colors.positive : CentmondTheme.Colors.negative.opacity(0.85))
        }
        .font(CentmondTheme.Typography.caption)
    }

    private func summaryBadge(label: String, color: Color) -> some View {
        Text(label)
            .font(CentmondTheme.Typography.captionMedium)
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, CentmondTheme.Spacing.sm)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous))
    }
}

// MARK: - Confirm Mode (Replace vs Merge)

extension ImportCSVSheet {

    private var confirmModeView: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            Spacer()

            VStack(spacing: CentmondTheme.Spacing.xs) {
                Text("You already have \(existingTransactions.count) transactions.")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text("How would you like to import these \(parsedRows.count) new ones?")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: CentmondTheme.Spacing.md) {
                // Merge card
                importModeCard(
                    isSelected: importMode == .merge,
                    icon: "arrow.triangle.merge",
                    iconColor: CentmondTheme.Colors.accent,
                    title: "Merge",
                    description: "Keep existing transactions and add the imported ones alongside them."
                ) {
                    withAnimation(CentmondTheme.Motion.default) { importMode = .merge }
                }

                // Replace card
                importModeCard(
                    isSelected: importMode == .replace,
                    icon: "trash.fill",
                    iconColor: CentmondTheme.Colors.negative,
                    title: "Replace",
                    description: "Delete all existing transactions and replace them with the imported ones."
                ) {
                    withAnimation(CentmondTheme.Motion.default) { importMode = .replace }
                }
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)

            if importMode == .replace {
                HStack(spacing: CentmondTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(CentmondTheme.Colors.negative)
                    Text("This will permanently delete \(existingTransactions.count) transactions.")
                        .font(CentmondTheme.Typography.caption)
                        .foregroundStyle(CentmondTheme.Colors.negative)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer()
        }
        .padding(.vertical, CentmondTheme.Spacing.lg)
    }

    private func importModeCard(
        isSelected: Bool,
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.md) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: CentmondTheme.Radius.sm, style: .continuous)
                            .fill(iconColor.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(iconColor)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(CentmondTheme.Colors.accent)
                    } else {
                        Circle()
                            .strokeBorder(CentmondTheme.Colors.strokeDefault, lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                    }
                }

                Text(title)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                Text(description)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(CentmondTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CentmondTheme.Colors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plainHover)
    }
}

// MARK: - Confirm Categories

extension ImportCSVSheet {

    private var confirmCategoriesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Explanation
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.xs) {
                Text("\(newCategoryNames.count) new \(newCategoryNames.count == 1 ? "category" : "categories") found in your CSV.")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text("Select which ones you'd like to add to your budget.")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.top, CentmondTheme.Spacing.lg)
            .padding(.bottom, CentmondTheme.Spacing.md)

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Select all / none
            HStack {
                Button(categoriesToAdd.count == newCategoryNames.count ? "Deselect All" : "Select All") {
                    withAnimation(CentmondTheme.Motion.default) {
                        if categoriesToAdd.count == newCategoryNames.count {
                            categoriesToAdd = []
                        } else {
                            categoriesToAdd = Set(newCategoryNames)
                        }
                    }
                }
                .font(CentmondTheme.Typography.captionMedium)
                .foregroundStyle(CentmondTheme.Colors.accent)
                .buttonStyle(.plainHover)
                Spacer()
                Text("\(categoriesToAdd.count) of \(newCategoryNames.count) selected")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.vertical, CentmondTheme.Spacing.sm)
            .background(CentmondTheme.Colors.bgSecondary.opacity(0.5))

            Divider().background(CentmondTheme.Colors.strokeSubtle)

            // Category list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(newCategoryNames, id: \.self) { name in
                        categoryRow(name: name)
                        Divider()
                            .background(CentmondTheme.Colors.strokeSubtle)
                            .padding(.horizontal, CentmondTheme.Spacing.lg)
                    }
                }
            }
        }
    }

    private func categoryRow(name: String) -> some View {
        let isSelected = categoriesToAdd.contains(name)
        let count = parsedRows.filter { $0.category?.capitalized == name }.count

        return Button {
            withAnimation(CentmondTheme.Motion.default) {
                if isSelected {
                    categoriesToAdd.remove(name)
                } else {
                    categoriesToAdd.insert(name)
                }
            }
        } label: {
            HStack(spacing: CentmondTheme.Spacing.md) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isSelected ? CentmondTheme.Colors.accent : Color.clear)
                        .frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault,
                            lineWidth: 1.5
                        )
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                // Icon
                let resolved = Self.resolveCategory(name)
                ZStack {
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous)
                        .fill(Color(hex: resolved.colorHex).opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: resolved.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: resolved.colorHex))
                }

                Text(name)
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)

                Spacer()

                Text("\(count) \(count == 1 ? "transaction" : "transactions")")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
            }
            .padding(.horizontal, CentmondTheme.Spacing.lg)
            .padding(.vertical, CentmondTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHover)
    }
}

// MARK: - Importing / Success

extension ImportCSVSheet {

    private var importingView: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Importing transactions…")
                .font(CentmondTheme.Typography.body)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var importSuccessView: some View {
        VStack(spacing: CentmondTheme.Spacing.lg) {
            Spacer()

            ZStack {
                Circle()
                    .fill(CentmondTheme.Colors.positive.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(CentmondTheme.Colors.positive)
            }

            VStack(spacing: CentmondTheme.Spacing.xs) {
                Text("Import Complete")
                    .font(CentmondTheme.Typography.heading2)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text("\(importedCount) transactions imported successfully.")
                    .font(CentmondTheme.Typography.body)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(CentmondTheme.Spacing.xxl)
    }
}

// MARK: - File Handling

extension ImportCSVSheet {

    private func browseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Select a CSV File"
        panel.message = "Choose a CSV file to import transactions from."

        if panel.runModal() == .OK, let url = panel.url {
            loadCSV(from: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                DispatchQueue.main.async {
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        loadCSV(from: url)
                    } else if let url = item as? URL {
                        loadCSV(from: url)
                    }
                }
            }
            return true
        }
        return false
    }

    private func loadCSV(from url: URL) {
        importError = nil
        selectedFileURL = url

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let rows = parseCSV(content)
            if rows.isEmpty {
                importError = "No valid rows found. Check that your file has date and amount columns."
            } else {
                withAnimation(CentmondTheme.Motion.default) {
                    parsedRows = rows
                    step = .preview
                }
            }
        } catch {
            importError = "Could not read file: \(error.localizedDescription)"
        }
    }
}

// MARK: - Smart CSV Parsing

extension ImportCSVSheet {

    struct CSVRow {
        let dateString: String
        let displayDate: String
        let payee: String
        let amount: Decimal
        let amountString: String
        let isIncome: Bool
        let category: String?
        let parsedDate: Date?
    }

    private struct ColumnMap {
        var dateIndex: Int?
        var amountIndex: Int?
        var payeeIndex: Int?
        var categoryIndex: Int?
        var typeIndex: Int?
        var noteIndex: Int?

        var isValid: Bool { dateIndex != nil && amountIndex != nil }
        var descriptionIndex: Int? { payeeIndex ?? noteIndex }
    }

    private func parseCSV(_ content: String) -> [CSVRow] {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else { return [] }

        let headerFields = parseCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let columnMap = buildColumnMap(from: headerFields)

        guard columnMap.isValid else {
            importError = "Could not find required columns (date, amount). Found: \(headerFields.joined(separator: ", "))"
            return []
        }

        let dataLines = Array(lines.dropFirst())
        var rows: [CSVRow] = []

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d"
        displayFormatter.locale = Locale(identifier: "en_US")

        let currencyFormatter = NumberFormatter()
        currencyFormatter.numberStyle = .currency
        currencyFormatter.currencyCode = "USD"
        currencyFormatter.maximumFractionDigits = 2

        for line in dataLines {
            let fields = parseCSVLine(line)

            guard let dateIdx = columnMap.dateIndex, dateIdx < fields.count else { continue }
            let dateString = fields[dateIdx].trimmingCharacters(in: .whitespaces)
            guard !dateString.isEmpty else { continue }

            guard let amountIdx = columnMap.amountIndex, amountIdx < fields.count else { continue }
            let rawAmount = fields[amountIdx]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "£", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
            guard let amount = Decimal(string: rawAmount), amount != 0 else { continue }

            var payee = "Unknown"
            if let descIdx = columnMap.descriptionIndex, descIdx < fields.count {
                let desc = fields[descIdx].trimmingCharacters(in: .whitespaces)
                if !desc.isEmpty { payee = desc }
            }

            var category: String?
            if let catIdx = columnMap.categoryIndex, catIdx < fields.count {
                let cat = fields[catIdx].trimmingCharacters(in: .whitespaces)
                if !cat.isEmpty { category = cat }
            }

            var isIncome = amount > 0
            if let typeIdx = columnMap.typeIndex, typeIdx < fields.count {
                let typeStr = fields[typeIdx].trimmingCharacters(in: .whitespaces).lowercased()
                if typeStr == "income" || typeStr == "credit" || typeStr == "deposit" { isIncome = true }
                else if typeStr == "expense" || typeStr == "debit" || typeStr == "withdrawal" { isIncome = false }
            }

            let absAmount = abs(amount)
            let parsedDate = Self.parseDate(dateString)
            let prefix = isIncome ? "+" : "-"
            let formatted = prefix + (currencyFormatter.string(from: absAmount as NSDecimalNumber) ?? "\(absAmount)")
            let displayDate = parsedDate.map { displayFormatter.string(from: $0) } ?? dateString

            rows.append(CSVRow(
                dateString: dateString,
                displayDate: displayDate,
                payee: payee,
                amount: absAmount,
                amountString: formatted,
                isIncome: isIncome,
                category: category,
                parsedDate: parsedDate
            ))
        }

        return rows
    }

    private func buildColumnMap(from headers: [String]) -> ColumnMap {
        var map = ColumnMap()

        let dateAliases:    Set<String> = ["date","transaction_date","trans_date","transaction date","posting_date","posting date","value_date","booked"]
        let amountAliases:  Set<String> = ["amount","value","sum","total","transaction_amount"]
        let payeeAliases:   Set<String> = ["payee","description","merchant","name","recipient","vendor","narrative","reference"]
        let categoryAliases:Set<String> = ["category","group","classification","tag","label"]
        let typeAliases:    Set<String> = ["type","kind","transaction_type","trans_type","direction"]
        let noteAliases:    Set<String> = ["note","notes","memo","comment","remarks","details"]

        for (index, h) in headers.enumerated() {
            if map.dateIndex == nil    && dateAliases.contains(h)    { map.dateIndex = index }
            else if map.amountIndex == nil && amountAliases.contains(h) { map.amountIndex = index }
            else if map.payeeIndex == nil  && payeeAliases.contains(h)  { map.payeeIndex = index }
        }
        for (index, h) in headers.enumerated() {
            guard index != map.dateIndex, index != map.amountIndex, index != map.payeeIndex else { continue }
            if map.typeIndex == nil     && typeAliases.contains(h)     { map.typeIndex = index }
            else if map.categoryIndex == nil && categoryAliases.contains(h) { map.categoryIndex = index }
            else if map.noteIndex == nil     && noteAliases.contains(h)     { map.noteIndex = index }
        }

        return map
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" { inQuotes.toggle() }
            else if char == "," && !inQuotes { fields.append(current); current = "" }
            else { current.append(char) }
        }
        fields.append(current)
        return fields
    }

    private static let dateFormatters: [DateFormatter] = {
        ["yyyy-MM-dd","MM/dd/yyyy","dd/MM/yyyy","yyyy/MM/dd","MM-dd-yyyy","dd-MM-yyyy",
         "MMM dd, yyyy","MMMM dd, yyyy","dd MMM yyyy","dd.MM.yyyy","yyyy.MM.dd"].map {
            let f = DateFormatter(); f.dateFormat = $0
            f.locale = Locale(identifier: "en_US_POSIX"); return f
        }
    }()

    private static func parseDate(_ string: String) -> Date? {
        dateFormatters.lazy.compactMap { $0.date(from: string) }.first
    }
}

// MARK: - Category Icon & Color Resolver

extension ImportCSVSheet {

    struct ResolvedCategory {
        let icon: String
        let colorHex: String
    }

    /// Maps a category name to an appropriate SF Symbol icon and color
    static func resolveCategory(_ name: String) -> ResolvedCategory {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Try exact match first, then keyword match
        if let exact = categoryLookup[key] { return exact }

        for (keyword, resolved) in categoryKeywords {
            if key.contains(keyword) { return resolved }
        }

        return ResolvedCategory(icon: "tag.fill", colorHex: "6B7280") // gray fallback
    }

    private static let categoryLookup: [String: ResolvedCategory] = [
        // Food & Drink
        "groceries":      ResolvedCategory(icon: "cart.fill",              colorHex: "22C55E"),
        "grocery":        ResolvedCategory(icon: "cart.fill",              colorHex: "22C55E"),
        "food":           ResolvedCategory(icon: "fork.knife",             colorHex: "F97316"),
        "dining":         ResolvedCategory(icon: "fork.knife",             colorHex: "F97316"),
        "restaurant":     ResolvedCategory(icon: "fork.knife",             colorHex: "F97316"),
        "restaurants":    ResolvedCategory(icon: "fork.knife",             colorHex: "F97316"),
        "eating out":     ResolvedCategory(icon: "fork.knife",             colorHex: "F97316"),
        "coffee":         ResolvedCategory(icon: "cup.and.saucer.fill",    colorHex: "92400E"),
        "cafe":           ResolvedCategory(icon: "cup.and.saucer.fill",    colorHex: "92400E"),

        // Transport
        "transport":      ResolvedCategory(icon: "bus.fill",               colorHex: "3B82F6"),
        "transportation": ResolvedCategory(icon: "bus.fill",               colorHex: "3B82F6"),
        "transit":        ResolvedCategory(icon: "tram.fill",              colorHex: "3B82F6"),
        "taxi":           ResolvedCategory(icon: "car.fill",               colorHex: "3B82F6"),
        "uber":           ResolvedCategory(icon: "car.fill",               colorHex: "3B82F6"),
        "gas":            ResolvedCategory(icon: "fuelpump.fill",          colorHex: "EF4444"),
        "fuel":           ResolvedCategory(icon: "fuelpump.fill",          colorHex: "EF4444"),
        "parking":        ResolvedCategory(icon: "parkingsign",            colorHex: "6366F1"),
        "car":            ResolvedCategory(icon: "car.fill",               colorHex: "3B82F6"),
        "auto":           ResolvedCategory(icon: "car.fill",               colorHex: "3B82F6"),

        // Housing
        "rent":           ResolvedCategory(icon: "house.fill",             colorHex: "8B5CF6"),
        "mortgage":       ResolvedCategory(icon: "house.fill",             colorHex: "8B5CF6"),
        "housing":        ResolvedCategory(icon: "house.fill",             colorHex: "8B5CF6"),
        "home":           ResolvedCategory(icon: "house.fill",             colorHex: "8B5CF6"),

        // Bills & Utilities
        "bills":          ResolvedCategory(icon: "doc.text.fill",          colorHex: "F59E0B"),
        "utilities":      ResolvedCategory(icon: "bolt.fill",              colorHex: "F59E0B"),
        "electricity":    ResolvedCategory(icon: "bolt.fill",              colorHex: "F59E0B"),
        "water":          ResolvedCategory(icon: "drop.fill",              colorHex: "06B6D4"),
        "internet":       ResolvedCategory(icon: "wifi",                   colorHex: "6366F1"),
        "phone":          ResolvedCategory(icon: "phone.fill",             colorHex: "6366F1"),
        "mobile":         ResolvedCategory(icon: "iphone",                 colorHex: "6366F1"),

        // Shopping
        "shopping":       ResolvedCategory(icon: "bag.fill",               colorHex: "EC4899"),
        "clothing":       ResolvedCategory(icon: "tshirt.fill",            colorHex: "EC4899"),
        "clothes":        ResolvedCategory(icon: "tshirt.fill",            colorHex: "EC4899"),
        "electronics":    ResolvedCategory(icon: "desktopcomputer",        colorHex: "6366F1"),

        // Health
        "health":         ResolvedCategory(icon: "heart.fill",             colorHex: "EF4444"),
        "healthcare":     ResolvedCategory(icon: "heart.fill",             colorHex: "EF4444"),
        "medical":        ResolvedCategory(icon: "cross.case.fill",        colorHex: "EF4444"),
        "pharmacy":       ResolvedCategory(icon: "pills.fill",             colorHex: "EF4444"),
        "fitness":        ResolvedCategory(icon: "figure.run",             colorHex: "10B981"),
        "gym":            ResolvedCategory(icon: "dumbbell.fill",          colorHex: "10B981"),

        // Education
        "education":      ResolvedCategory(icon: "graduationcap.fill",     colorHex: "6366F1"),
        "school":         ResolvedCategory(icon: "graduationcap.fill",     colorHex: "6366F1"),
        "tuition":        ResolvedCategory(icon: "graduationcap.fill",     colorHex: "6366F1"),
        "books":          ResolvedCategory(icon: "book.fill",              colorHex: "8B5CF6"),
        "courses":        ResolvedCategory(icon: "book.fill",              colorHex: "8B5CF6"),

        // Entertainment
        "entertainment":  ResolvedCategory(icon: "film.fill",              colorHex: "A855F7"),
        "movies":         ResolvedCategory(icon: "film.fill",              colorHex: "A855F7"),
        "music":          ResolvedCategory(icon: "music.note",             colorHex: "EC4899"),
        "games":          ResolvedCategory(icon: "gamecontroller.fill",    colorHex: "A855F7"),
        "streaming":      ResolvedCategory(icon: "play.tv.fill",           colorHex: "A855F7"),
        "hobbies":        ResolvedCategory(icon: "star.fill",              colorHex: "F59E0B"),

        // Travel
        "travel":         ResolvedCategory(icon: "airplane",               colorHex: "06B6D4"),
        "vacation":       ResolvedCategory(icon: "sun.max.fill",           colorHex: "F59E0B"),
        "hotel":          ResolvedCategory(icon: "bed.double.fill",        colorHex: "06B6D4"),
        "flights":        ResolvedCategory(icon: "airplane",               colorHex: "06B6D4"),

        // Finance
        "insurance":      ResolvedCategory(icon: "shield.fill",            colorHex: "14B8A6"),
        "taxes":          ResolvedCategory(icon: "building.columns.fill",  colorHex: "64748B"),
        "tax":            ResolvedCategory(icon: "building.columns.fill",  colorHex: "64748B"),
        "savings":        ResolvedCategory(icon: "banknote.fill",          colorHex: "10B981"),
        "investment":     ResolvedCategory(icon: "chart.line.uptrend.xyaxis", colorHex: "22C55E"),
        "investments":    ResolvedCategory(icon: "chart.line.uptrend.xyaxis", colorHex: "22C55E"),
        "loan":           ResolvedCategory(icon: "creditcard.fill",        colorHex: "EF4444"),
        "debt":           ResolvedCategory(icon: "creditcard.fill",        colorHex: "EF4444"),

        // Subscriptions
        "subscriptions":  ResolvedCategory(icon: "arrow.triangle.2.circlepath", colorHex: "8B5CF6"),
        "subscription":   ResolvedCategory(icon: "arrow.triangle.2.circlepath", colorHex: "8B5CF6"),

        // Personal
        "personal":       ResolvedCategory(icon: "person.fill",            colorHex: "6366F1"),
        "gift":           ResolvedCategory(icon: "gift.fill",              colorHex: "EC4899"),
        "gifts":          ResolvedCategory(icon: "gift.fill",              colorHex: "EC4899"),
        "donation":       ResolvedCategory(icon: "heart.circle.fill",      colorHex: "EF4444"),
        "donations":      ResolvedCategory(icon: "heart.circle.fill",      colorHex: "EF4444"),
        "charity":        ResolvedCategory(icon: "heart.circle.fill",      colorHex: "EF4444"),
        "pets":           ResolvedCategory(icon: "pawprint.fill",          colorHex: "F97316"),
        "pet":            ResolvedCategory(icon: "pawprint.fill",          colorHex: "F97316"),
        "kids":           ResolvedCategory(icon: "figure.2.and.child.holdinghands", colorHex: "F59E0B"),
        "childcare":      ResolvedCategory(icon: "figure.2.and.child.holdinghands", colorHex: "F59E0B"),
        "beauty":         ResolvedCategory(icon: "sparkles",               colorHex: "EC4899"),

        // Income
        "salary":         ResolvedCategory(icon: "banknote.fill",          colorHex: "22C55E"),
        "income":         ResolvedCategory(icon: "arrow.down.circle.fill", colorHex: "22C55E"),
        "freelance":      ResolvedCategory(icon: "laptopcomputer",         colorHex: "10B981"),
        "side hustle":    ResolvedCategory(icon: "briefcase.fill",         colorHex: "10B981"),
        "bonus":          ResolvedCategory(icon: "star.circle.fill",       colorHex: "F59E0B"),
        "refund":         ResolvedCategory(icon: "arrow.uturn.left.circle.fill", colorHex: "06B6D4"),

        // Other
        "other":          ResolvedCategory(icon: "ellipsis.circle.fill",   colorHex: "64748B"),
        "miscellaneous":  ResolvedCategory(icon: "ellipsis.circle.fill",   colorHex: "64748B"),
        "misc":           ResolvedCategory(icon: "ellipsis.circle.fill",   colorHex: "64748B"),
        "uncategorized":  ResolvedCategory(icon: "questionmark.circle.fill", colorHex: "9CA3AF"),
    ]

    /// Keyword-based fallback: if the category name *contains* a keyword
    private static let categoryKeywords: [(String, ResolvedCategory)] = [
        ("grocer",     ResolvedCategory(icon: "cart.fill",             colorHex: "22C55E")),
        ("food",       ResolvedCategory(icon: "fork.knife",            colorHex: "F97316")),
        ("eat",        ResolvedCategory(icon: "fork.knife",            colorHex: "F97316")),
        ("dine",       ResolvedCategory(icon: "fork.knife",            colorHex: "F97316")),
        ("restaurant", ResolvedCategory(icon: "fork.knife",            colorHex: "F97316")),
        ("coffee",     ResolvedCategory(icon: "cup.and.saucer.fill",   colorHex: "92400E")),
        ("transport",  ResolvedCategory(icon: "bus.fill",              colorHex: "3B82F6")),
        ("car",        ResolvedCategory(icon: "car.fill",              colorHex: "3B82F6")),
        ("rent",       ResolvedCategory(icon: "house.fill",            colorHex: "8B5CF6")),
        ("bill",       ResolvedCategory(icon: "doc.text.fill",         colorHex: "F59E0B")),
        ("shop",       ResolvedCategory(icon: "bag.fill",              colorHex: "EC4899")),
        ("cloth",      ResolvedCategory(icon: "tshirt.fill",           colorHex: "EC4899")),
        ("health",     ResolvedCategory(icon: "heart.fill",            colorHex: "EF4444")),
        ("medic",      ResolvedCategory(icon: "cross.case.fill",       colorHex: "EF4444")),
        ("pharm",      ResolvedCategory(icon: "pills.fill",            colorHex: "EF4444")),
        ("educ",       ResolvedCategory(icon: "graduationcap.fill",    colorHex: "6366F1")),
        ("school",     ResolvedCategory(icon: "graduationcap.fill",    colorHex: "6366F1")),
        ("book",       ResolvedCategory(icon: "book.fill",             colorHex: "8B5CF6")),
        ("entertain",  ResolvedCategory(icon: "film.fill",             colorHex: "A855F7")),
        ("movie",      ResolvedCategory(icon: "film.fill",             colorHex: "A855F7")),
        ("travel",     ResolvedCategory(icon: "airplane",              colorHex: "06B6D4")),
        ("flight",     ResolvedCategory(icon: "airplane",              colorHex: "06B6D4")),
        ("hotel",      ResolvedCategory(icon: "bed.double.fill",       colorHex: "06B6D4")),
        ("insur",      ResolvedCategory(icon: "shield.fill",           colorHex: "14B8A6")),
        ("tax",        ResolvedCategory(icon: "building.columns.fill", colorHex: "64748B")),
        ("subscri",    ResolvedCategory(icon: "arrow.triangle.2.circlepath", colorHex: "8B5CF6")),
        ("gift",       ResolvedCategory(icon: "gift.fill",             colorHex: "EC4899")),
        ("pet",        ResolvedCategory(icon: "pawprint.fill",         colorHex: "F97316")),
        ("invest",     ResolvedCategory(icon: "chart.line.uptrend.xyaxis", colorHex: "22C55E")),
        ("salar",      ResolvedCategory(icon: "banknote.fill",         colorHex: "22C55E")),
        ("freelan",    ResolvedCategory(icon: "laptopcomputer",        colorHex: "10B981")),
    ]
}

// MARK: - Import Execution

extension ImportCSVSheet {

    private func performImport() {
        importError = nil

        // Build category map from existing categories
        var categoryMap: [String: BudgetCategory] = [:]
        do {
            let catDescriptor = FetchDescriptor<BudgetCategory>()
            let freshCategories = try modelContext.fetch(catDescriptor)
            for cat in freshCategories {
                categoryMap[cat.name.lowercased()] = cat
            }
        } catch {
            for cat in existingCategories {
                categoryMap[cat.name.lowercased()] = cat
            }
        }

        // Create selected new categories
        for name in categoriesToAdd {
            let resolved = Self.resolveCategory(name)
            let newCat = BudgetCategory(
                name: name,
                icon: resolved.icon,
                colorHex: resolved.colorHex,
                budgetAmount: 0,
                isExpenseCategory: true,
                sortOrder: existingCategories.count + categoryMap.count
            )
            modelContext.insert(newCat)
            categoryMap[name.lowercased()] = newCat
        }

        // If Replace mode — clear relationships then delete (all in one transaction before save)
        if importMode == .replace {
            do {
                let descriptor = FetchDescriptor<Transaction>()
                let all = try modelContext.fetch(descriptor)
                // Break self-referential relationships to avoid constraint violations
                for tx in all {
                    tx.splitParent = nil
                    tx.splitChildren = []
                }
                for tx in all {
                    modelContext.delete(tx)
                }
            } catch {
                importError = "Failed to delete existing transactions: \(error.localizedDescription)"
                withAnimation(CentmondTheme.Motion.default) { step = .preview }
                return
            }
        }

        // Insert new transactions
        var count = 0
        for row in parsedRows {
            let date = row.parsedDate ?? .now
            let matchedCategory = row.category.flatMap { categoryMap[$0.lowercased()] }

            let transaction = Transaction(
                date: date,
                payee: row.payee,
                amount: row.amount,
                isIncome: row.isIncome,
                status: .cleared,
                isReviewed: false,
                category: matchedCategory
            )
            modelContext.insert(transaction)
            count += 1
        }

        // Single atomic save — delete + insert happen together
        do {
            try modelContext.save()
            importedCount = count
            withAnimation(CentmondTheme.Motion.default) { step = .success }
        } catch {
            importError = "Failed to save: \(error.localizedDescription)"
            withAnimation(CentmondTheme.Motion.default) { step = .preview }
        }
    }
}
