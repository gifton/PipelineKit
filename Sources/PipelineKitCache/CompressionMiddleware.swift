#if canImport(Compression)
import Foundation
import PipelineKit
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
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let startTime = Date()
        
        // Try to compress the command if it supports compression
        var processedCommand = command
        var compressionApplied = false
        
        if let compressible = command as? any CompressibleCommand,
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
                    guard let typedCommand = compressible.withCompressedData(compressedData) as? T else {
                        throw CompressionError.compressionFailed("Failed to cast compressed command to type \(T.self)")
                    }
                    processedCommand = typedCommand
                    compressionApplied = true
                    
                    // Store compression metadata
                    context.setMetadata("compression.applied", value: true)
                    context.setMetadata("compression.algorithm", value: algorithm.rawValue)
                    context.setMetadata("compression.level", value: compressionLevel.rawValue)
                    context.setMetadata("compression.originalSize", value: dataToCompress.count)
                    context.setMetadata("compression.compressedSize", value: compressedData.count)
                    context.setMetadata("compression.ratio", value: Double(dataToCompress.count) / Double(compressedData.count))
                    
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
                context.setMetadata("compression.failed", value: true)
                context.setMetadata("compression.error", value: error.localizedDescription)
            }
        }
        
        // Execute command with potentially compressed data
        let result = try await next(processedCommand, context)
        
        // If we compressed the command, we may need to decompress the result
        var processedResult = result
        if compressionApplied {
            // Mark that decompression may be needed
            context.setMetadata("compression.needsDecompression", value: true)
        }
        
        // Try to compress the result if it supports compression
        if let compressibleResult = result as? any CompressibleResult,
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
                    guard let typedResult = compressibleResult.withCompressedData(compressedData) as? T.Result else {
                        throw CompressionError.compressionFailed("Failed to cast compressed result to type \(T.Result.self)")
                    }
                    processedResult = typedResult
                    
                    // Store result compression metadata
                    context.setMetadata("compression.resultApplied", value: true)
                    context.setMetadata("compression.resultOriginalSize", value: dataToCompress.count)
                    context.setMetadata("compression.resultCompressedSize", value: compressedData.count)
                    context.setMetadata("compression.resultRatio", value: Double(dataToCompress.count) / Double(compressedData.count))
                }
            } catch {
                // Log compression failure but return uncompressed result
                context.setMetadata("compression.resultFailed", value: true)
                context.setMetadata("compression.resultError", value: error.localizedDescription)
            }
        }
        
        return processedResult
    }
    
    // MARK: - Private Methods
    
    private func shouldCompressCommand<T: Command>(_ command: T, context: CommandContext) async -> Bool {
        // Check if compression is disabled in context
        let metadata = context.getMetadata()
        if let disabled = metadata["compression.disabled"] as? Bool, disabled {
            return false
        }
        
        // Check size threshold
        if let compressible = command as? any CompressibleCommand {
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
    case zlib
    
    /// Apple's LZFSE (optimized for Apple platforms).
    case lzfse
    
    /// LZ4 (very fast, moderate compression).
    case lz4
    
    /// Gzip compression (widely compatible).
    case gzip
    
    /// Brotli (best compression, slower).
    case brotli
    
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
public enum CompressionError: Error, LocalizedError, Sendable {
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
    
    /// Compress data using the specified algorithm, including nonempty small payloads.
    ///
    /// Empty input retains its empty representation. `testSmallPayloadRoundTrips` in
    /// `CompressionCompletionContractTests` covers the empty and small-payload contract.
    /// Middleware callers still decide whether compression is beneficial.
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
            
            let (sizeWithOverhead, overheadOverflow) = data.count.addingReportingOverflow(data.count / 100)
            let (destinationSize, sizeOverflow) = sizeWithOverhead.addingReportingOverflow(16)
            guard !overheadOverflow, !sizeOverflow else {
                throw CompressionError.dataTooLarge(data.count)
            }
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
            defer { destinationBuffer.deallocate() }
            
            let compressedSize = compression_encode_buffer(
                destinationBuffer,
                destinationSize,
                sourcePtr,
                data.count,
                nil,
                algorithm.foundationAlgorithm
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
    
    /// Decode one complete compressed stream within a caller-selected output byte limit.
    ///
    /// - Parameters:
    ///   - data: One compressed stream. Empty input returns empty after argument validation.
    ///   - algorithm: The existing platform codec selected by `CompressionAlgorithm`.
    ///   - originalSize: Optional nonnegative allocation hint, not an expected length or
    ///     completion signal. The initial reservation is capped at `maxOutputSize` and 64 KiB.
    ///   - maxOutputSize: Required positive maximum number of decoded bytes to return.
    /// - Returns: All decoded bytes after the platform reports end-of-stream with no trailing
    ///   input. `CompressionCompletionContractTests` exercises limits, hints and malformed input.
    /// - Throws: `CompressionError.decompressionFailed` for invalid arguments, initialization
    ///   failure, platform-reported corruption, incomplete input, lack of progress or bytes
    ///   following the first stream.
    ///   `CompressionError.dataTooLarge(maxOutputSize)` if decoding produces an excess byte.
    ///
    /// The destination buffer is at most 64 KiB and no larger than the output limit.
    /// The codec manages its own internal state. At the exact limit, one destination byte is
    /// reused to distinguish completion from overflow; that byte is never appended to output.
    public static func decompress(
        _ data: Data,
        using algorithm: CompressionAlgorithm,
        originalSize: Int? = nil,
        maxOutputSize: Int
    ) throws -> Data {
        guard maxOutputSize > 0 else {
            throw CompressionError.decompressionFailed("Maximum output size must be positive")
        }
        if let originalSize, originalSize < 0 {
            throw CompressionError.decompressionFailed("Original size hint must be nonnegative")
        }
        guard !data.isEmpty else { return data }
        
        return try data.withUnsafeBytes { (sourceBuffer: UnsafeRawBufferPointer) in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw CompressionError.decompressionFailed("Invalid source data")
            }

            let bufferCapacity: Int = min(maxOutputSize, 64 * 1024)
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferCapacity)
            defer { destinationBuffer.deallocate() }

            var stream = compression_stream(
                dst_ptr: destinationBuffer, dst_size: 0, src_ptr: sourcePtr, src_size: 0, state: nil
            )
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm.foundationAlgorithm) == COMPRESSION_STATUS_OK else {
                throw CompressionError.decompressionFailed("Could not initialize decoder")
            }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = sourcePtr
            // DEFLATE/LZFSE may buffer trailing input before returning END (S05-P01).
            // Withhold the last byte so END before supplying it proves trailing data.
            // testTrailingAndConcatenatedStreamsAreRejected covers all enum cases.
            stream.src_size = data.count - 1
            var suppliedFinalByte = false

            var output = Data(capacity: min(originalSize ?? bufferCapacity, bufferCapacity))
            while true {
                // Subtraction is safe because append below is guarded by the remaining capacity.
                let remainingCapacity: Int = maxOutputSize - output.count
                let offeredCapacity: Int = remainingCapacity > 0 ? min(bufferCapacity, remainingCapacity) : 1
                let inputBefore: Int = stream.src_size
                stream.dst_ptr = destinationBuffer
                stream.dst_size = offeredCapacity

                let flags: Int32 = suppliedFinalByte ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(&stream, flags)
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw CompressionError.decompressionFailed("Invalid or incomplete compressed stream")
                }
                let produced: Int = offeredCapacity - stream.dst_size
                guard produced <= remainingCapacity else {
                    throw CompressionError.dataTooLarge(maxOutputSize)
                }
                output.append(destinationBuffer, count: produced)

                if status == COMPRESSION_STATUS_END {
                    guard suppliedFinalByte, stream.src_size == 0 else {
                        throw CompressionError.decompressionFailed("Trailing bytes after compressed stream")
                    }
                    return output
                }
                if stream.src_size == inputBefore && produced == 0 {
                    guard !suppliedFinalByte else {
                        throw CompressionError.decompressionFailed("Decoder made no progress before completion")
                    }
                    // Drain all buffered output before offering the withheld byte. On the
                    // next call FINALIZE makes incomplete input terminal; this refill occurs once.
                    // Preserve any unconsumed prefix and extend its contiguous buffer by one.
                    // Its size is at most data.count - 1 before this addition.
                    stream.src_size += 1
                    suppliedFinalByte = true
                }
            }
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
}

#endif // canImport(Compression)
