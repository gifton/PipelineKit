import Foundation

// MARK: - Compression Protocol

/// Internal protocol for platform-specific data compression implementations.
internal protocol DataCompressor {
    /// Compress data using gzip format.
    /// - Parameter data: The data to compress
    /// - Returns: Compressed data in gzip format
    /// - Throws: CompressionError if compression fails
    func compress(_ data: Data) throws -> Data
    
    /// Decompress gzip-compressed data.
    /// - Parameter data: The gzip-compressed data
    /// - Returns: Decompressed data
    /// - Throws: CompressionError if decompression fails
    func decompress(_ data: Data) throws -> Data
}

// MARK: - Compression Configuration

internal struct CompressionConfig {
    /// Minimum size threshold for compression (1KB)
    /// Payloads smaller than this are returned uncompressed
    static let minimumSizeThreshold = 1024
    
    /// Default compression level (6 - balanced speed/ratio)
    static let compressionLevel: Int32 = 6
    
    /// Maximum time allowed for compression operation
    static let maxCompressionTime: TimeInterval = 0.1
}

// MARK: - Compression Errors

internal enum CompressionError: Error, CustomStringConvertible {
    case belowThreshold(size: Int)
    case compressionFailed(reason: String)
    case decompressionFailed(reason: String)
    case invalidData(reason: String)
    case timeout
    
    var description: String {
        switch self {
        case .belowThreshold(let size):
            return "Payload too small for compression: \(size) bytes"
        case .compressionFailed(let reason):
            return "Compression failed: \(reason)"
        case .decompressionFailed(let reason):
            return "Decompression failed: \(reason)"
        case .invalidData(let reason):
            return "Invalid data: \(reason)"
        case .timeout:
            return "Compression timeout exceeded"
        }
    }
}

// MARK: - Platform-Specific Implementations

#if canImport(Foundation) && !os(Linux)

// MARK: - Apple Platform Compressor

internal struct AppleCompressor: DataCompressor {
    func compress(_ data: Data) throws -> Data {
        // Check minimum size threshold
        guard data.count >= CompressionConfig.minimumSizeThreshold else {
            throw CompressionError.belowThreshold(size: data.count)
        }
        
        // Use NSData compression with zlib (produces gzip format)
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else {
            throw CompressionError.compressionFailed(reason: "NSData compression failed")
        }
        
        // Verify gzip magic bytes
        guard compressed.count >= 2 else {
            throw CompressionError.compressionFailed(reason: "Compressed data too small")
        }
        
        let magicBytes = compressed.prefix(2)
        guard magicBytes[magicBytes.startIndex] == 0x1f && 
              magicBytes[magicBytes.index(after: magicBytes.startIndex)] == 0x8b else {
            throw CompressionError.compressionFailed(reason: "Invalid gzip header")
        }
        
        return compressed
    }
    
    func decompress(_ data: Data) throws -> Data {
        guard let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data else {
            throw CompressionError.decompressionFailed(reason: "NSData decompression failed")
        }
        return decompressed
    }
}

#elseif os(Linux)

// Note: zlib is available as a system library on Linux
// No Package.swift changes needed - Swift automatically links system libraries
import zlib

// MARK: - Linux zlib Compressor

internal struct ZlibCompressor: DataCompressor {
    
    func compress(_ data: Data) throws -> Data {
        // Check minimum size threshold
        guard data.count >= CompressionConfig.minimumSizeThreshold else {
            throw CompressionError.belowThreshold(size: data.count)
        }
        
        return try data.withUnsafeBytes { (inputPtr: UnsafeRawBufferPointer) -> Data in
            guard let inputBaseAddress = inputPtr.baseAddress else {
                throw CompressionError.invalidData(reason: "Invalid input buffer")
            }
            
            // Allocate output buffer (worst case is input size + headers/footers)
            // zlib recommends input_size + (input_size / 1000) + 12 + 8 for gzip
            let outputSize = data.count + (data.count / 1000) + 20
            var outputData = Data(count: outputSize)
            
            let compressedSize = try outputData.withUnsafeMutableBytes { (outputPtr: UnsafeMutableRawBufferPointer) -> Int in
                guard let outputBaseAddress = outputPtr.baseAddress else {
                    throw CompressionError.compressionFailed(reason: "Invalid output buffer")
                }
                
                var stream = z_stream()
                // Note: zlib requires mutable pointer but doesn't modify input
                // Using mutating cast is safe here as zlib treats input as const
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBaseAddress.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(data.count)
                stream.next_out = outputBaseAddress.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(outputSize)
                
                // Initialize for gzip format
                // windowBits = 15 (max) + 16 (gzip format) = 31
                let windowBits: Int32 = 15 + 16
                let ret = deflateInit2_(
                    &stream,
                    CompressionConfig.compressionLevel,
                    Z_DEFLATED,
                    windowBits,
                    8, // memLevel (default)
                    Z_DEFAULT_STRATEGY,
                    ZLIB_VERSION,
                    Int32(MemoryLayout<z_stream>.size)
                )
                
                guard ret == Z_OK else {
                    throw CompressionError.compressionFailed(reason: "deflateInit2 failed: \(ret)")
                }
                
                defer {
                    deflateEnd(&stream)
                }
                
                // Perform compression in one shot
                let deflateRet = deflate(&stream, Z_FINISH)
                
                guard deflateRet == Z_STREAM_END else {
                    let reason = zlibErrorString(deflateRet)
                    throw CompressionError.compressionFailed(reason: "deflate failed: \(reason)")
                }
                
                return Int(stream.total_out)
            }
            
            // Resize to actual compressed size
            outputData.count = compressedSize
            
            // Verify gzip magic bytes
            guard outputData.count >= 2 else {
                throw CompressionError.compressionFailed(reason: "Compressed data too small")
            }
            
            guard outputData[0] == 0x1f && outputData[1] == 0x8b else {
                throw CompressionError.compressionFailed(reason: "Invalid gzip header")
            }
            
            return outputData
        }
    }
    
