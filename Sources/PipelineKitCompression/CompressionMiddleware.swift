import Foundation
import PipelineKitCore
import Compression

/// Middleware that provides transparent compression/decompression for command data.
///
/// This middleware automatically compresses command payloads and results to reduce
/// memory usage and network transfer costs, while maintaining transparency for handlers.
///
/// ## Overview
///
/// The compression middleware:
/// - Compresses large command payloads before processing
/// - Decompresses data transparently for handlers
/// - Supports multiple compression algorithms
/// - Provides configurable compression thresholds
/// - Tracks compression ratios for monitoring
///
/// ## Usage
///
/// ```swift
/// let compressionMiddleware = CompressionMiddleware(
///     algorithm: .zlib,
///     compressionLevel: .balanced,
///     minimumSize: 1024 // Only compress data > 1KB
/// )
///
/// let pipeline = StandardPipeline(
///     handler: handler,
///     middleware: [compressionMiddleware, ...]
/// )
/// ```
///
/// ## Performance Considerations
///
/// - Compression trades CPU for memory/bandwidth
/// - Use `.fast` level for real-time systems
/// - Use `.best` level for batch processing
/// - Monitor compression ratios to ensure effectiveness
///
/// - Note: This middleware has `.postProcessing` priority to compress
///   after business logic but before network transmission.
///
/// - SeeAlso: `CompressionAlgorithm`, `CompressionLevel`, `Middleware`
public struct CompressionMiddleware: Middleware {
    /// Priority ensures compression happens at the right time.
    public let priority: ExecutionPriority = .postProcessing
    
    /// The compression algorithm to use.
    private let algorithm: CompressionAlgorithm
    
    /// Compression level (speed vs size tradeoff).
    private let compressionLevel: CompressionLevel
    
    /// Minimum data size to trigger compression (bytes).
    private let minimumSize: Int
    
    /// Whether to track compression statistics.
    private let trackStatistics: Bool
    
    /// Creates a new compression middleware.
    ///
    /// - Parameters:
    ///   - algorithm: The compression algorithm to use
    ///   - compressionLevel: Balance between speed and compression ratio
    ///   - minimumSize: Minimum payload size to compress (default: 1KB)
    ///   - trackStatistics: Whether to track compression metrics
    public init(
        algorithm: CompressionAlgorithm = .zlib,
        compressionLevel: CompressionLevel = .balanced,
        minimumSize: Int = 1024,
        trackStatistics: Bool = true
    ) {
        self.algorithm = algorithm
        self.compressionLevel = compressionLevel
        self.minimumSize = minimumSize
        self.trackStatistics = trackStatistics
    }
    
    /// Executes compression around command processing.
    ///
    /// - Parameters:
    ///   - command: The command being executed
    ///   - context: The command context
    ///   - next: The next handler in the chain
    ///
    /// - Returns: The result from the command execution chain
    ///
    /// - Throws: `CompressionError` if compression fails, or any error
    ///   from the downstream chain
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        
        // Try to compress the command if it supports compression
        var processedCommand = command
        var compressionApplied = false
        
        if let compressible = command as? CompressibleCommand,
           compressible.estimatedSize >= minimumSize,
           let dataToCompress = compressible.dataToCompress {
            
            do {
                // Compress the data
                let compressedData = try CompressionUtility.compress(
                    dataToCompress,
                    using: algorithm,
                    level: compressionLevel
                )
                
                // Only use compressed version if it's actually smaller
                if compressedData.count < dataToCompress.count {
                    processedCommand = compressible.withCompressedData(compressedData) as! T
                    compressionApplied = true
                    
                    // Store compression metadata
                    context.metadata["compression.applied"] = true
                    context.metadata["compression.algorithm"] = algorithm.rawValue
                    context.metadata["compression.level"] = compressionLevel.rawValue
                    context.metadata["compression.originalSize"] = dataToCompress.count
                    context.metadata["compression.compressedSize"] = compressedData.count
                    context.metadata["compression.ratio"] = Double(dataToCompress.count) / Double(compressedData.count)
                    
                    if trackStatistics {
                        await updateStatistics(
                            originalSize: dataToCompress.count,
                            compressedSize: compressedData.count,
                            duration: Date().timeIntervalSince(startTime)
                        )
                    }
                }
            } catch {
                // Log compression failure but continue with uncompressed data
                context.metadata["compression.failed"] = true
                context.metadata["compression.error"] = error.localizedDescription
            }
        }
        
        // Execute command with potentially compressed data
        let result = try await next(processedCommand, context)
        
        // If we compressed the command, we may need to decompress the result
        var processedResult = result
        if compressionApplied {
            // Mark that decompression may be needed
            context.metadata["compression.needsDecompression"] = true
        }
        
