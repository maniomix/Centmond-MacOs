import Foundation
import os.log

// ============================================================
// MARK: - Secure Logger (macOS)
// ============================================================
// Same API as iOS so cloud-side code can use a single name.
// Strips sensitive data (UUIDs, emails, JWT tokens) in
// production; full text in development.
// ============================================================

enum SecureLogger {

    private static let subsystem = Bundle.main.bundleIdentifier ?? "mani.Centmond"
    private static let logger = Logger(subsystem: subsystem, category: "app")

    // MARK: - Public

    static func info(_ message: String) {
        logger.info("\(sanitize(message), privacy: .public)")
    }

    static func debug(_ message: String) {
        guard AppConfig.shared.environment.allowsVerboseLogging else { return }
        logger.debug("\(sanitize(message), privacy: .public)")
    }

    static func warning(_ message: String) {
        logger.warning("\(sanitize(message), privacy: .public)")
    }

    static func error(_ message: String, _ error: Error? = nil) {
        let full = error.map { "\(message) — \(sanitizeError($0))" } ?? message
        logger.error("\(sanitize(full), privacy: .public)")
    }

    static func security(_ message: String) {
        logger.notice("[SEC] \(sanitize(message), privacy: .public)")
    }

    // MARK: - Sanitization

    /// Redacts UUIDs, JWT-shaped tokens, and email addresses in production builds.
    private static func sanitize(_ s: String) -> String {
        guard !AppConfig.shared.environment.allowsVerboseLogging else { return s }
        var out = s
        // UUIDs → <uuid>
        out = out.replacingOccurrences(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            with: "<uuid>", options: .regularExpression)
        // JWT-shaped (3 base64 segments separated by .) → <jwt>
        out = out.replacingOccurrences(
            of: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
            with: "<jwt>", options: .regularExpression)
        // Emails → <email>
        out = out.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "<email>", options: .regularExpression)
        return out
    }

    private static func sanitizeError(_ error: Error) -> String {
        sanitize(String(describing: error))
    }
}
