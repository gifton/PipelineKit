import Foundation
import Compression
import PipelineKitCore

/// Middleware that provides compression and decompression for command payloads.
///
/// This middleware automatically compresses large payloads before processing and
/// decompresses results when needed. It supports multiple compression algorithms
/// and configurable thresholds.
///
/// ## Features
/// - Automatic compression based on payload size
/// - Multiple compression algorithms (zlib, lz4, lzfse, lzma)
/// - Configurable compression thresholds
/// - Transparent compression/decompression
/// - Metrics tracking for compression ratios
///
/// ## Example Usage
/// ```swift
/// let middleware = CompressionMiddleware(
///     algorithm: .zlib,
///     compressionThreshold: 1024, // Compress payloads > 1KB
///     compressionLevel: .balanced
/// )
/// pipeline.use(middleware)
/// ```
public struct CompressionMiddleware: Middleware {
    public let priority: ExecutionPriority = .processing

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Compression algorithm to use
        public let algorithm: CompressionAlgorithm

        /// Minimum payload size for compression (in bytes)
        public let compressionThreshold: Int

        /// Compression level
        public let compressionLevel: CompressionLevel

        /// Whether to compress command inputs
        public let compressInputs: Bool

        /// Whether to compress command results
        public let compressResults: Bool

        /// Content types to compress (if empty, compress all)
        public let allowedContentTypes: Set<String>

        /// Content types to never compress
        public let excludedContentTypes: Set<String>

        /// Whether to emit metrics
        public let emitMetrics: Bool

