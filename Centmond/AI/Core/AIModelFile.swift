import Foundation

/// Represents a GGUF model file with metadata for the model picker UI.
struct AIModelFile: Identifiable, Hashable {
    let filename: String
    let sizeBytes: Int64?

    var id: String { filename }

    /// Human-readable display name
    var displayName: String {
        let info = Self.knownModels[filename]
        return info?.displayName ?? filename.replacingOccurrences(of: ".gguf", with: "")
    }

    /// Quantization level extracted from filename
    var quantization: String {
        let info = Self.knownModels[filename]
        if let q = info?.quantization { return q }
        // Try to extract from filename pattern like "Q4_K_M" or "Q6_K"
        let name = filename.uppercased()
        let patterns = ["Q8_0", "Q6_K", "Q5_K_M", "Q5_K_S", "Q4_K_M", "Q4_K_S", "Q4_1", "Q4_0",
                        "IQ4_XS", "IQ4_NL", "IQ3_XXS", "IQ2_M", "Q3_K_M", "Q3_K_S"]
        return patterns.first { name.contains($0) } ?? "Unknown"
    }

    /// Speed tier (1-5, higher = faster)
    var speedTier: Int {
        Self.knownModels[filename]?.speedTier ?? quantizationSpeedTier
    }

    /// Quality tier (1-5, higher = better)
    var qualityTier: Int {
        Self.knownModels[filename]?.qualityTier ?? quantizationQualityTier
    }

    /// Speed label
    var speedLabel: String {
        switch speedTier {
        case 1: return "Very Slow"
        case 2: return "Slow"
        case 3: return "Moderate"
        case 4: return "Fast"
        case 5: return "Very Fast"
        default: return "Unknown"
        }
    }

    /// Quality label
    var qualityLabel: String {
        switch qualityTier {
        case 1: return "Low"
        case 2: return "Fair"
        case 3: return "Good"
        case 4: return "Very Good"
        case 5: return "Excellent"
        default: return "Unknown"
        }
    }

