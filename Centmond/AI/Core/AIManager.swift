import Foundation
import os
import LlamaSwift

// ============================================================
// MARK: - AI Manager
// ============================================================
//
// UI-facing layer for on-device AI inference.
//
// @MainActor @Observable — holds ONLY the state that SwiftUI
// needs to render (status, isGenerating, availableModels …).
//
// ALL llama.cpp work (model loading, context setup, decode,
// sampling) is delegated to LlamaBackend — a dedicated
// background actor that never touches the main thread.
//
// ============================================================

private let log = Logger(subsystem: "com.centmond.ai", category: "AIManager")

/// Status of the AI model lifecycle.
enum AIModelStatus: Equatable {
    case notLoaded
    case loading
    case ready
    case error(String)
    case generating
    case downloading(progress: Double, downloadedBytes: Int64)
}

@MainActor @Observable
final class AIManager {
    static let shared = AIManager()

    // MARK: - UI State (read by SwiftUI views)

    var status: AIModelStatus = .notLoaded
    var isGenerating: Bool = false
    var loadedModelFilename: String = ""
    var availableModels: [AIModelFile] = []

    // MARK: - Private

    private let backend = LlamaBackend.shared
    @ObservationIgnored private var generationTask: Task<Void, Never>?

    // MARK: - Model Paths