        public init(
            algorithm: CompressionAlgorithm = .zlib,
            compressionThreshold: Int = 1024,
            compressionLevel: CompressionLevel = .balanced,
            compressInputs: Bool = true,
            compressResults: Bool = true,
            allowedContentTypes: Set<String> = [],
            excludedContentTypes: Set<String> = ["image/jpeg", "image/png", "video/mp4"],
            emitMetrics: Bool = true
        ) {
            self.algorithm = algorithm
            self.compressionThreshold = compressionThreshold
            self.compressionLevel = compressionLevel
            self.compressInputs = compressInputs
            self.compressResults = compressResults
            self.allowedContentTypes = allowedContentTypes
            self.excludedContentTypes = excludedContentTypes
            self.emitMetrics = emitMetrics
        }
    }

    /// Compression algorithms
    public enum CompressionAlgorithm: String, Sendable, CaseIterable {
        case zlib
        case lz4
        case lzfse
        case lzma

        var algorithm: compression_algorithm {
            switch self {
            case .zlib: return COMPRESSION_ZLIB
            case .lz4: return COMPRESSION_LZ4
            case .lzfse: return COMPRESSION_LZFSE
            case .lzma: return COMPRESSION_LZMA
            }
        }
    }

    /// Compression levels
    public enum CompressionLevel: Sendable {
        case fastest
        case balanced
        case best
        case custom(Int)

        var level: Int {
            switch self {
            case .fastest: return 1
            case .balanced: return 5
            case .best: return 9
            case .custom(let level): return max(0, min(9, level))
            }
        }
    }

    private let configuration: Configuration
    private let compressor: PayloadCompressor

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.compressor = PayloadCompressor(configuration: configuration)
    }

    public init(
        algorithm: CompressionAlgorithm = .zlib,
        compressionThreshold: Int = 1024
    ) {
        self.init(
            configuration: Configuration(
                algorithm: algorithm,
                compressionThreshold: compressionThreshold
            )
        )
    }

    // MARK: - Middleware Implementation

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        var compressedCommand = command
        var compressionApplied = false
        var originalSize = 0
        var compressedSize = 0

        // Compress command if it implements CompressibleCommand
        if configuration.compressInputs,
           var compressible = command as? any CompressibleCommand {
            let payload = compressible.getCompressiblePayload()

            if shouldCompress(payload: payload, contentType: compressible.contentType) {
                originalSize = payload.count

                do {
                    let compressed = try await compressor.compress(payload)
                    compressedSize = compressed.count
                    compressible.setCompressedPayload(compressed, algorithm: configuration.algorithm)

                    if let updatedCommand = compressible as? T {
                        compressedCommand = updatedCommand
                        compressionApplied = true

                        // Store compression info in context
                        context.metadata["compressionApplied"] = true
                        context.metadata["compressionAlgorithm"] = configuration.algorithm.rawValue
                        context.metadata["originalSize"] = originalSize
                        context.metadata["compressedSize"] = compressedSize
                    }
                } catch {
                    // Log compression failure but continue
                    await emitCompressionError(error: error, context: context)
                }
            }
        }

        // Execute command
        let result = try await next(compressedCommand, context)

        // Handle result compression if needed
        var finalResult = result
        if configuration.compressResults,
           let compressibleResult = result as? any CompressibleResult {
            finalResult = try await handleResultCompression(
                result: compressibleResult,
                context: context
            ) as? T.Result ?? result
        }

        // Emit metrics
        if compressionApplied {
            let duration = Date().timeIntervalSince(startTime)
            await emitCompressionMetrics(
                originalSize: originalSize,
                compressedSize: compressedSize,
                duration: duration,
                context: context
            )
        }

        return finalResult
    }

    // MARK: - Private Methods

    private func shouldCompress(payload: Data, contentType: String?) -> Bool {
        // Check size threshold
        guard payload.count >= configuration.compressionThreshold else {
            return false
        }

        // Check content type if specified
        if let contentType = contentType {
            // Check excluded types first
            if configuration.excludedContentTypes.contains(contentType) {
                return false
            }

            // If allowed types are specified, check inclusion
            if !configuration.allowedContentTypes.isEmpty {
                return configuration.allowedContentTypes.contains(contentType)
            }
        }

        return true
    }

    private func handleResultCompression<R: CompressibleResult>(
        result: R,
        context: CommandContext
    ) async throws -> R {
        let payload = result.getCompressiblePayload()

        guard shouldCompress(payload: payload, contentType: result.contentType) else {
            return result
        }

        let originalSize = payload.count
        let compressed = try await compressor.compress(payload)
        let compressedSize = compressed.count

        var compressedResult = result
        compressedResult.setCompressedPayload(compressed, algorithm: configuration.algorithm)

        // Update metrics
        if let existingOriginal = context.metrics["compression.result.originalSize"] as? Int {
            context.metrics["compression.result.originalSize"] = existingOriginal + originalSize
            context.metrics["compression.result.compressedSize"] = (context.metrics["compression.result.compressedSize"] as? Int ?? 0) + compressedSize
        } else {
            context.metrics["compression.result.originalSize"] = originalSize
            context.metrics["compression.result.compressedSize"] = compressedSize
        }

        return compressedResult
    }

    private func emitCompressionMetrics(
        originalSize: Int,
        compressedSize: Int,
        duration: TimeInterval,
        context: CommandContext
    ) async {
        guard configuration.emitMetrics else { return }

        let compressionRatio = Double(originalSize - compressedSize) / Double(originalSize)

        context.metrics["compression.originalSize"] = originalSize
        context.metrics["compression.compressedSize"] = compressedSize
        context.metrics["compression.ratio"] = compressionRatio
        context.metrics["compression.duration"] = duration

        // Store compression event data in context metadata
        context.metadata["compressionEvent"] = [
            "event": "payload_compressed",
            "algorithm": configuration.algorithm.rawValue,
            "original_size": originalSize,
            "compressed_size": compressedSize,
            "compression_ratio": compressionRatio,
            "duration": duration,
            "timestamp": Date()
        ] as [String: any Sendable]
    }

    private func emitCompressionError(error: Error, context: CommandContext) async {
        guard configuration.emitMetrics else { return }

        // Store compression error event data in context metadata
        context.metadata["compressionErrorEvent"] = [
            "event": "compression_error",
            "error": String(describing: error),
            "algorithm": configuration.algorithm.rawValue,
            "timestamp": Date()
        ] as [String: any Sendable]
    }
}

