import Foundation
import SwiftData
import os.log

private let persistLog = Logger(subsystem: "com.centmond.persistence", category: "ModelContext")

extension ModelContext {

    /// Persist pending changes with explicit error logging.
    ///
    /// Replaces the `try? context.save()` idiom so save failures are visible
    /// in Console.app instead of being silently dropped. Callers that need to
    /// react to failure can inspect the returned `Bool`.
    ///
    /// Phase 2 polish (2026-04-23): any silent `try? save()` on a SwiftData
    /// context hides real data-integrity failures — corrupted shares, tombstoned
    /// refs, failed migrations. This wrapper preserves the "don't throw at the
    /// caller" ergonomics but routes failures to the unified persistence log.
    ///
    /// - Parameter origin: An optional label — the enclosing `#function` by
    ///   default. Included in the log line so failures are attributable.
    /// - Returns: `true` if the save succeeded, `false` if it threw.
    @discardableResult
    func persist(
        _ origin: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) -> Bool {
        do {
            try save()
            return true
        } catch {
            persistLog.error(
                "persist failed: \(origin, privacy: .public) at \(file, privacy: .public):\(line, privacy: .public) — \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