    static var modelDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("AIModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let activeModelKey = "ai.active_model_filename"

    static var modelFilename: String {
        UserDefaults.standard.string(forKey: activeModelKey) ?? "gemma-4-E4B-it-Q6_K.gguf"
    }

    static var modelURL: URL {
        modelDirectory.appendingPathComponent(modelFilename)
    }

    static var resolvedModelURL: URL {
        modelURL
    }

    var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: Self.resolvedModelURL.path)
    }

    // MARK: - Init

    private init() {
        refreshAvailableModels()
    }

    // MARK: - Available Models

    func refreshAvailableModels() {
        let dir = Self.modelDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            availableModels = []
            return
        }

        availableModels = files
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .compactMap { url -> AIModelFile? in
                let name = url.lastPathComponent
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
                return AIModelFile(filename: name, sizeBytes: size)
            }
            .sorted { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) }
    }

    // ============================================================
    // MARK: - Model Loading (delegates to LlamaBackend)
    // ============================================================

    func loadModel(from url: URL? = nil) {
        let modelURL = url ?? Self.resolvedModelURL
        let modelPath = modelURL.path

        guard FileManager.default.fileExists(atPath: modelPath) else {
            status = .error("Model file not found")
            log.error("AI model not found at \(modelPath)")
            return
        }

        guard Self.isValidGGUF(at: modelURL) else {
            let size = (try? FileManager.default.attributesOfItem(atPath: modelPath)[.size] as? Int64) ?? 0
            status = .error("Invalid model file (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
            log.error("Not a valid GGUF file at \(modelPath), size: \(size)")
            if modelPath == Self.modelURL.path {
                try? FileManager.default.removeItem(atPath: modelPath)
            }
            return
        }

        status = .loading
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: modelPath)[.size] as? Int64) ?? 0
        log.info("Loading AI model (\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))...")

        let path = modelPath
        let filename = Self.modelFilename

        // Model loading happens entirely on the LlamaBackend actor —
        // NOT on MainActor. Only the status update hops back.
        Task {
            let success = await backend.loadModel(path: path)

            // Back on MainActor (we're in a @MainActor class)
            if success {
                self.status = .ready
                self.loadedModelFilename = filename
                log.info("AI model loaded successfully: \(filename)")
            } else {
                self.status = .error("Failed to load model -- not enough memory or incompatible format")
                log.error("LlamaBackend failed to load model at \(path)")
            }
        }
    }

    func unloadModel() {
        cancelGeneration()
        Task { await backend.unload() }
        status = .notLoaded
    }

    func switchModel(to filename: String) {
        guard filename != Self.modelFilename else { return }
        log.info("Switching model: \(Self.modelFilename) → \(filename)")
        unloadModel()
        loadedModelFilename = ""
        UserDefaults.standard.set(filename, forKey: Self.activeModelKey)
        loadModel()
    }

    // ============================================================
    // MARK: - Text Generation (streaming via LlamaBackend)
    // ============================================================

    func stream(_ userMessage: String, systemPrompt: String? = nil) -> AsyncStream<String> {
        stream(messages: [AIMessage(role: .user, content: userMessage)], systemPrompt: systemPrompt)
    }

    func stream(messages: [AIMessage], systemPrompt: String? = nil) -> AsyncStream<String> {
        self.isGenerating = true
        self.status = .generating

        // Get the raw token stream from backend (runs off MainActor)
        let msgs = messages
        let sys = systemPrompt

        let (uiStream, uiContinuation) = AsyncStream.makeStream(of: String.self)

        generationTask = Task.detached(priority: .background) {
            let tokenStream = await LlamaBackend.shared.generate(
                messages: msgs, systemPrompt: sys
            )

            for await token in tokenStream {
                if Task.isCancelled { break }
                uiContinuation.yield(token)
            }
            uiContinuation.finish()

            await MainActor.run { [weak self] in
                self?.isGenerating = false
                self?.status = .ready
            }
        }

        let task = generationTask
        uiContinuation.onTermination = { _ in
            task?.cancel()
        }

        return uiStream
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        if case .generating = status { status = .ready }
    }

    // ============================================================
    // MARK: - Non-streaming convenience
    // ============================================================

    func generate(_ userMessage: String, systemPrompt: String? = nil) async -> String {
        var result = ""
        for await token in stream(userMessage, systemPrompt: systemPrompt) {
            result += token
        }
        return result
    }

    func generate(messages: [AIMessage], systemPrompt: String? = nil) async -> String {
        var result = ""
        for await token in stream(messages: messages, systemPrompt: systemPrompt) {
            result += token
        }
        return result
    }

    // ============================================================
    // MARK: - Static helpers (kept for backward compat with views)
    // ============================================================

    /// Build a multi-turn formatted prompt using Gemma 4's chat template.
    static func buildPromptStatic(
        model: OpaquePointer,
        messages: [AIMessage],
        systemPrompt: String?
    ) -> String {
        LlamaBackend.buildPrompt(model: model, messages: messages, systemPrompt: systemPrompt)
    }

    static func tokenizeStatic(
        vocab: OpaquePointer?,
        text: String,
        addSpecial: Bool
    ) -> [llama_token] {
        LlamaBackend.tokenize(vocab: vocab, text: text, addSpecial: addSpecial)
    }

    static func tokenToPieceStatic(vocab: OpaquePointer?, token: llama_token) -> String {
        LlamaBackend.tokenToPiece(vocab: vocab, token: token)
    }

    // ============================================================
    // MARK: - Model File Management
    // ============================================================

    func importModel(from sourceURL: URL) throws {
        let dest = Self.modelDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        UserDefaults.standard.set(dest.lastPathComponent, forKey: Self.activeModelKey)
        log.info("AI model imported: \(dest.lastPathComponent)")
        refreshAvailableModels()
    }

    func deleteModel() {
        let currentFile = Self.modelURL
        unloadModel()
        try? FileManager.default.removeItem(at: currentFile)
        log.info("AI model deleted: \(currentFile.lastPathComponent)")
        refreshAvailableModels()

        if let first = availableModels.first {
            UserDefaults.standard.set(first.filename, forKey: Self.activeModelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
        }
    }

    func deleteModel(filename: String) {
        let url = Self.modelDirectory.appendingPathComponent(filename)
        if filename == Self.modelFilename {
            deleteModel()
        } else {
            try? FileManager.default.removeItem(at: url)
            log.info("AI model deleted: \(filename)")
            refreshAvailableModels()
        }
    }

    var modelFileSize: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.modelURL.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    // ============================================================
    // MARK: - Model Download
    // ============================================================

    nonisolated static let defaultDownloadURL = "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q5_K_M.gguf"
    nonisolated static let modelDownloadSizeLabel = "~5.5 GB"
    nonisolated static let estimatedModelBytes: Int64 = 5_480_000_000

    private static let downloadURLKey = "ai.download_url"

    var downloadURL: String {
        get { UserDefaults.standard.string(forKey: Self.downloadURLKey) ?? Self.defaultDownloadURL }
        set { UserDefaults.standard.set(newValue, forKey: Self.downloadURLKey) }
    }

    var downloadingFilename: String = ""

    private var downloadTask: URLSessionDownloadTask?
    private var downloadID: UUID?

    var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    private static func isValidGGUF(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            log.error("isValidGGUF: cannot open file handle for \(url.path)")
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return size > 100_000_000
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4) else {
            log.error("isValidGGUF: cannot read header bytes")
            return false
        }
        let valid = header.count == 4 && header == Data([0x47, 0x47, 0x55, 0x46])
        if !valid {
            log.error("isValidGGUF: header mismatch: \(header.map { String(format: "0x%02X", $0) })")
        }
        return valid
    }

    func downloadModel(option: AIModelFile.DownloadOption? = nil) {
        guard !isDownloading else { return }

        let downloadOpt = option ?? AIModelFile.downloadCatalog.first!
        guard let url = URL(string: downloadOpt.url) else {
            status = .error("Invalid download URL")
            return
        }

        downloadingFilename = downloadOpt.filename

        let thisDownloadID = UUID()
        downloadID = thisDownloadID

        status = .downloading(progress: 0, downloadedBytes: 0)
        log.info("Starting model download: \(downloadOpt.filename) from \(url)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600

        let delegate = DownloadDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)

        let estimatedSize = downloadOpt.estimatedBytes

        delegate.onProgress = { [weak self] bytesWritten, totalExpected in
            Task { @MainActor in
                guard let self, self.downloadID == thisDownloadID else { return }
                let progress: Double
                if totalExpected > 0 && totalExpected != NSURLSessionTransferSizeUnknown {
                    progress = Double(bytesWritten) / Double(totalExpected)
                } else {
                    progress = min(0.99, Double(bytesWritten) / Double(estimatedSize))
                }
                self.status = .downloading(progress: progress, downloadedBytes: bytesWritten)
            }
        }

        delegate.onComplete = { [weak self] tempURL, httpStatus, error in
            Task { @MainActor in
                guard let self, self.downloadID == thisDownloadID else {
                    if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
                    return
                }
                self.downloadTask = nil
                self.downloadID = nil

                if let error {
                    self.status = .error("Download failed: \(error.localizedDescription)")
                    return
                }

                if let code = httpStatus, !(200...299).contains(code) {
                    self.status = .error("Download failed (HTTP \(code))")
                    if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
                    return
                }

                guard let tempURL else {
                    self.status = .error("Download failed -- no file")
                    return
                }

                let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0

                guard Self.isValidGGUF(at: tempURL) else {
                    self.status = .error("Invalid file -- not a GGUF model")
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }

                guard fileSize > 100_000_000 else {
                    self.status = .error("File too small (\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))")
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }

                do {
                    let targetFilename = self.downloadingFilename.isEmpty ? Self.modelFilename : self.downloadingFilename
                    let dest = Self.modelDirectory.appendingPathComponent(targetFilename)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    log.info("Model saved: \(targetFilename) (\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))")
                    UserDefaults.standard.set(targetFilename, forKey: Self.activeModelKey)
                    self.downloadingFilename = ""
                    self.refreshAvailableModels()
                    self.loadModel()
                } catch {
                    self.status = .error("Save failed: \(error.localizedDescription)")
                }
            }
        }

        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadID = nil
        downloadTask?.cancel()
        downloadTask = nil
        status = .notLoaded
        log.info("Model download cancelled")
    }
}

// ============================================================
// MARK: - URLSession Download Delegate
// ============================================================

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((_ bytesWritten: Int64, _ totalExpected: Int64) -> Void)?
    var onComplete: ((URL?, Int?, Error?) -> Void)?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gguf")
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            onComplete?(tmp, httpStatus, nil)
        } catch {
            onComplete?(nil, httpStatus, error)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            onComplete?(nil, nil, error)
        }
    }
}
