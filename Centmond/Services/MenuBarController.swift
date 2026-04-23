import AppKit
import SwiftUI

/// Phase 1 — menu bar presence for Centmond.
///
/// Creates a status-bar item with three actions: Quick Add Transaction
/// (hotkey wired in Phase 2), Open Centmond, and Quit. Respects the
/// `menuBarEnabled` AppStorage toggle so the user can hide it.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var enabledObserver: NSObjectProtocol?

    override private init() {
        super.init()
    }

    func start() {
        apply(enabled: UserDefaults.standard.object(forKey: "menuBarEnabled") as? Bool ?? true)

        enabledObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let on = UserDefaults.standard.object(forKey: "menuBarEnabled") as? Bool ?? true
            Task { @MainActor in self.apply(enabled: on) }
        }
    }

    private func apply(enabled: Bool) {
        if enabled {
            installIfNeeded()
        } else {
            removeIfNeeded()
        }
    }

    private func installIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "dollarsign.circle", accessibilityDescription: "Centmond")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Centmond"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func removeIfNeeded() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let quickAdd = NSMenuItem(
            title: "Quick Add Transaction",
            action: #selector(handleQuickAdd),
            keyEquivalent: "a"
        )
        quickAdd.keyEquivalentModifierMask = [.command, .control]
        quickAdd.target = self
        menu.addItem(quickAdd)

        menu.addItem(.separator())

        let open = NSMenuItem(
            title: "Open Centmond",
            action: #selector(handleOpen),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Centmond",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func handleQuickAdd() {
        NotificationCenter.default.post(name: .quickAddRequested, object: nil)
    }

    @objc private func handleOpen() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    /// Fired by the menu bar item or the global hotkey (Phase 2) to
    /// present the Quick Add floating panel.
    static let quickAddRequested = Notification.Name("centmond.quickAddRequested")
}
