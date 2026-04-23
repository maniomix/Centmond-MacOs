import AppKit
import SwiftUI
import SwiftData

/// Phase 3 — shared pointer to the app's SwiftData container so the
/// floating Quick Add panel writes into the same store as the main
/// window. Populated once from `CentmondApp.init`.
enum QuickAddContainer {
    static var shared: ModelContainer?
}

/// Phase 3 — owns the borderless floating panel that hosts the Quick
/// Add flow. Listens to `.quickAddRequested` (fired by the menu bar
/// item and the global hotkey) and toggles the panel.
@MainActor
final class QuickAddCoordinator {
    static let shared = QuickAddCoordinator()

    private var panel: QuickAddPanel?
    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .quickAddRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.toggle() }
        }
    }

    func toggle() {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        present()
    }

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.centerOnActiveScreen()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func makePanel() -> QuickAddPanel {
        let root = QuickAddFlowView(onClose: { [weak self] in
            self?.panel?.close()
        })
        .modelContainer(QuickAddContainer.shared ?? {
            // Fallback — should never hit, but keeps the view
            // constructible if the coordinator is presented before the
            // app's container is wired up.
            let schema = Schema([Transaction.self])
            return try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }())

        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        return panel
    }
}

/// Panel subclass that can become key (so text fields work) even
/// though it's a non-activating floating panel.
final class QuickAddPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    func centerOnActiveScreen() {
        guard let screen = NSScreen.main else { center(); return }
        let frame = screen.visibleFrame
        let size = self.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + 80
        )
        setFrameOrigin(origin)
    }
}
