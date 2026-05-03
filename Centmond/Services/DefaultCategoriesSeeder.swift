import Foundation
import SwiftData

// ============================================================
// MARK: - DefaultCategoriesSeeder
// ============================================================
//
// Seeds the standard expense categories (Groceries, Rent, Bills,
// Transport, Health, Education, Dining, Shopping, Other) on first
// launch and after a wipe. Mirrors the iOS hardcoded defaults from
// FullCategoryManager.swift so users see the same starter list on
// both platforms.
//
// Built-ins are marked `isBuiltIn = true` and are:
//   - Protected from delete in BudgetView and InspectorView.
//   - Excluded from cloud sync (iOS has its own hardcoded copy of
//     the same names; syncing would duplicate them on iOS).
//
// Idempotent by name match — running this twice is a no-op. Safe
// to call on every launch.
// ============================================================

@MainActor
enum DefaultCategoriesSeeder {

    /// Canonical list of seed categories. Order = display order
    /// (matches the iOS Plan Budget screen).
    static let defaults: [(name: String, icon: String, colorHex: String)] = [
        ("Groceries", "cart.fill",                 "22C55E"), // green
        ("Rent",      "house.fill",                "F59E0B"), // orange
        ("Bills",     "doc.text.fill",             "EF4444"), // red
        ("Transport", "car.fill",                  "3B82F6"), // blue
        ("Health",    "heart.fill",                "FF3B30"), // health red
        ("Education", "book.fill",                 "5AC8FA"), // teal
        ("Dining",    "fork.knife",                "FF2E55"), // dining pink
        ("Shopping",  "bag.fill",                  "B051DE"), // purple
        ("Other",     "questionmark.circle.fill", "8E8E93")   // gray
    ]

    /// Reconcile local categories with the canonical default set.
    ///
    /// Two passes:
    ///   1. **Promote** — any existing local category whose lowercased
    ///      name matches a default name gets `isBuiltIn = true` AND
    ///      its icon / colorHex refreshed to the canonical look. This
    ///      catches rows that pre-date the `isBuiltIn` field (which
    ///      defaulted to `false` on lightweight migration), so a user
    ///      who manually created "Groceries" before the seeder
    ///      existed will now see that row become un-deletable.
    ///   2. **Insert** — defaults whose name matches no existing row
    ///      get inserted fresh, marked `isBuiltIn = true`.
    ///
    /// Idempotent. Run once on launch.
    static func seedIfNeeded(context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []

        // Bucket locals by lowercased name so we can promote-or-insert
        // in one pass. Multiple rows with the same name (rare; result
        // of an old import) → first wins, others left untouched.
        var byLowerName: [String: BudgetCategory] = [:]
        for cat in existing where byLowerName[cat.name.lowercased()] == nil {
            byLowerName[cat.name.lowercased()] = cat
        }

        var promoted = 0
        var inserted = 0
        var keyBackfilled = 0

        // Pass 0: backfill `storageKey` on every existing row that's
        // empty (rows created before the field existed, or built-ins
        // promoted in a previous launch before storageKey landed).
        // Touch updatedAt only when we actually wrote a key — empty
        // assignments would trigger spurious cloud pushes.
        for cat in existing where cat.storageKey.isEmpty {
            cat.storageKey = BudgetCategory.canonicalStorageKey(
                name: cat.name, isBuiltIn: cat.isBuiltIn
            )
            cat.updatedAt = .now
            keyBackfilled += 1
        }

        for (index, def) in defaults.enumerated() {
            let key = def.name.lowercased()
            if let match = byLowerName[key] {
                // Pass 1: promote. Only touch fields if something
                // actually changed so we don't bump updatedAt for a
                // no-op (which would otherwise trigger a needless
                // cloud push on next cycle).
                var dirty = false
                if !match.isBuiltIn { match.isBuiltIn = true; dirty = true }
                if match.icon != def.icon { match.icon = def.icon; dirty = true }
                if match.colorHex != def.colorHex { match.colorHex = def.colorHex; dirty = true }
                // Promote also re-derives the storageKey since the
                // isBuiltIn flag flipping changes the prefix rule.
                let canonicalKey = BudgetCategory.canonicalStorageKey(
                    name: match.name, isBuiltIn: true
                )
                if match.storageKey != canonicalKey {
                    match.storageKey = canonicalKey
                    dirty = true
                }
                if dirty {
                    match.updatedAt = .now
                    promoted += 1
                }
            } else {
                // Pass 2: insert.
                let cat = BudgetCategory(
                    name: def.name,
                    icon: def.icon,
                    colorHex: def.colorHex,
                    budgetAmount: 0,
                    isExpenseCategory: true,
                    sortOrder: index,
                    isBuiltIn: true
                )
                context.insert(cat)
                inserted += 1
            }
        }

        if inserted > 0 || promoted > 0 || keyBackfilled > 0 {
            try? context.save()
            SecureLogger.info("Default categories: \(inserted) inserted, \(promoted) promoted to built-in, \(keyBackfilled) storage-key backfilled")
        }
    }
}
