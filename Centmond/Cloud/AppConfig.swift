import Foundation

// ============================================================
// MARK: - App Configuration (macOS)
// ============================================================
// Mirrors iOS's `AppConfig` so cloud-side code reads the same
// shape on both platforms. Values come from `Centmond.plist`,
// which is gitignored. Add the file to the macOS bundle's
// resources in Xcode (Build Phases → Copy Bundle Resources).
// ============================================================

enum AppEnvironment: String {
    case development
    case staging
    case production

    var allowsVerboseLogging: Bool { self != .production }
    var enforcesSecurity: Bool { self != .development }
    var showsDetailedErrors: Bool { self == .development }
}

struct AppConfig {

    // MARK: - Singleton

    static let shared: AppConfig = {
        guard let path = Bundle.main.path(forResource: "Centmond", ofType: "plist") ??
                         Bundle.main.path(forResource: "Supabase", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            #if DEBUG
            fatalError("⛔ Centmond.plist not found in app bundle. Add it via Xcode → Build Phases → Copy Bundle Resources.")
            #else
            return AppConfig(dict: [:])
            #endif
        }
        return AppConfig(dict: dict)
    }()

    // MARK: - Public

    let supabaseURL: String
    let supabaseAnonKey: String
    let googleClientID: String
    let environment: AppEnvironment

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    // MARK: - Init

    private init(dict: [String: Any]) {
        supabaseURL = dict["SUPABASE_URL"] as? String ?? ""
        supabaseAnonKey = dict["SUPABASE_ANON_KEY"] as? String ?? ""
        googleClientID = dict["GOOGLE_CLIENT_ID"] as? String ?? ""
        let envString = dict["ENVIRONMENT"] as? String ?? "production"
        environment = AppEnvironment(rawValue: envString) ?? .production
    }

    /// Call once on launch to surface misconfiguration early.
    @discardableResult
    func validate() -> Bool {
        var ok = true
        if supabaseURL.isEmpty {
            SecureLogger.error("Missing SUPABASE_URL in Centmond.plist")
            ok = false
        } else if !supabaseURL.hasPrefix("https://") {
            SecureLogger.warning("SUPABASE_URL should use HTTPS")
        }
        if supabaseAnonKey.isEmpty {
            SecureLogger.error("Missing SUPABASE_ANON_KEY in Centmond.plist")
            ok = false
        }
        return ok
    }
}