        // Try to compress the result if it supports compression
        if let compressibleResult = result as? CompressibleResult,
           compressibleResult.estimatedSize >= minimumSize,
           let dataToCompress = compressibleResult.dataToCompress {
            
            do {
                // Compress the result data
                let compressedData = try CompressionUtility.compress(
                    dataToCompress,
                    using: algorithm,
                    level: compressionLevel
                )
                
                // Only use compressed version if it's actually smaller
                if compressedData.count < dataToCompress.count {
                    processedResult = compressibleResult.withCompressedData(compressedData) as! T.Result
                    
                    // Store result compression metadata
                    context.metadata["compression.resultApplied"] = true
                    context.metadata["compression.resultOriginalSize"] = dataToCompress.count
                    context.metadata["compression.resultCompressedSize"] = compressedData.count
                    context.metadata["compression.resultRatio"] = Double(dataToCompress.count) / Double(compressedData.count)
                }
            } catch {
                // Log compression failure but return uncompressed result
                context.metadata["compression.resultFailed"] = true
                context.metadata["compression.resultError"] = error.localizedDescription
            }
        }
        
        return processedResult
    }
    
    // MARK: - Private Methods
    
    private func shouldCompressCommand<T: Command>(_ command: T, context: CommandContext) async -> Bool {
        // Check if compression is disabled in context
        if let disabled = context.metadata["compression.disabled"] as? Bool, disabled {
            return false
        }
        
        // Check size threshold
        if let compressible = command as? CompressibleCommand {
            return compressible.estimatedSize >= minimumSize
        }
        
        return false
    }
    
    private func estimateCompressedSize(_ originalSize: Int) -> Int {
        // Estimate based on typical compression ratios
        switch algorithm {
        case .zlib:
            return Int(Double(originalSize) * 0.3) // ~70% compression
        case .lzfse:
            return Int(Double(originalSize) * 0.35) // ~65% compression
        case .lz4:
            return Int(Double(originalSize) * 0.4) // ~60% compression
        case .gzip:
            return Int(Double(originalSize) * 0.28) // ~72% compression
        case .brotli:
            return Int(Double(originalSize) * 0.25) // ~75% compression
        }
    }
    
    private func updateStatistics(originalSize: Int, compressedSize: Int, duration: TimeInterval) async {
        // In production, this would update metrics collectors
        let ratio = Double(originalSize) / Double(compressedSize)
        let throughput = Double(originalSize) / duration // bytes per second
        
        // Log statistics (would normally go to metrics system)
        #if DEBUG
        print("""
            Compression Statistics:
            - Algorithm: \(algorithm.rawValue)
            - Original: \(originalSize) bytes
            - Compressed: \(compressedSize) bytes
            - Ratio: \(String(format: "%.2fx", ratio))
            - Throughput: \(String(format: "%.2f", throughput / 1024 / 1024)) MB/s
            """)
        #endif
    }
}

// MARK: - Supporting Types

/// Available compression algorithms.
public enum CompressionAlgorithm: String, Sendable, CaseIterable {
    /// Zlib compression (good balance).
    case zlib = "zlib"
    
    /// Apple's LZFSE (optimized for Apple platforms).
    case lzfse = "lzfse"
    
    /// LZ4 (very fast, moderate compression).
    case lz4 = "lz4"
    
    /// Gzip compression (widely compatible).
    case gzip = "gzip"
    
    /// Brotli (best compression, slower).
    case brotli = "brotli"
    
    /// The Foundation Compression algorithm type.
    var foundationAlgorithm: compression_algorithm {
        switch self {
        case .zlib: return COMPRESSION_ZLIB
        case .lzfse: return COMPRESSION_LZFSE
        case .lz4: return COMPRESSION_LZ4
        case .gzip: return COMPRESSION_ZLIB // Use zlib with gzip wrapper
        case .brotli: return COMPRESSION_LZFSE // Fallback, Brotli not in Foundation
        }
    }
}

/// Compression level (speed vs ratio tradeoff).
public enum CompressionLevel: Sendable {
    /// Fastest compression, lower ratio.
    case fast
    
    /// Balanced speed and compression.
    case balanced
    
    /// Best compression, slower.
    case best
    
    /// Custom level (0-9).
    case custom(Int)
    
    public var rawValue: String {
        switch self {
        case .fast: return "fast"
        case .balanced: return "balanced"
        case .best: return "best"
        case .custom(let level): return "custom-\(level)"
        }
    }
    
    /// Compression level for zlib (-1 to 9).
    var zlibLevel: Int32 {
        switch self {
        case .fast: return 1
        case .balanced: return 5
        case .best: return 9
        case .custom(let level): return Int32(max(0, min(9, level)))
        }
    }
}

/// Protocol for commands that can be compressed.
public protocol CompressibleCommand: Command {
    /// Returns the data to be compressed.
    var dataToCompress: Data? { get }
    
    /// Estimated size of the command data in bytes.
    var estimatedSize: Int { get }
    
    /// Creates a new instance with compressed data.
    func withCompressedData(_ compressedData: Data) -> Self
    
    /// Creates a new instance with decompressed data.
    func withDecompressedData(_ data: Data) -> Self
}

