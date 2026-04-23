import Foundation

/// Filesystem-level SwiftData store nuke. Sidesteps every SwiftData /
/// Core Data accessor so it can never fault on a tombstoned row.
///
/// Usage: set the pending flag via `requestNukeOnNextLaunch()`, then
/// terminate the app. On the next launch, `runIfRequested()` (called
/// before `ModelContainer` is created) deletes the store + its WAL / SHM
/// siblings. The container then initializes against a blank store.
///
/// This exists because the in-process `wipeAllData` path still routes
/// through `context.save()`, which walks every pending change — a single
/// tombstoned `BudgetCategory` reference in a RecurringTransaction is
/// enough to kill the save and leave the user stuck.
enum StoreNuke {
    private static let pendingKey = "pendingStoreNuke_v1"

    /// Called from `Settings → Erase All Data`. Writes the flag and asks
    /// the caller to terminate the app; the next launch picks it up.
    static func requestNukeOnNextLaunch() {
        UserDefaults.standard.set(true, forKey: pendingKey)
        UserDefaults.standard.synchronize()
    }

    /// Called at `@main` initialization, BEFORE the ModelContainer is
    /// created. If the flag is set, delete every file in the default
    /// SwiftData store directory that matches the `default.store*`
    /// pattern, then clear companion `UserDefaults`.
    static func runIfRequested() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: pendingKey) else { return }
        defaults.removeObject(forKey: pendingKey)

        deleteStoreFiles()
        clearCompanionDefaults()
    }

    private static func deleteStoreFiles() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }

        // SwiftData default store lives under
        // ~/Library/Application Support/<bundle-id>/default.store
        // and writes WAL + SHM siblings alongside it. Wipe all three.
        let bundleID = Bundle.main.bundleIdentifier ?? "Centmond"
        let appDir = appSupport.appendingPathComponent(bundleID, isDirectory: true)

        // Try both the bundle-id subfolder and the Application Support
        // root — SwiftData versions have shipped both layouts.
        let searchRoots: [URL] = [appDir, appSupport]

        for root in searchRoots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }

            for url in entries where url.lastPathComponent.hasPrefix("default.store") {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func clearCompanionDefaults() {
        let d = UserDefaults.standard
        d.set(false, forKey: "hasCompletedOnboarding")
        d.set(false, forKey: "appLockEnabled")
        d.set("", forKey: "appPasscode")
        // Reset one-shot sweep / repair guards so the fresh store doesn't
        // inherit flags from the dead one.
        d.removeObject(forKey: "didPurgeOrphanRecurrings_2026_04_22")
    }
}