    /// Formatted file size
    var formattedSize: String {
        guard let size = sizeBytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Description for info box
    var description: String {
        Self.knownModels[filename]?.description ?? "Custom GGUF model — \(quantization) quantization"
    }

    /// Recommendation tag
    var recommendation: Recommendation? {
        Self.knownModels[filename]?.recommendation
    }

    enum Recommendation: String {
        case bestBalance = "Best Balance"
        case bestQuality = "Best Quality"
        case fastest = "Fastest"
    }

    // MARK: - Fallback tiers from quantization

    private var quantizationSpeedTier: Int {
        switch quantization {
        case "Q8_0": return 1
        case "Q6_K": return 2
        case "Q5_K_M", "Q5_K_S": return 3
        case "Q4_K_M": return 4
        case "Q4_K_S", "Q4_1", "Q4_0": return 4
        case "Q3_K_M", "Q3_K_S": return 5
        default: return 3
        }
    }

    private var quantizationQualityTier: Int {
        switch quantization {
        case "Q8_0": return 5
        case "Q6_K": return 5
        case "Q5_K_M", "Q5_K_S": return 4
        case "Q4_K_M": return 3
        case "Q4_K_S", "Q4_1", "Q4_0": return 3
        case "Q3_K_M", "Q3_K_S": return 2
        default: return 3
        }
    }

    // MARK: - Known Models Database

    private struct ModelInfo {
        let displayName: String
        let quantization: String
        let speedTier: Int      // 1-5
        let qualityTier: Int    // 1-5
        let description: String
        let recommendation: Recommendation?
    }

    private static let knownModels: [String: ModelInfo] = [
        "gemma-4-E4B-it-Q6_K.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — Q6_K",
            quantization: "Q6_K",
            speedTier: 2,
            qualityTier: 5,
            description: "Highest quality, but slower and uses more memory (7 GB). Best for detailed financial analysis when speed is not critical.",
            recommendation: .bestQuality
        ),
        "gemma-4-E4B-it-Q5_K_M.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — Q5_K_M",
            quantization: "Q5_K_M",
            speedTier: 3,
            qualityTier: 4,
            description: "Great balance of speed and quality (5.5 GB). Nearly as accurate as Q6_K but noticeably faster. Recommended for most users.",
            recommendation: .bestBalance
        ),
        "gemma-4-E4B-it-Q5_K_S.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — Q5_K_S",
            quantization: "Q5_K_S",
            speedTier: 3,
            qualityTier: 4,
            description: "Similar to Q5_K_M with slightly smaller file size. Good all-around choice.",
            recommendation: nil
        ),
        "gemma-4-E4B-it-Q4_K_M.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — Q4_K_M",
            quantization: "Q4_K_M",
            speedTier: 4,
            qualityTier: 3,
            description: "Fast and lightweight (5 GB). Good enough for budgeting and transactions. Best if your Mac feels slow with larger models.",
            recommendation: .fastest
        ),
        "gemma-4-E4B-it-Q4_K_S.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — Q4_K_S",
            quantization: "Q4_K_S",
            speedTier: 4,
            qualityTier: 3,
            description: "Compact 4-bit quantization. Fast inference with acceptable quality for everyday use.",
            recommendation: nil
        ),
        "gemma-4-E4B-it-Q4_0.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — Q4_0",
            quantization: "Q4_0",
            speedTier: 4,
            qualityTier: 2,
            description: "Basic 4-bit quantization. Very fast but lower quality — may produce less accurate financial advice.",
            recommendation: nil
        ),
        "gemma-4-E4B-it-Q4_1.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — Q4_1",
            quantization: "Q4_1",
            speedTier: 4,
            qualityTier: 3,
            description: "Improved 4-bit quantization. Better than Q4_0 with similar speed.",
            recommendation: nil
        ),
        "gemma-4-E4B-it-Q8_0.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — Q8_0",
            quantization: "Q8_0",
            speedTier: 1,
            qualityTier: 5,
            description: "Near-lossless 8-bit (8.2 GB). Maximum quality but very heavy on memory. May cause lag on 16 GB Macs.",
            recommendation: nil
        ),
        "gemma-4-E4B-it-Q3_K_M.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — Q3_K_M",
            quantization: "Q3_K_M",
            speedTier: 5,
            qualityTier: 2,
            description: "Ultra-compact 3-bit. Fastest possible but significant quality loss. Only for very constrained systems.",
            recommendation: nil
        ),
        "gemma-4-E4B-it-Q3_K_S.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — Q3_K_S",
            quantization: "Q3_K_S",
            speedTier: 5,
            qualityTier: 2,
            description: "Smallest 3-bit variant. Ultra-fast but noticeable quality degradation.",
            recommendation: nil
        ),
        "gemma-4-E4B-it-IQ4_XS.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — IQ4_XS",
            quantization: "IQ4_XS",
            speedTier: 4,
            qualityTier: 3,
            description: "Importance-weighted 4-bit. Smaller than Q4_K_M with similar quality in key areas.",
            recommendation: nil
        ),
        "gemma-4-E4B-it-IQ4_NL.gguf": ModelInfo(
            displayName: "Gemma 4 E4B — IQ4_NL",
            quantization: "IQ4_NL",
            speedTier: 4,
            qualityTier: 3,
            description: "Non-linear 4-bit quantization. Experimental but efficient.",
            recommendation: nil
        ),
        "gemma-4-E2B-it-Q4_K_M.gguf": ModelInfo(
            displayName: "Gemma 4 E2B — Q4_K_M",
            quantization: "Q4_K_M",
            speedTier: 5,
            qualityTier: 2,
            description: "Smaller 2B model (2.9 GB). Very fast but less capable. Good for quick simple questions only.",
            recommendation: nil
        ),
    ]

    // MARK: - Downloadable Model Catalog

    /// Models available for download
    struct DownloadOption: Identifiable {
        let filename: String
        let url: String
        let sizeLabel: String
        let estimatedBytes: Int64

        var id: String { filename }

        var modelFile: AIModelFile {
            AIModelFile(filename: filename, sizeBytes: estimatedBytes)
        }
    }

    static let downloadCatalog: [DownloadOption] = [
        DownloadOption(
            filename: "gemma-4-E4B-it-Q5_K_M.gguf",
            url: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q5_K_M.gguf",
            sizeLabel: "~5.5 GB",
            estimatedBytes: 5_480_000_000
        ),
        DownloadOption(
            filename: "gemma-4-E4B-it-Q6_K.gguf",
            url: "https://huggingface.co/Dextermitur/MacOs-Gemma-Centmond/resolve/main/gemma-4-E4B-it-Q6_K.gguf",
            sizeLabel: "~7 GB",
            estimatedBytes: 7_070_000_000
        ),
    ]
}