    func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw CompressionError.invalidData(reason: "Cannot decompress empty data")
        }
        
        // Verify gzip header
        guard data.count >= 2 else {
            throw CompressionError.invalidData(reason: "Data too small to be gzip")
        }
        
        guard data[0] == 0x1f && data[1] == 0x8b else {
            throw CompressionError.invalidData(reason: "Not a gzip file")
        }
        
        return try data.withUnsafeBytes { (inputPtr: UnsafeRawBufferPointer) -> Data in
            guard let inputBaseAddress = inputPtr.baseAddress else {
                throw CompressionError.invalidData(reason: "Invalid input buffer")
            }
            
            // Initial output buffer size (4x input is usually enough)
            var outputSize = data.count * 4
            var outputData = Data(count: outputSize)
            var totalOutput = 0
            
            var stream = z_stream()
            // Note: zlib requires mutable pointer but doesn't modify input
            // Using mutating cast is safe here as zlib treats input as const
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBaseAddress.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)
            
            // Initialize for gzip format
            let windowBits: Int32 = 15 + 16
            let ret = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            
            guard ret == Z_OK else {
                throw CompressionError.decompressionFailed(reason: "inflateInit2 failed: \(ret)")
            }
            
            defer {
                inflateEnd(&stream)
            }
            
            // Decompress in chunks, resizing output as needed
            repeat {
                if totalOutput == outputSize {
                    // Need more space
                    outputSize *= 2
                    outputData.count = outputSize
                }
                
                let decompressedSize = try outputData.withUnsafeMutableBytes { (outputPtr: UnsafeMutableRawBufferPointer) -> Int in
                    guard let outputBaseAddress = outputPtr.baseAddress else {
                        throw CompressionError.decompressionFailed(reason: "Invalid output buffer")
                    }
                    
                    stream.next_out = outputBaseAddress.advanced(by: totalOutput).assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(outputSize - totalOutput)
                    
                    let inflateRet = inflate(&stream, Z_NO_FLUSH)
                    
                    if inflateRet != Z_OK && inflateRet != Z_STREAM_END {
                        let reason = zlibErrorString(inflateRet)
                        throw CompressionError.decompressionFailed(reason: "inflate failed: \(reason)")
                    }
                    
                    return Int(stream.total_out) - totalOutput
                }
                
                totalOutput += decompressedSize
                
            } while stream.avail_in > 0
            
            // Resize to actual decompressed size
            outputData.count = totalOutput
            return outputData
        }
    }
    
    private func zlibErrorString(_ code: Int32) -> String {
        switch code {
        case Z_ERRNO:
            return "Z_ERRNO"
        case Z_STREAM_ERROR:
            return "Z_STREAM_ERROR"
        case Z_DATA_ERROR:
            return "Z_DATA_ERROR"
        case Z_MEM_ERROR:
            return "Z_MEM_ERROR"
        case Z_BUF_ERROR:
            return "Z_BUF_ERROR"
        case Z_VERSION_ERROR:
            return "Z_VERSION_ERROR"
        default:
            return "Unknown error: \(code)"
        }
    }
}

#else

// MARK: - Fallback No-Op Compressor

internal struct NoOpCompressor: DataCompressor {
    func compress(_ data: Data) throws -> Data {
        // Return data as-is when compression not available
        return data
    }
    
    func decompress(_ data: Data) throws -> Data {
        // Return data as-is when decompression not available
        return data
    }
}

#endif

// MARK: - Factory

internal struct CompressionUtility {
    static func createCompressor() -> DataCompressor {
        #if canImport(Foundation) && !os(Linux)
        return AppleCompressor()
        #elseif os(Linux)
        return ZlibCompressor()
        #else
        return NoOpCompressor()
        #endif
    }
}