// MARK: - Protocols

/// Protocol for commands that support compression
public protocol CompressibleCommand: Command {
    /// Content type of the payload (e.g., "application/json")
    var contentType: String? { get }

    /// Get the payload to compress
    func getCompressiblePayload() -> Data

    /// Set the compressed payload
    mutating func setCompressedPayload(_ data: Data, algorithm: CompressionMiddleware.CompressionAlgorithm)
}

/// Protocol for results that support compression
public protocol CompressibleResult {
    /// Content type of the result
    var contentType: String? { get }

    /// Get the payload to compress
    func getCompressiblePayload() -> Data

    /// Set the compressed payload
    mutating func setCompressedPayload(_ data: Data, algorithm: CompressionMiddleware.CompressionAlgorithm)
}

// MARK: - Payload Compressor

private actor PayloadCompressor {
    private let configuration: CompressionMiddleware.Configuration

    init(configuration: CompressionMiddleware.Configuration) {
        self.configuration = configuration
    }

    func compress(_ data: Data) throws -> Data {
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return compression_encode_buffer(
                destinationBuffer,
                data.count,
                baseAddress,
                data.count,
                nil,
                configuration.algorithm.algorithm
            )
        }

        guard compressedSize > 0 else {
            throw CompressionError.compressionFailed
        }

        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    func decompress(_ data: Data, originalSize: Int? = nil) throws -> Data {
        let bufferSize = originalSize ?? data.count * 4
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return compression_decode_buffer(
                destinationBuffer,
                bufferSize,
                baseAddress,
                data.count,
                nil,
                configuration.algorithm.algorithm
            )
        }

        guard decompressedSize > 0 else {
            throw CompressionError.decompressionFailed
        }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}

// MARK: - Errors

public enum CompressionError: Error, Sendable {
    case compressionFailed
    case decompressionFailed
    case invalidAlgorithm
    case payloadTooLarge
}

// MARK: - Convenience Extensions

public extension CompressionMiddleware {
    /// Creates a compression middleware optimized for JSON payloads
    static func json(threshold: Int = 512) -> CompressionMiddleware {
        CompressionMiddleware(
            configuration: Configuration(
                algorithm: .zlib,
                compressionThreshold: threshold,
                compressionLevel: .balanced,
                allowedContentTypes: ["application/json", "text/json"]
            )
        )
    }

    /// Creates a compression middleware optimized for text payloads
    static func text(threshold: Int = 1024) -> CompressionMiddleware {
        CompressionMiddleware(
            configuration: Configuration(
                algorithm: .lzfse,
                compressionThreshold: threshold,
                compressionLevel: .balanced,
                allowedContentTypes: ["text/plain", "text/html", "text/xml", "text/csv"]
            )
        )
    }

    /// Creates a compression middleware for large binary payloads
    static func binary(threshold: Int = 10240) -> CompressionMiddleware {
        CompressionMiddleware(
            configuration: Configuration(
                algorithm: .lz4,
                compressionThreshold: threshold,
                compressionLevel: .fastest,
                excludedContentTypes: ["image/jpeg", "image/png", "video/mp4", "audio/mp3"]
            )
        )
    }
}

// MARK: - Decompression Support

public extension CompressionMiddleware {
    /// Decompresses data that was compressed by this middleware
    static func decompress(
        _ data: Data,
        algorithm: CompressionAlgorithm,
        originalSize: Int? = nil
    ) async throws -> Data {
        let compressor = PayloadCompressor(
            configuration: Configuration(algorithm: algorithm)
        )
        return try await compressor.decompress(data, originalSize: originalSize)
    }
}
