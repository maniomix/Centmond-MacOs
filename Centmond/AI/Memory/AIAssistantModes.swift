import Foundation

// ============================================================
// MARK: - AI Assistant Modes
// ============================================================
//
// Configurable assistant behavior modes that change how the AI
// interacts with the user — from cautious advisor to full
// autonomous CFO.
//
// Modes affect: trust defaults, proactivity, verbosity,
// auto-execution, confidence thresholds, optimization emphasis,
// proactive intensity, tone, and clarification behavior.
//
// macOS Centmond: @Observable instead of ObservableObject,
// removes @Published / Combine.
//
// ============================================================

// MARK: - Mode Behavior Sub-Types

/// How aggressively the AI generates proactive items.
enum ProactiveIntensity: String, Codable, CaseIterable {
    case none     = "none"
    case light    = "light"
    case moderate = "moderate"
    case high     = "high"

    var title: String {
        switch self {
        case .none:     return "Off"
        case .light:    return "Light"
        case .moderate: return "Moderate"
        case .high:     return "High"
        }
    }

    var minimumSeverity: Int {
        switch self {
        case .none:     return -1
        case .light:    return 1
        case .moderate: return 3
        case .high:     return 3
        }
    }

    var includesInfoItems: Bool {
        switch self {
        case .none, .light: return false
        case .moderate, .high: return true
        }
    }
}

/// How strongly the optimizer frames recommendations.
enum OptimizationEmphasis: String, Codable, CaseIterable {
    case optional   = "optional"
    case moderate   = "moderate"
    case strong     = "strong"

    var title: String {
        switch self {
        case .optional: return "Optional"
        case .moderate: return "Moderate"
        case .strong:   return "Strong"
        }
    }

    var prefix: String {
        switch self {
        case .optional: return "Consider:"
        case .moderate: return ""
        case .strong:   return "Action needed:"
        }
    }
}

// MARK: - Assistant Mode (full version — replaces stub in AITrustPolicy)

extension AssistantMode {

    var icon: String {
        switch self {
        case .advisor:   return "lightbulb.fill"
        case .assistant:  return "person.fill"
        case .autopilot:  return "bolt.fill"
        case .cfo:        return "briefcase.fill"
        }
    }

    var description: String {
        switch self {
        case .advisor:
            return "Suggests actions but never executes. Always asks for confirmation. Best for learning and careful control."
        case .assistant:
            return "Executes safe actions automatically (add transactions, analyze). Confirms risky actions (delete, large amounts)."
        case .autopilot:
            return "Executes most actions automatically. Only confirms destructive operations. Best for power users."
        case .cfo:
            return "Full autonomy. Proactively manages budgets, detects issues, suggests optimizations. Minimal interruptions."
        }
    }

    var descriptionFarsi: String {
        switch self {
        case .advisor:
            return "فقط پیشنهاد میده، هیچ‌وقت خودش اجرا نمیکنه. همیشه تأیید میگیره."
        case .assistant:
            return "کارهای امن رو خودکار انجام میده. برای کارهای حساس تأیید میگیره."
        case .autopilot:
            return "بیشتر کارها رو خودکار انجام میده. فقط برای حذف تأیید میگیره."
        case .cfo:
            return "استقلال کامل. خودش بودجه مدیریت میکنه و مشکلات رو شناسایی میکنه."
        }
    }

    var tagline: String {
        switch self {
        case .advisor:   return "You decide everything"
        case .assistant:  return "Safe actions auto-run"
        case .autopilot:  return "Minimal interruptions"
        case .cfo:        return "Full financial autopilot"
        }
    }

    var behaviorBullets: [String] {
        switch self {
        case .advisor:
            return [
                "Always asks before acting",
                "Detailed explanations",
                "No proactive alerts",
                "Gentle optimization suggestions"
            ]
        case .assistant:
            return [
                "Auto-runs safe actions (add, analyze)",
                "Asks for risky actions (delete, large amounts)",
                "Light proactive alerts",
                "Balanced recommendations"
            ]
        case .autopilot:
            return [
                "Auto-runs most actions",
                "Only asks for destructive ops",
                "Active proactive monitoring",
                "Direct, action-oriented"
            ]
        case .cfo:
            return [
                "Full autonomous execution",
                "Proactive issue detection",
                "Strong optimization emphasis",
                "Brief status updates only"
            ]
        }
    }

    // MARK: - Behavior Configuration

    var clarificationThreshold: Double {
        switch self {
        case .advisor:   return 0.7
        case .assistant:  return 0.5
        case .autopilot:  return 0.3
        case .cfo:        return 0.2
        }
    }

