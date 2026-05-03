import Foundation

/// Status of the AI model lifecycle. Extracted from AIManager.swift so
/// the iOS target — which excludes AIManager (llama backend is macOS-only
/// for now) — can still reference the enum from cross-platform call sites
/// like `AIPromptVersioning.updateHealth(from:)`.
enum AIModelStatus: Equatable {
    case notLoaded
    case loading
    case ready
    case error(String)
    case generating
    case downloading(progress: Double, downloadedBytes: Int64)
}
