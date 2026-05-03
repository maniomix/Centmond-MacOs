require 'xcodeproj'
project = Xcodeproj::Project.open('Centmond.xcodeproj')
ios = project.targets.find { |t| t.name == 'CentmondiOS' }

# Mac-only files. iOS gets a placeholder shell (IOSAppShell.swift) for now;
# Track B3-B6 will replace with native iOS views. AI features and report
# export are macOS-only in v1 (NSPanel/NSColor.controlBackgroundColor + llama
# desktop budget).
MAC_ONLY = %w[
  AI/Core/AIKeyboardShortcuts.swift
  AI/Core/AIManager.swift
  AI/Core/LlamaBackend.swift
  AI/Ingestion/AIReceiptScanner.swift
  AI/Intelligence/InsightEnricher.swift
  Reports/Export/CompositeExporter.swift
  Reports/Export/CompositeReportPDFBuilder.swift
  Reports/Export/CSVExporter.swift
  Reports/Export/PDFExporter.swift
  Reports/Export/ReportExporter.swift
  Reports/Export/ReportExportService.swift
  Reports/Export/ReportImageRenderer.swift
  Reports/Export/ReportShareService.swift
  Reports/Export/XLSXExporter.swift
  Reports/ReportScheduleService.swift
  Services/AppLockController.swift
  Services/MenuBarController.swift
  Services/NetWorthCSVExporter.swift
  Services/QuickAddHotkey.swift
  Services/QuickAddPanel.swift
  Sheets/ExportSheet.swift
  Sheets/ImportCSVSheet.swift
  Views/AI/AIActionCard.swift
  Views/AI/AIActivityDashboard.swift
  Views/AI/AIChatView.swift
  Views/AI/AIIngestionView.swift
  Views/AI/AIInsightBanner.swift
  Views/AI/AIInsightDashboard.swift
  Views/AI/AIMemoryView.swift
  Views/AI/AIModeSettingsView.swift
  Views/AI/AIOnboardingView.swift
  Views/AI/AIOptimizerView.swift
  Views/AI/AIPredictionView.swift
  Views/AI/AIProactiveView.swift
  Views/AI/AIReceiptScannerView.swift
  Views/AI/AIScenarioView.swift
  Views/AI/AIWorkflowView.swift
  Views/AI/ChatBubbleView.swift
  Views/AI/GroupedActionCard.swift
  Views/Dashboard/DashboardInsightStrip.swift
  Views/Dashboard/DashboardView.swift
  Views/Household/HouseholdView.swift
  Views/Insights/InsightsView.swift
  Views/QuickAdd/QuickAddFlowView.swift
  Views/Reports/ReportExportSheet.swift
  Views/Reports/ReportScheduleSheet.swift
  Views/Reports/ReportsView.swift
  Views/Settings/AIModelDownloadSheet.swift
  Views/Settings/AIModelPickerSheet.swift
  Views/Settings/InAppSettingsView.swift
  Views/Settings/SettingsView.swift
  Views/Shell/AppShell.swift
  Views/Shell/ContentRouter.swift
  Views/Shell/SidebarView.swift
  Views/Transactions/TransactionsView.swift
]

excluded = MAC_ONLY.map { |p| "$(SRCROOT)/Centmond/#{p}" }.join(' ')
ios.build_configurations.each do |c|
  c.build_settings['EXCLUDED_SOURCE_FILE_NAMES'] = excluded
end
project.save
puts "Excluded #{MAC_ONLY.length} files from iOS target"