    var autoExecuteSafe: Bool {
        switch self {
        case .advisor:   return false
        case .assistant:  return true
        case .autopilot:  return true
        case .cfo:        return true
        }
    }

    var autoExecuteMedium: Bool {
        switch self {
        case .advisor:   return false
        case .assistant:  return false
        case .autopilot:  return true
        case .cfo:        return true
        }
    }

    var autoExecuteHigh: Bool {
        switch self {
        case .advisor:   return false
        case .assistant:  return false
        case .autopilot:  return false
        case .cfo:        return true
        }
    }

    var proactiveInsights: Bool {
        switch self {
        case .advisor:   return false
        case .assistant:  return true
        case .autopilot:  return true
        case .cfo:        return true
        }
    }

    var verboseResponses: Bool {
        switch self {
        case .advisor:   return true
        case .assistant:  return true
        case .autopilot:  return false
        case .cfo:        return false
        }
    }

    var largeAmountMultiplier: Double {
        switch self {
        case .advisor:   return 1.0
        case .assistant:  return 1.5
        case .autopilot:  return 3.0
        case .cfo:        return 5.0
        }
    }

    var proactiveIntensity: ProactiveIntensity {
        switch self {
        case .advisor:   return .none
        case .assistant:  return .light
        case .autopilot:  return .moderate
        case .cfo:        return .high
        }
    }

    var optimizationEmphasis: OptimizationEmphasis {
        switch self {
        case .advisor:   return .optional
        case .assistant:  return .moderate
        case .autopilot:  return .moderate
        case .cfo:        return .strong
        }
    }

    var autoShowOptimizations: Bool {
        switch self {
        case .advisor, .assistant:  return false
        case .autopilot, .cfo:      return true
        }
    }

    var maxCompactRecommendations: Int {
        switch self {
        case .advisor:   return 3
        case .assistant:  return 2
        case .autopilot:  return 2
        case .cfo:        return 1
        }
    }

    var skipsMediumClarification: Bool {
        switch self {
        case .advisor:   return false
        case .assistant:  return false
        case .autopilot:  return true
        case .cfo:        return true
        }
    }

    var promptModifier: String {
        switch self {
        case .advisor:
            return """
                MODE: Advisor — You are a cautious financial advisor. \
                NEVER auto-execute actions. Always present options and ask for confirmation. \
                Explain your reasoning thoroughly. Use phrases like "I suggest..." and "Would you like me to...?" \
                Provide detailed analysis with every recommendation. Be educational and transparent.
                """
        case .assistant:
            return """
                MODE: Assistant — You are a helpful finance assistant. \
                Execute safe actions (adding transactions, analyzing data) directly. \
                For budget changes, deletions, or large amounts, ask for confirmation first. \
                Be concise but friendly. Give clear explanations when asked.
                """
        case .autopilot:
            return """
                MODE: Autopilot — You are an efficient finance manager. \
                Execute actions quickly with minimal conversation. \
                Only pause for destructive operations (delete, cancel). \
                Skip pleasantries, be direct and action-oriented. \
                Focus on getting things done fast.
                """
        case .cfo:
            return """
                MODE: CFO — You are the user's personal Chief Financial Officer. \
                Take full ownership of their finances. Execute all actions autonomously. \
                Proactively identify issues, suggest optimizations, and implement improvements. \
                Communicate in brief status updates. Think strategically about their financial health. \
                Flag risks early, act on opportunities immediately.
                """
        }
    }
}

// MARK: - Mode Manager

@MainActor @Observable
final class AIAssistantModeManager {
    static let shared = AIAssistantModeManager()

    var currentMode: AssistantMode {
        didSet {
            UserDefaults.standard.set(currentMode.rawValue, forKey: modeKey)
            NotificationCenter.default.post(name: .aiModeDidChange, object: currentMode)
        }
    }

    private let modeKey = "ai.assistantMode"

    private init() {
        let saved = UserDefaults.standard.string(forKey: modeKey) ?? ""
        self.currentMode = AssistantMode(rawValue: saved) ?? .assistant
    }

    func shouldSkipClarification(confidence: Double) -> Bool {
        confidence >= currentMode.clarificationThreshold
    }

    var promptModifier: String {
        currentMode.promptModifier
    }

    var proactiveIntensity: ProactiveIntensity {
        currentMode.proactiveIntensity
    }

    var optimizationEmphasis: OptimizationEmphasis {
        currentMode.optimizationEmphasis
    }

    var isProactiveEnabled: Bool {
        currentMode.proactiveInsights
    }

    var modeIndicatorLabel: String {
        "\(currentMode.icon) \(currentMode.title)"
    }
}

// MARK: - Notification

extension Notification.Name {
    static let aiModeDidChange = Notification.Name("aiModeDidChange")
}
