import Foundation
import os
import LlamaSwift

// ============================================================
// MARK: - AI Manager
// ============================================================
//
// On-device LLM inference powered by Gemma 4 E4B via llama.cpp.
//
// Runs entirely on-device -- no data leaves the Mac.
// Uses the GGUF quantized model stored in Application Support.
//
// macOS port: fixed M4 16GB params (no adaptive tiers needed),
// @Observable instead of ObservableObject.
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

    // MARK: - State

    var status: AIModelStatus = .notLoaded
    var isGenerating: Bool = false

    // MARK: - Private State

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    @ObservationIgnored private var generationTask: Task<Void, Never>?

    // MARK: - M4 16GB Parameters

    private let maxTokens: Int32 = 2048
    private let contextSize: UInt32 = 8192
    private let gpuLayers: Int32 = 99
    private let batchSize: UInt32 = 512

    // MARK: - Model Paths

    static var modelDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("AIModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let modelFilename = "gemma-4-E4B-it-Q6_K.gguf"

    static var modelURL: URL {
        modelDirectory.appendingPathComponent(modelFilename)
    }

    static var resolvedModelURL: URL {
        modelURL
    }

    var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: Self.resolvedModelURL.path)
    }

    // MARK: - Init / Deinit

    private init() {
        llama_backend_init()
    }

    deinit {
        generationTask?.cancel()
        llama_backend_free()
    }

    // ============================================================
    // MARK: - Model Loading
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

        if model != nil {
            status = .ready
            return
        }

        status = .loading
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: modelPath)[.size] as? Int64) ?? 0
        log.info("Loading AI model (\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))...")
        log.info("M4 16GB -> gpu_layers=\(self.gpuLayers), ctx=\(self.contextSize), batch=\(self.batchSize)")

        let nGpuLayers = self.gpuLayers
        let path = modelPath

        Task.detached(priority: .userInitiated) {
            var mparams = llama_model_default_params()
            mparams.n_gpu_layers = nGpuLayers

            let mdl = llama_model_load_from_file(path, mparams)

            await MainActor.run { [weak self] in
                guard let self else { return }

                guard let mdl else {
                    self.status = .error("Failed to load model -- not enough memory or incompatible format")
                    log.error("llama_model_load_from_file returned nil for \(path)")
                    return
                }

                self.model = mdl
                self.setupContext()
                self.setupSampler()
                self.status = .ready
                log.info("AI model loaded successfully")
            }
        }
    }

    func unloadModel() {
        cancelGeneration()

        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model   { llama_model_free(model) }

        sampler = nil
        context = nil
        model = nil
        status = .notLoaded
    }

    // MARK: - Context & Sampler Setup

    private func setupContext() {
        guard let model else { return }

        var cparams = llama_context_default_params()
        cparams.n_ctx = contextSize
        cparams.n_batch = batchSize
        cparams.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1)))
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO

        context = llama_init_from_model(model, cparams)

        if context == nil {
            log.error("Failed to create context (n_ctx=\(self.contextSize), batch=\(self.batchSize))")
        }
    }

    private func setupSampler() {
        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)

        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        sampler = chain
    }

    // ============================================================
    // MARK: - Text Generation (Streaming)
    // ============================================================

    func stream(_ userMessage: String, systemPrompt: String? = nil) -> AsyncStream<String> {
        stream(messages: [AIMessage(role: .user, content: userMessage)], systemPrompt: systemPrompt)
    }

    func stream(messages: [AIMessage], systemPrompt: String? = nil) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)

        let ctx = self.context
        let mdl = self.model
        let smp = self.sampler
        let maxTok = self.maxTokens

        guard let ctx, let mdl, let smp else {
            continuation.finish()
            return stream
        }

        self.isGenerating = true
        self.status = .generating

        generationTask = Task.detached(priority: .userInitiated) {
            await AIManager.runGeneration(
                ctx: ctx, mdl: mdl, smp: smp,
                messages: messages, systemPrompt: systemPrompt,
                maxTokens: maxTok, continuation: continuation
            )
            await MainActor.run { [weak self] in
                self?.isGenerating = false
                self?.status = .ready
            }
        }

        let task = generationTask
        continuation.onTermination = { _ in
            task?.cancel()
        }

        return stream
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
    // MARK: - Chat Template & Tokenization
    // ============================================================

    private static func runGeneration(
        ctx: OpaquePointer,
        mdl: OpaquePointer,
        smp: UnsafeMutablePointer<llama_sampler>,
        messages: [AIMessage],
        systemPrompt: String?,
        maxTokens: Int32,
        continuation: AsyncStream<String>.Continuation
    ) async {
        let fullPrompt = buildPromptStatic(
            model: mdl, messages: messages, systemPrompt: systemPrompt
        )

        let vocab = llama_model_get_vocab(mdl)
        var tokens = tokenizeStatic(vocab: vocab, text: fullPrompt, addSpecial: true)

        guard !tokens.isEmpty else {
            continuation.finish()
            return
        }

        let ctxSize = Int(llama_n_ctx(ctx))
        let maxPromptTokens = ctxSize - Int(maxTokens) - 16
        if tokens.count > maxPromptTokens {
            log.info("Truncating prompt: \(tokens.count) -> \(maxPromptTokens) tokens (ctx=\(ctxSize))")
            let keepStart = maxPromptTokens / 3
            let keepEnd = maxPromptTokens - keepStart
            tokens = Array(tokens.prefix(keepStart)) + Array(tokens.suffix(keepEnd))
        }

        llama_memory_clear(llama_get_memory(ctx), true)

        let batchLimit = Int(llama_n_batch(ctx))
        var offset = 0
        while offset < tokens.count {
            if Task.isCancelled { continuation.finish(); return }
            let remaining = tokens.count - offset
            let chunkSize = min(remaining, batchLimit)
            var chunk = Array(tokens[offset..<(offset + chunkSize)])
            let batch = chunk.withUnsafeMutableBufferPointer { buf in
                llama_batch_get_one(buf.baseAddress!, Int32(chunkSize))
            }
            if llama_decode(ctx, batch) != 0 {
                log.error("llama_decode failed at offset \(offset)/\(tokens.count)")
                continuation.finish()
                return
            }
            offset += chunkSize
        }

        let eosToken = llama_vocab_eos(vocab)

        for _ in 0..<maxTokens {
            if Task.isCancelled { break }

            let tokenId = llama_sampler_sample(smp, ctx, -1)
            if tokenId == eosToken { break }

            let piece = tokenToPieceStatic(vocab: vocab, token: tokenId)
            if !piece.isEmpty {
                if piece.contains("<|turn|>") || piece.contains("<|turn>")
                    || piece.contains("<end_of_turn>") || piece.contains("<start_of_turn>") {
                    break
                }
                continuation.yield(piece)
            }

            var nextToken = tokenId
            let batch = llama_batch_get_one(&nextToken, 1)
            if llama_decode(ctx, batch) != 0 {
                log.error("llama_decode failed during generation")
                break
            }
        }

        continuation.finish()
    }

    /// Build a multi-turn formatted prompt using Gemma 4's chat template.
    /// Gemma 4 uses `<|turn>role` / `<|turn|>` (different from Gemma 3's `<start_of_turn>` / `<end_of_turn>`).
    static func buildPromptStatic(
        model: OpaquePointer,
        messages: [AIMessage],
        systemPrompt: String?
    ) -> String {
        var prompt = ""
        if let sys = systemPrompt, !sys.isEmpty {
            prompt += "<|turn>system\n\(sys)<|turn|>\n"
        }

        for message in messages {
            switch message.role {
            case .user:
                prompt += "<|turn>user\n\(message.content)<|turn|>\n"
            case .assistant:
                prompt += "<|turn>model\n\(message.content)<|turn|>\n"
            case .system:
                prompt += "<|turn>system\n\(message.content)<|turn|>\n"
            }
        }

        prompt += "<|turn>model\n"
        return prompt
    }

    static func tokenizeStatic(
        vocab: OpaquePointer?,
        text: String,
        addSpecial: Bool
    ) -> [llama_token] {
        guard let vocab else { return [] }

        let utf8 = text.utf8CString
        let maxTokens = Int32(utf8.count) + 16

        var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
        let nTokens = utf8.withUnsafeBufferPointer { buf in
            llama_tokenize(vocab, buf.baseAddress, Int32(text.utf8.count), &tokens, maxTokens, addSpecial, true)
        }

        if nTokens < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-nTokens))
            let n2 = utf8.withUnsafeBufferPointer { buf in
                llama_tokenize(vocab, buf.baseAddress, Int32(text.utf8.count), &tokens, -nTokens, addSpecial, true)
            }
            if n2 < 0 { return [] }
            return Array(tokens.prefix(Int(n2)))
        }

        return Array(tokens.prefix(Int(nTokens)))
    }

    static func tokenToPieceStatic(vocab: OpaquePointer?, token: llama_token) -> String {
        guard let vocab else { return "" }

        var buf = [CChar](repeating: 0, count: 128)
        let n = llama_token_to_piece(vocab, token, &buf, 128, 0, true)
        if n <= 0 { return "" }
        return String(cString: Array(buf.prefix(Int(n))) + [0])
    }

    // ============================================================
    // MARK: - Model File Management
    // ============================================================

    func importModel(from sourceURL: URL) throws {
        let dest = Self.modelURL
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        log.info("AI model imported to \(dest.lastPathComponent)")
    }

    func deleteModel() {
        unloadModel()
        try? FileManager.default.removeItem(at: Self.modelURL)
        log.info("AI model deleted")
    }

    var modelFileSize: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.modelURL.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    // ============================================================
    // MARK: - Model Download
    // ============================================================

    nonisolated static let defaultDownloadURL = "https://huggingface.co/Dextermitur/MacOs-Gemma-Centmond/resolve/main/gemma-4-E4B-it-Q6_K.gguf"
    nonisolated static let modelDownloadSizeLabel = "~7 GB"
    nonisolated static let estimatedModelBytes: Int64 = 7_070_000_000

    private static let downloadURLKey = "ai.download_url"

    var downloadURL: String {
        get { UserDefaults.standard.string(forKey: Self.downloadURLKey) ?? Self.defaultDownloadURL }
        set { UserDefaults.standard.set(newValue, forKey: Self.downloadURLKey) }
    }

    private var downloadTask: URLSessionDownloadTask?
    private var downloadID: UUID?

    var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    private static func isValidGGUF(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            log.error("isValidGGUF: cannot open file handle for \(url.path)")
            // Fallback: if file exists and is large enough, assume valid
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

    func downloadModel() {
        guard !isDownloading else { return }

        guard let url = URL(string: downloadURL) else {
            status = .error("Invalid download URL")
            return
        }

        let thisDownloadID = UUID()
        downloadID = thisDownloadID

        status = .downloading(progress: 0, downloadedBytes: 0)
        log.info("Starting model download from \(url)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600

        let delegate = DownloadDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)

        delegate.onProgress = { [weak self] bytesWritten, totalExpected in
            Task { @MainActor in
                guard let self, self.downloadID == thisDownloadID else { return }
                let progress: Double
                if totalExpected > 0 {
                    progress = Double(bytesWritten) / Double(totalExpected)
                } else {
                    progress = min(0.99, Double(bytesWritten) / Double(Self.estimatedModelBytes))
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
                    let dest = Self.modelURL
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    log.info("Model saved (\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))")
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
