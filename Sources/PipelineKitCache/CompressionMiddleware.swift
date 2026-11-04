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
///     algorithm: .rawDeflate,
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
/// - Encoding uses the platform codec settings; compression levels are not configurable
/// - Monitor compression ratios to ensure effectiveness
///
/// - Note: This middleware has `.postProcessing` priority to compress
///   after business logic but before network transmission.
///
/// - SeeAlso: `CompressionAlgorithm`, `Middleware`
public struct CompressionMiddleware: Middleware {
    /// Priority ensures compression happens at the right time.
    public let priority: ExecutionPriority = .postProcessing
    
    /// The compression algorithm to use.
    private let algorithm: CompressionAlgorithm
    
    /// Minimum data size to trigger compression (bytes).
    private let minimumSize: Int
    
    /// Whether to track compression statistics.
    private let trackStatistics: Bool
    
    /// Creates a new compression middleware.
    ///
    /// - Parameters:
    ///   - algorithm: The compression algorithm to use
    ///   - minimumSize: Minimum payload size to compress (default: 1KB)
    ///   - trackStatistics: Whether to track compression metrics
    public init(
        algorithm: CompressionAlgorithm = .rawDeflate,
        minimumSize: Int = 1024,
        trackStatistics: Bool = true
    ) {
        self.algorithm = algorithm
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
                    using: algorithm
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
                    using: algorithm
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

/// Wire formats emitted by the platform codecs, using their default encoder settings.
public enum CompressionAlgorithm: String, Sendable, CaseIterable {
    /// RFC 1951 raw DEFLATE without a zlib or gzip container.
    case rawDeflate = "deflate-raw"

    /// Apple's LZFSE format.
    case lzfse

    /// LZ4 with Apple's framing, as documented in the platform compression.h header.
    case appleLZ4 = "apple-lz4"

    var foundationAlgorithm: compression_algorithm {
        switch self {
        case .rawDeflate: return COMPRESSION_ZLIB
        case .lzfse: return COMPRESSION_LZFSE
        case .appleLZ4: return COMPRESSION_LZ4
        }
    }
}

/// Labels persisted by older PipelineKit versions, available only for decoding.
///
/// Historical `zlib` and `gzip` payloads are raw DEFLATE; historical `brotli`
/// payloads are LZFSE. These labels never select genuine gzip or Brotli streams.
/// `CompressionFormatContractTests` verifies each mapping with fixed legacy fixtures.
public enum LegacyCompressionAlgorithm: String, Sendable, CaseIterable {
    /// Historical `zlib` label selecting raw DEFLATE decoding.
    case zlib
    /// Historical `gzip` label selecting raw DEFLATE decoding without a gzip container.
    case gzip
    /// Historical label selecting Apple's LZFSE decoding.
    case lzfse
    /// Historical `brotli` label selecting LZFSE decoding, not the Brotli format.
    case brotli
    /// Historical `lz4` label selecting Apple's framed LZ4 decoding.
    case lz4

    fileprivate var canonicalAlgorithm: CompressionAlgorithm {
        switch self {
        case .zlib, .gzip: return .rawDeflate
        case .lzfse, .brotli: return .lzfse
        case .lz4: return .appleLZ4
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
    /// Compression failed for the associated diagnostic reason.
    case compressionFailed(String)
    /// Decompression failed for the associated validation or decoding reason.
    case decompressionFailed(String)
    /// The associated algorithm identifier is unsupported.
    case unsupportedAlgorithm(String)
    /// Encoding allocation overflowed, or decoding exceeded the associated output limit.
    ///
    /// The associated byte count is the input size for encoding allocation overflow,
    /// or the caller's `maxOutputSize` for a decoding limit violation.
    case dataTooLarge(Int)
    
    /// A human-readable description of the error and its associated value.
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
    /// Return a saturating allocation estimate using a one-percent margin plus 16 bytes.
    ///
    /// This estimate is not a proven upper bound for every codec or input. The encoder
    /// independently checks its allocation arithmetic and reports insufficient output space.
    /// - Precondition: `sourceSize` is nonnegative.
    /// - Returns: The estimate, or `Int.max` if the derived arithmetic overflows.
    public static func maxCompressedSize(for sourceSize: Int) -> Int {
        precondition(sourceSize >= 0, "Source size must be nonnegative")
        let (withMargin, marginOverflow) = sourceSize.addingReportingOverflow(sourceSize / 100)
        let (estimate, overheadOverflow) = withMargin.addingReportingOverflow(16)
        return marginOverflow || overheadOverflow ? Int.max : estimate
    }

    /// Compress data using the specified algorithm, including nonempty small payloads.
    ///
    /// Empty input retains its empty representation. `testSmallPayloadRoundTrips` in
    /// `CompressionCompletionContractTests` covers the empty and small-payload contract.
    /// Middleware callers still decide whether compression is beneficial.
    public static func compress(
        _ data: Data,
        using algorithm: CompressionAlgorithm
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
    
    /// Decode bytes identified by a historical PipelineKit algorithm label.
    ///
    /// This preserves the original bytes-to-codec mapping, including the old `gzip`
    /// and `brotli` aliases. `originalSize` and `maxOutputSize` follow `decompress`:
    /// the hint is nonnegative, the limit is positive, and a complete stream with no
    /// trailing input is required. `CompressionFormatContractTests` covers these routes.
    public static func decompressLegacy(
        _ data: Data,
        using algorithm: LegacyCompressionAlgorithm,
        originalSize: Int? = nil,
        maxOutputSize: Int
    ) throws -> Data {
        try decompress(
            data, using: algorithm.canonicalAlgorithm,
            originalSize: originalSize, maxOutputSize: maxOutputSize
        )
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
        using algorithm: CompressionAlgorithm
    ) -> Result<Double, CompressionError> {
        guard !data.isEmpty else { return .success(1.0) }
        
        do {
            let compressed = try compress(data, using: algorithm)
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
