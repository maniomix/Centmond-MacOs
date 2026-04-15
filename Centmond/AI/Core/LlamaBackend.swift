import Foundation
import os
import LlamaSwift

// ============================================================
// MARK: - Llama Backend Actor
// ============================================================
//
// Dedicated background actor that owns ALL llama.cpp resources
// (model, context, sampler) and runs ALL inference off MainActor.
//
// This is the critical fix: llama_decode() is a blocking C call
// that monopolises CPU/GPU. By isolating it in its own actor,
// the MainActor (UI thread) is never blocked.
//
// AIManager (@MainActor) delegates to this actor and only
// receives status updates + token streams back.
//
// ============================================================

private let log = Logger(subsystem: "com.centmond.ai", category: "LlamaBackend")

actor LlamaBackend {
    static let shared = LlamaBackend()

    // MARK: - Llama Resources (owned by this actor, never touch MainActor)

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    // MARK: - Parameters

    private let maxTokens: Int32 = 768
    private let contextSize: UInt32 = 8192
    private let gpuLayers: Int32 = 99
    // Larger batch = far fewer GPU dispatches during prompt ingestion.
    // Prediction prompts are ~3-5k tokens; bumping 256 → 512 roughly
    // halves the prompt-eval wall time.
    private let batchSize: UInt32 = 512

    var isLoaded: Bool { model != nil && context != nil }

    // MARK: - Init

    private init() {
        llama_backend_init()
    }

    deinit {
        cleanup()
        llama_backend_free()
    }

    // ============================================================
    // MARK: - Model Loading (runs entirely off MainActor)
    // ============================================================

    func loadModel(path: String) -> Bool {
        if model != nil && context != nil { return true }

        // Clean up any partial state from a previous failed load
        if model != nil || context != nil || sampler != nil {
            cleanup()
        }

        log.info("LlamaBackend: loading model from \(path)")

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = gpuLayers

        guard let mdl = llama_model_load_from_file(path, mparams) else {
            log.error("LlamaBackend: llama_model_load_from_file returned nil")
            return false
        }

        model = mdl
        setupContext()

        // Validate context was created — if not, the model is unusable
        guard context != nil else {
            log.error("LlamaBackend: context creation failed, cleaning up model")
            cleanup()
            return false
        }

        setupSampler()

        log.info("LlamaBackend: model loaded successfully")
        return true
    }

    func unload() {
        cleanup()
    }

    private func cleanup() {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model   { llama_model_free(model) }
        sampler = nil
        context = nil
        model = nil
    }

    // MARK: - Context & Sampler

    private func setupContext() {
        guard let model else { return }

        var cparams = llama_context_default_params()
        cparams.n_ctx = contextSize
        cparams.n_batch = batchSize
        // 2 threads — leave CPU headroom for UI & window server
        cparams.n_threads = 2
        // Disable flash attention — AUTO causes EXC_BREAKPOINT crash
        // during Metal kernel compilation on some hardware configs
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED

        context = llama_init_from_model(model, cparams)

        if context == nil {
            log.error("LlamaBackend: failed to create context (n_ctx=\(self.contextSize), batch=\(self.batchSize))")
        }
    }

    private func setupSampler() {
        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)

        // top_k=20 instead of 40 — smaller candidate pool, faster sampling
        // at every token. Quality difference is negligible for our use case.
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        sampler = chain
    }

    // ============================================================
    // MARK: - Streaming Generation (runs entirely off MainActor)
    // ============================================================

    /// Generate tokens and stream them back via AsyncStream.
    /// This method runs on the LlamaBackend actor — completely
    /// off the main thread. The caller (AIManager) consumes
    /// the stream on a background task and batches UI updates.
    func generate(
        messages: [AIMessage],
        systemPrompt: String?
    ) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)

        guard let ctx = context, let mdl = model, let smp = sampler else {
            continuation.finish()
            return stream
        }

        let maxTok = maxTokens

        // Run generation in an unstructured task so the caller
        // doesn't have to await the entire generation.
        Task { [weak self] in
            guard let self else { continuation.finish(); return }
            await self.runGeneration(
                ctx: ctx, mdl: mdl, smp: smp,
                messages: messages, systemPrompt: systemPrompt,
                maxTokens: maxTok, continuation: continuation
            )
        }

        return stream
    }

    private func runGeneration(
        ctx: OpaquePointer,
        mdl: OpaquePointer,
        smp: UnsafeMutablePointer<llama_sampler>,
        messages: [AIMessage],
        systemPrompt: String?,
        maxTokens: Int32,
        continuation: AsyncStream<String>.Continuation
    ) async {
        let fullPrompt = Self.buildPrompt(
            model: mdl, messages: messages, systemPrompt: systemPrompt
        )

        let vocab = llama_model_get_vocab(mdl)
        var tokens = Self.tokenize(vocab: vocab, text: fullPrompt, addSpecial: true)

        guard !tokens.isEmpty else {
            continuation.finish()
            return
        }

        let ctxSize = Int(llama_n_ctx(ctx))
        let maxPromptTokens = ctxSize - Int(maxTokens) - 16
        if tokens.count > maxPromptTokens {
            log.info("Truncating prompt: \(tokens.count) -> \(maxPromptTokens) tokens")
            let keepStart = maxPromptTokens / 3
            let keepEnd = maxPromptTokens - keepStart
            tokens = Array(tokens.prefix(keepStart)) + Array(tokens.suffix(keepEnd))
        }

        llama_memory_clear(llama_get_memory(ctx), true)

        // ── Prompt ingestion ──
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

            // Yield between batches — gives the compositor breathing room.
            // No sleep: prompt ingestion is the bottleneck for prediction
            // (3-5k tokens), and the cooperative yield is enough.
            await Task.yield()
        }

        // ── Token generation ──
        let eosToken = llama_vocab_eos(vocab)

        for i in 0..<maxTokens {
            if Task.isCancelled { break }

            let tokenId = llama_sampler_sample(smp, ctx, -1)
            if tokenId == eosToken { break }

            let piece = Self.tokenToPiece(vocab: vocab, token: tokenId)
            if !piece.isEmpty {
                if piece.contains("<|turn|>") || piece.contains("<|turn>")
                    || piece.contains("<end_of_turn>") || piece.contains("<start_of_turn>") {
                    break
                }
                continuation.yield(piece)
            }

            var nextToken = tokenId
            let singleBatch = llama_batch_get_one(&nextToken, 1)
            if llama_decode(ctx, singleBatch) != 0 {
                log.error("llama_decode failed during generation")
                break
            }

            // Every 6 tokens, yield so the window server can composite frames.
            // Was every 3 with a 1ms sleep — this halves the cooperative
            // overhead during generation without starving the UI.
            if i % 6 == 5 {
                await Task.yield()
            }
        }

        continuation.finish()
    }

    // ============================================================
    // MARK: - Prompt Building & Tokenization (pure functions)
    // ============================================================

    static func buildPrompt(
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

    static func tokenize(
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

    static func tokenToPiece(vocab: OpaquePointer?, token: llama_token) -> String {
        guard let vocab else { return "" }

        var buf = [CChar](repeating: 0, count: 128)
        let n = llama_token_to_piece(vocab, token, &buf, 128, 0, true)
        if n <= 0 { return "" }
        return String(cString: Array(buf.prefix(Int(n))) + [0])
    }
}
