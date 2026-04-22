import SwiftUI

struct ReportsView: View {
    @State private var openDefinition: ReportDefinition?

    var body: some View {
        ZStack {
            if let def = openDefinition {
                ReportDetailView(definition: def) {
                    openDefinition = nil
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                ReportsHubView { def in
                    openDefinition = def
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(CentmondTheme.Motion.layout, value: openDefinition)
    }
}
