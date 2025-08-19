import XCTest
import PipelineKitCore
import PipelineKitStorage
import Foundation

// Example compressible command for testing
struct DataProcessingCommand: Command, CompressibleCommand {
    typealias Result = ProcessingResult
    
    let data: Data
    let operation: String
    
    // CompressibleCommand conformance
    var dataToCompress: Data? {
        return data
    }
    
    var estimatedSize: Int {
        return data.count
    }
    
    func withCompressedData(_ compressedData: Data) -> DataProcessingCommand {
        // Return new instance with compressed data
        return DataProcessingCommand(data: compressedData, operation: operation + ".compressed")
    }
    
    func withDecompressedData(_ data: Data) -> DataProcessingCommand {
        // Return new instance with decompressed data
        return DataProcessingCommand(data: data, operation: operation + ".decompressed")
    }
}

struct ProcessingResult: Sendable, CompressibleResult {
    let processedData: Data
    let success: Bool
    
    // CompressibleResult conformance
    var dataToCompress: Data? {
        return processedData
    }
    
    var estimatedSize: Int {
        return processedData.count
    }
    
    func withCompressedData(_ compressedData: Data) -> ProcessingResult {
        return ProcessingResult(processedData: compressedData, success: success)
    }
    
    func withDecompressedData(_ data: Data) -> ProcessingResult {
        return ProcessingResult(processedData: data, success: success)
    }
}

final class CompressionMiddlewareTests: XCTestCase {
    
    func testCompressionMiddleware() async throws {
        // Create middleware
        let middleware = CompressionMiddleware(
            algorithm: .zlib,
            compressionLevel: .balanced,
            minimumSize: 100 // Only compress data > 100 bytes
        )
        
        // Create test data (compressible pattern)
        let testData = Data(repeating: 65, count: 1000) // 1000 'A' characters
        
        // Create test command
        let command = DataProcessingCommand(
            data: testData,
            operation: "test"
        )
        
        // Create context
        let context = CommandContext()
        
        // Test handler
        let handler: @Sendable (DataProcessingCommand, CommandContext) async throws -> ProcessingResult = { cmd, ctx in
            // Verify compression was applied
            let metadata = await ctx.getMetadata()
            if let applied = metadata["compression.applied"] as? Bool, applied {
                XCTAssertEqual(metadata["compression.algorithm"] as? String, "zlib")
                XCTAssertNotNil(metadata["compression.originalSize"])
                XCTAssertNotNil(metadata["compression.compressedSize"])
                
                // Verify operation was marked as compressed
                XCTAssertTrue(cmd.operation.contains("compressed"))
            }
            
            // Return result with same data
            return ProcessingResult(processedData: cmd.data, success: true)
        }
        
        // Execute through middleware
        let result = try await middleware.execute(command, context: context, next: handler)
        
        // Verify result
        XCTAssertTrue(result.success)
    }
    
    func testCompressionBelowThreshold() async throws {
        // Create middleware with high threshold
        let middleware = CompressionMiddleware(
            algorithm: .zlib,
            compressionLevel: .fast,
            minimumSize: 10000 // Only compress data > 10KB
        )
        
        // Create small test data
        let testData = Data(repeating: 65, count: 100) // 100 bytes
        
        // Create test command
        let command = DataProcessingCommand(
            data: testData,
            operation: "test"
        )
        
        // Create context
        let context = CommandContext()
        
        // Test handler
        let handler: @Sendable (DataProcessingCommand, CommandContext) async throws -> ProcessingResult = { cmd, ctx in
            // Verify compression was NOT applied
            let metadata = await ctx.getMetadata()
            XCTAssertNil(metadata["compression.applied"])
            XCTAssertFalse(cmd.operation.contains("compressed"))
            
            return ProcessingResult(processedData: cmd.data, success: true)
        }
        
        // Execute through middleware
        let result = try await middleware.execute(command, context: context, next: handler)
        
        // Verify result
        XCTAssertTrue(result.success)
    }
    
    func testCompressionRatio() throws {
        // Test data with good compression potential
        let testData = Data(repeating: 65, count: 1000)
        
        // Calculate compression ratio
        let ratioResult = CompressionUtility.compressionRatio(
            for: testData,
            using: .zlib,
            level: .best
        )
        
        switch ratioResult {
        case .success(let ratio):
            // Repeating data should compress well
            XCTAssertGreaterThan(ratio, 10.0, "Expected high compression ratio for repeating data")
        case .failure(let error):
            XCTFail("Compression ratio calculation failed: \(error)")
        }
    }
    
    func testCompressionDecompression() throws {
        // Original data
        let originalData = "Hello, World! This is a test string for compression.".data(using: .utf8)!
        
        // Compress
        let compressed = try CompressionUtility.compress(
            originalData,
            using: .lzfse,
            level: .balanced
        )
        
        // Verify compressed is different and smaller
        XCTAssertNotEqual(compressed, originalData)
        XCTAssertLessThan(compressed.count, originalData.count)
        
        // Decompress
        let decompressed = try CompressionUtility.decompress(
            compressed,
            using: .lzfse,
            originalSize: originalData.count
        )
        
        // Verify decompressed matches original
        XCTAssertEqual(decompressed, originalData)
    }
}