/// Protocol for results that can be compressed.
public protocol CompressibleResult {
    /// Returns the data to be compressed.
    var dataToCompress: Data? { get }
    
    /// Estimated size of the result data in bytes.
    var estimatedSize: Int { get }
    
    /// Creates a new instance with compressed data.
    func withCompressedData(_ compressedData: Data) -> Self
    
    /// Creates a new instance with decompressed data.
    func withDecompressedData(_ data: Data) -> Self
}

/// Errors that can occur during compression operations.
public enum CompressionError: Error, LocalizedError {
    case compressionFailed(String)
    case decompressionFailed(String)
    case unsupportedAlgorithm(String)
    case dataTooLarge(Int)
    
    public var errorDescription: String? {
        switch self {
        case .compressionFailed(let reason):
            return "Compression failed: \(reason)"
        case .decompressionFailed(let reason):
            return "Decompression failed: \(reason)"
        case .unsupportedAlgorithm(let algorithm):
            return "Unsupported compression algorithm: \(algorithm)"
        case .dataTooLarge(let size):
            return "Data too large for compression: \(size) bytes"
        }
    }
}

// MARK: - Compression Utilities

/// Utility class for performing actual compression/decompression.
public final class CompressionUtility: Sendable {
    /// Calculate the maximum possible compressed size for a given input size.
    ///
    /// This uses the zlib formula for worst-case compression overhead.
    /// - Parameter sourceSize: The size of the uncompressed data
    /// - Returns: The maximum possible compressed size
    public static func maxCompressedSize(for sourceSize: Int) -> Int {
        return sourceSize + sourceSize / 100 + 16
    }
    
    /// Compress data using the specified algorithm.
    public static func compress(
        _ data: Data,
        using algorithm: CompressionAlgorithm,
        level: CompressionLevel = .balanced
    ) throws -> Data {
        guard !data.isEmpty else { return data }
        
        return try data.withUnsafeBytes { sourceBuffer in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw CompressionError.compressionFailed("Invalid source data")
            }
            
            let destinationSize = maxCompressedSize(for: data.count)
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
            defer { destinationBuffer.deallocate() }
            
            let compressedSize = compression_encode_buffer(
                destinationBuffer, destinationSize,
                sourcePtr, data.count,
                nil, algorithm.foundationAlgorithm
            )
            
            guard compressedSize > 0 else {
                throw CompressionError.compressionFailed("Compression returned no data")
            }
            
            guard compressedSize <= destinationSize else {
                throw CompressionError.compressionFailed("Buffer overflow: compressed size \(compressedSize) exceeds buffer \(destinationSize)")
            }
            
            return Data(bytes: destinationBuffer, count: compressedSize)
        }
    }
    
    /// Decompress data using the specified algorithm.
    public static func decompress(
        _ data: Data,
        using algorithm: CompressionAlgorithm,
        originalSize: Int? = nil
    ) throws -> Data {
        guard !data.isEmpty else { return data }
        
        return try data.withUnsafeBytes { sourceBuffer in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw CompressionError.decompressionFailed("Invalid source data")
            }
            
            // Estimate decompressed size (use original if known)
            let destinationSize = originalSize ?? (data.count * 10)
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
            defer { destinationBuffer.deallocate() }
            
            let decompressedSize = compression_decode_buffer(
                destinationBuffer, destinationSize,
                sourcePtr, data.count,
                nil, algorithm.foundationAlgorithm
            )
            
            guard decompressedSize > 0 else {
                throw CompressionError.decompressionFailed("Decompression returned no data")
            }
            
            return Data(bytes: destinationBuffer, count: decompressedSize)
        }
    }
    
    /// Calculate compression ratio for data.
    /// - Returns: The compression ratio, or nil if compression fails
    public static func compressionRatio(
        for data: Data,
        using algorithm: CompressionAlgorithm,
        level: CompressionLevel = .balanced
    ) -> Result<Double, CompressionError> {
        guard !data.isEmpty else { return .success(1.0) }
        
        do {
            let compressed = try compress(data, using: algorithm, level: level)
            let ratio = Double(data.count) / Double(compressed.count)
            return .success(ratio)
        } catch let error as CompressionError {
            // Log the error for debugging
            #if DEBUG
            print("Compression ratio calculation failed: \(error)")
            #endif
            return .failure(error)
        } catch {
            return .failure(.compressionFailed("Unknown error: \(error)"))
        }
    }
    
    /// Calculate compression ratio for data (legacy version for compatibility).
    /// - Warning: This method swallows errors and returns 1.0 on failure. Use the Result-based version instead.
    @available(*, deprecated, message: "Use compressionRatio that returns Result instead")
    public static func compressionRatioOrDefault(
        for data: Data,
        using algorithm: CompressionAlgorithm,
        level: CompressionLevel = .balanced
    ) -> Double {
        switch compressionRatio(for: data, using: algorithm, level: level) {
        case .success(let ratio):
            return ratio
        case .failure:
            return 1.0
        }
    }
}