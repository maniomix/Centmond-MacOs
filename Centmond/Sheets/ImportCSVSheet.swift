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
                        .font(CentmondTheme.Typography.captionSmall)
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
                            .font(CentmondTheme.Typography.captionMedium)
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
                let budgetMonthCount = Set(parsedRows.compactMap { row -> String? in
                    guard let d = row.parsedDate, row.monthlyBudget != nil else { return nil }
                    let c = Calendar.current
                    return "\(c.component(.year, from: d))-\(c.component(.month, from: d))"
                }).count

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: CentmondTheme.Spacing.xs) {
                        Image(systemName: "doc.text.fill")
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.accent)
                        Text(url.lastPathComponent)
                            .font(CentmondTheme.Typography.captionMedium)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        if budgetMonthCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "target")
                                    .font(CentmondTheme.Typography.micro.weight(.semibold))
                                Text("\(budgetMonthCount) monthly budget\(budgetMonthCount == 1 ? "" : "s")")
                                    .font(CentmondTheme.Typography.overline)
                            }
                            .foregroundStyle(CentmondTheme.Colors.projected)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(CentmondTheme.Colors.projected.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
                        }
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

            // Rows — capped height so the sheet doesn't stretch to the
            // full 1,356 rows. Without the cap the ScrollView reports its
            // ideal size as "all rows visible" and the sheet obligingly
            // grows to match, producing a 2,000pt-tall dialog. The cap
            // lets the scroll view fit ~8 rows comfortably; everything
            // below scrolls in place.
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
            .frame(maxHeight: 360)
        }
    }

    // Preview row layout:
    //   Date       Description                Category     Amount
    //   (92pt)     (flex)                     (120pt)      (110pt)
    //
    // Column widths sized to hold the realistic worst-case content in
    // ONE line without truncating on common values:
    //   - Date 92pt: fits "Nov 1 · 08:14" (the time-aware formatter
    //     added by the Time-column feature). Earlier 44pt width pushed
    //     every row with a time into a two-line wrap and broke the
    //     alignment across the whole list.
    //   - Category 120pt: fits "Bills & Utilities" and "Gifts & Donations".
    //     Earlier 68pt truncated to "Bills & Util…" / "Gifts & Do…".
    //   - Amount 110pt: fits European-locale amounts like "+4.091,74 US$"
    //     in monospaced digits. Earlier 80pt wrapped them to two lines.
    // `.lineLimit(1)` on every column + truncation-tail keeps row height
    // uniform even when a value just barely exceeds its column.
    private static let previewColWidths = (date: CGFloat(92), category: CGFloat(120), amount: CGFloat(110))

    private var previewHeaderRow: some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Text("Date").frame(width: Self.previewColWidths.date, alignment: .leading)
            Text("Description").frame(maxWidth: .infinity, alignment: .leading)
            Text("Category").frame(width: Self.previewColWidths.category, alignment: .leading)
            Text("Amount").frame(width: Self.previewColWidths.amount, alignment: .trailing)
        }
        .font(CentmondTheme.Typography.captionMedium)
        .foregroundStyle(CentmondTheme.Colors.textTertiary)
    }

    private func previewRow(_ row: CSVRow) -> some View {
        HStack(spacing: CentmondTheme.Spacing.sm) {
            Text(row.displayDate)
                .frame(width: Self.previewColWidths.date, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
            Text(row.payee)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)
            Text(row.category?.capitalized ?? "—")
                .frame(width: Self.previewColWidths.category, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
            Text(row.amountString)
                .frame(width: Self.previewColWidths.amount, alignment: .trailing)
                .lineLimit(1)
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
                        .font(CentmondTheme.Typography.captionSmall)
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
                            .font(CentmondTheme.Typography.subheading.weight(.medium))
                            .foregroundStyle(iconColor)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(CentmondTheme.Typography.heading2.weight(.regular))
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
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous)
                        .fill(isSelected ? CentmondTheme.Colors.accent : Color.clear)
                        .frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs, style: .continuous)
                        .strokeBorder(
                            isSelected ? CentmondTheme.Colors.accent : CentmondTheme.Colors.strokeDefault,
                            lineWidth: 1.5
                        )
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(CentmondTheme.Typography.overlineSemibold.weight(.bold))
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
                        .font(CentmondTheme.Typography.captionSmall.weight(.medium))
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
        let note: String?             // Captured from a dedicated note/memo column when distinct from the payee/description column
        let amount: Decimal
        let amountString: String
        let isIncome: Bool
        let category: String?
        let parsedDate: Date?
        let monthlyBudget: Decimal?   // Whole-month budget override pulled from "Monthly Budget" column
        let isSubscriptionHint: Bool  // "Subscription"/"Recurring" column → true (P9 integration)
        let memberName: String?       // "Member"/"Paid By" column — resolved to HouseholdMember at insert time (P8)
    }

    private struct ColumnMap {
        var dateIndex: Int?
        var amountIndex: Int?
        var payeeIndex: Int?
        var categoryIndex: Int?
        var typeIndex: Int?
        var noteIndex: Int?
        var monthlyBudgetIndex: Int?
        /// Optional Subscription/Recurring column — accepts yes/true/1/y
        /// as positive. Hint fans out to the post-import review flow so
        /// the user sees these merchants at the top of the Detected sheet.
        var subscriptionHintIndex: Int?
        /// Optional `Time`/`Hour` column — combined with the Date column
        /// to produce a Date with a real hour-of-day. Without this the
        /// imported transactions default to 00:00 (midnight), which
        /// triggers false "late-night" flags in the AI's emotional
        /// profile since the engine treats hour ∈ [22, 4] as late-night.
        var timeIndex: Int?

        /// Optional `Member`/`Household Member`/`Paid By` column — if the
        /// value matches a known HouseholdMember name (case-insensitive),
        /// the imported transaction is attributed to them. No auto-create —
        /// unmatched names fall through to the payee-learner.
        var memberIndex: Int?

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
        // Second formatter that includes the time when present in the
        // source CSV, so the preview row shows "Nov 1 · 08:14" and the
        // user can tell their Time column was picked up.
        let displayFormatterWithTime = DateFormatter()
        displayFormatterWithTime.dateFormat = "MMM d · HH:mm"
        displayFormatterWithTime.locale = Locale(identifier: "en_US")

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

            // Note column — captured separately when it's distinct from the
            // column we're already using for `payee`. Without this guard a CSV
            // with only a Note column would put the merchant in `payee` AND
            // duplicate the same string into `notes`.
            var note: String? = nil
            if let noteIdx = columnMap.noteIndex,
               noteIdx != columnMap.payeeIndex,
               noteIdx < fields.count {
                let raw = fields[noteIdx].trimmingCharacters(in: .whitespaces)
                if !raw.isEmpty { note = raw }
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

            // Optional time column (HH:MM / HH:MM:SS / 12-hour with am/pm).
            // If present and valid, combine with the parsed date so the
            // resulting Date carries a real hour-of-day. If absent or
            // unparseable, fall back to just the date (defaults to 00:00).
            var timeString: String = ""
            if let tIdx = columnMap.timeIndex, tIdx < fields.count {
                timeString = fields[tIdx].trimmingCharacters(in: .whitespaces)
            }

            let absAmount = abs(amount)
            let parsedDate = Self.parseDate(dateString, timeString: timeString)
            let prefix = isIncome ? "+" : "-"
            let formatted = prefix + (currencyFormatter.string(from: absAmount as NSDecimalNumber) ?? "\(absAmount)")
            let hasTime = !timeString.isEmpty && parsedDate != nil
            let formatterForRow = hasTime ? displayFormatterWithTime : displayFormatter
            let displayDate = parsedDate.map { formatterForRow.string(from: $0) } ?? dateString

            // Subscription hint — "yes"/"true"/"1"/"y" anywhere in the column
            // value means the user has pre-labelled this row as a recurring
            // charge. Used downstream to surface these merchants at the top
            // of the Detected sheet after import.
            var isSubscriptionHint = false
            if let sIdx = columnMap.subscriptionHintIndex, sIdx < fields.count {
                let raw = fields[sIdx].trimmingCharacters(in: .whitespaces).lowercased()
                let positives: Set<String> = ["yes", "y", "true", "1", "t", "subscription", "recurring"]
                if positives.contains(raw) { isSubscriptionHint = true }
            }

            // Member column (P8) — captured as a raw string; resolved to an
            // actual HouseholdMember at insert time so we can fall back to
            // the payee-learner without having to duplicate the lookup here.
            var memberName: String? = nil
            if let mIdx = columnMap.memberIndex, mIdx < fields.count {
                let raw = fields[mIdx].trimmingCharacters(in: .whitespaces)
                if !raw.isEmpty { memberName = raw }
            }

            // Monthly budget column — only non-empty values produce a value.
            var monthlyBudget: Decimal? = nil
            if let bIdx = columnMap.monthlyBudgetIndex, bIdx < fields.count {
                let rawBudget = fields[bIdx]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "$", with: "")
                    .replacingOccurrences(of: "€", with: "")
                    .replacingOccurrences(of: "£", with: "")
                    .replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: " ", with: "")
                if !rawBudget.isEmpty, let b = Decimal(string: rawBudget), b > 0 {
                    monthlyBudget = b
                }
            }

            rows.append(CSVRow(
                dateString: dateString,
                displayDate: displayDate,
                payee: payee,
                note: note,
                amount: absAmount,
                amountString: formatted,
                isIncome: isIncome,
                category: category,
                parsedDate: parsedDate,
                monthlyBudget: monthlyBudget,
                isSubscriptionHint: isSubscriptionHint,
                memberName: memberName
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
        let budgetAliases:  Set<String> = ["monthly budget","monthly_budget","month budget","month_budget","budget"]
        let subHintAliases: Set<String> = ["subscription","is_subscription","is subscription","recurring","is_recurring","is recurring"]
        let timeAliases:    Set<String> = ["time","hour","hours","transaction_time","transaction time","timestamp","tx_time"]
        let memberAliases:  Set<String> = ["member","household member","household_member","paid by","paid_by","paidby","person","owner","paidfor","paid for","paid_for"]

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
            else if map.monthlyBudgetIndex == nil && budgetAliases.contains(h) { map.monthlyBudgetIndex = index }
            else if map.subscriptionHintIndex == nil && subHintAliases.contains(h) { map.subscriptionHintIndex = index }
            else if map.timeIndex == nil && timeAliases.contains(h) { map.timeIndex = index }
            else if map.memberIndex == nil && memberAliases.contains(h) { map.memberIndex = index }
        }

        return map
    }

    /// Look up a HouseholdMember by name (case- and whitespace-insensitive)
    /// from the current store. No auto-create — unknown names return nil and
    /// the caller falls back to the payee-learner. (P8 CSV member column.)
    private func findHouseholdMember(named raw: String) -> HouseholdMember? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let descriptor = FetchDescriptor<HouseholdMember>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.first {
            $0.isActive && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }
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
            let f = DateFormatter()
            f.dateFormat = $0
            f.locale = Locale(identifier: "en_US_POSIX")
            // Explicit local timezone — default is already local, but pinning
            // prevents any accidental UTC-parsing surprise if the process
            // locale/tz changes under us.
            f.timeZone = TimeZone.current
            f.isLenient = false
            return f
        }
    }()

    /// Accepts `08:14`, `08:14:30`, `8:14 AM`, `8:14 PM`, `08:14:30 PM`.
    /// 24-hour patterns listed FIRST so CSVs using `HH:MM` (the common
    /// machine-readable format, and what the provided sample file uses)
    /// are matched unambiguously. Putting `h:mm a` first was subtly
    /// wrong: on some locales/macOS versions DateFormatter leniency
    /// could accept `"08:14"` as "hour 8 AM" with an implied AM, making
    /// `"13:00"` wrap to 1 AM. Reordering + explicit `isLenient = false`
    /// makes that impossible — `h:mm a` now strictly requires an AM/PM
    /// suffix and only runs after the numeric 24-hour patterns fail.
    private static let timeFormatters: [DateFormatter] = {
        ["HH:mm", "H:mm", "HH:mm:ss", "H:mm:ss", "h:mm a", "h:mm:ss a"].map {
            let f = DateFormatter()
            f.dateFormat = $0
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.isLenient = false
            return f
        }
    }()

    private static func parseDate(_ string: String, timeString: String = "") -> Date? {
        guard let date = dateFormatters.lazy.compactMap({ $0.date(from: string) }).first else {
            return nil
        }
        let trimmedTime = timeString.trimmingCharacters(in: .whitespaces)
        guard !trimmedTime.isEmpty else { return date }

        // Parse the time string into hour/minute components. A
        // DateFormatter on just the time string returns a Date on a
        // reference day (Jan 1 2000 etc.) — we only want its
        // hour/minute/second.
        guard let t = timeFormatters.lazy.compactMap({ $0.date(from: trimmedTime) }).first else {
            return date
        }

        // Combine via explicit components rather than
        // `Calendar.date(bySettingHour:minute:second:of:)`. The
        // `bySettingHour` API uses `matchingPolicy: .nextTime` by
        // default, which searches FORWARD for the next occurrence of
        // the requested time — if the parsed date happened to be at
        // noon (some DateFormatter quirks default to 12:00 instead of
        // 00:00 to sidestep DST edge cases), asking for hour 8 would
        // return TOMORROW's 8:00, not today's. That explains the
        // "time doesn't match" symptom. Explicit component combination
        // is unambiguous: take year/month/day from the date, take
        // hour/minute/second from the time, build a new Date.
        let cal = Calendar.current
        let dateParts = cal.dateComponents([.year, .month, .day], from: date)
        let timeParts = cal.dateComponents([.hour, .minute, .second], from: t)

        var combined = DateComponents()
        combined.year   = dateParts.year
        combined.month  = dateParts.month
        combined.day    = dateParts.day
        combined.hour   = timeParts.hour ?? 0
        combined.minute = timeParts.minute ?? 0
        combined.second = timeParts.second ?? 0
        combined.timeZone = TimeZone.current

        return cal.date(from: combined) ?? date
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

        // If Replace mode — clear relationships then delete (all in one transaction before save).
        //
        // CLOUD POLICY (intentional): "Replace" propagates the wipe to cloud.
        // CloudSyncCoordinator's willSave hook captures every deleted Transaction
        // (via TransactionDeletionService) and queues a cloud DELETE; the cascade
        // also drops linked ExpenseShares / HouseholdSettlements / GoalContributions,
        // which ride out via household snapshot push and the deletion queue. The
        // user's intent on "Replace" is "make the import the new source of truth"
        // — preserving cloud copies that aren't in the CSV would defeat that.
        if importMode == .replace {
            do {
                let descriptor = FetchDescriptor<Transaction>()
                let all = try modelContext.fetch(descriptor)
                TransactionDeletionService.delete(all, context: modelContext)
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
                notes: row.note,
                isIncome: row.isIncome,
                status: .cleared,
                isReviewed: false,
                category: matchedCategory
            )
            modelContext.insert(transaction)
            // Attribute household member: prefer an explicit CSV column match
            // (P8 — case-insensitive name lookup against existing members, no
            // auto-create). Fall back to the payee-learner if the column is
            // missing or the value doesn't resolve (P2).
            if let rawMember = row.memberName,
               let explicit = findHouseholdMember(named: rawMember) {
                transaction.householdMember = explicit
            } else {
                transaction.householdMember = HouseholdService.resolveMember(
                    forPayee: row.payee,
                    in: modelContext
                )
            }
            count += 1
        }

        // Single atomic save — delete + insert happen together.
        // NOTE: Monthly-budget upsert is deliberately deferred until after this
        // save. Issuing a FetchDescriptor against a different entity while a
        // large Transaction delete+insert is still pending was wiping the
        // pending transactions in practice (SwiftData flush behavior) and
        // also triggered AppKit layout recursion via @Query re-fires.
        do {
            try modelContext.save()
        } catch {
            importError = "Failed to save: \(error.localizedDescription)"
            withAnimation(CentmondTheme.Motion.default) { step = .preview }
            return
        }

        // After bulk insert, sweep new transactions against existing active
        // subscriptions in one pass. Same SwiftData-flush rule as the
        // monthly-budget block above — runs only after the import save has
        // committed.
        SubscriptionReconciliationService.reconcileAll(in: modelContext)

        // P9 integration: merchants the user pre-labelled as subscriptions in
        // the CSV get stashed for the Detected sheet, which boosts their
        // confidence + lowers the minimum-charge threshold so they surface on
        // the first review pass. Cleared by the sheet on load.
        let hintedKeys: Set<String> = Set(
            parsedRows
                .filter { $0.isSubscriptionHint }
                .map { Subscription.merchantKey(for: $0.payee) }
                .filter { !$0.isEmpty }
        )
        if !hintedKeys.isEmpty {
            SubscriptionDetector.stashHintedKeys(hintedKeys)
        }

        // Now that transactions are durably saved, upsert whole-month budgets
        // from the "Monthly Budget" column. One value per (year, month) —
        // first non-empty wins. Runs in its own save so a budget conflict
        // never rolls back the imported transactions.
        var monthlyBudgetsByKey: [String: (year: Int, month: Int, amount: Decimal)] = [:]
        let cal = Calendar.current
        for row in parsedRows {
            guard let date = row.parsedDate, let amt = row.monthlyBudget else { continue }
            let y = cal.component(.year, from: date)
            let m = cal.component(.month, from: date)
            let key = "\(y)-\(m)"
            if monthlyBudgetsByKey[key] == nil {
                monthlyBudgetsByKey[key] = (y, m, amt)
            }
        }
        if !monthlyBudgetsByKey.isEmpty {
            for (_, entry) in monthlyBudgetsByKey {
                let y = entry.year
                let m = entry.month
                let descriptor = FetchDescriptor<MonthlyTotalBudget>(
                    predicate: #Predicate { $0.year == y && $0.month == m }
                )
                if let existing = try? modelContext.fetch(descriptor).first {
                    existing.amount = entry.amount
                } else {
                    modelContext.insert(MonthlyTotalBudget(year: y, month: m, amount: entry.amount))
                }
            }
            modelContext.persist()
        }

        // Replace mode wipes transactions across every account, and
        // append mode may have inserted transactions tied to existing
        // accounts. Either way, resync stored balances after the bulk write.
        BalanceService.recalculateAll(in: modelContext)
        importedCount = count
        withAnimation(CentmondTheme.Motion.default) { step = .success }
    }
}
