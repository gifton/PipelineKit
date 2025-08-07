import XCTest
import Foundation
@testable import PipelineKitCore

final class CompressionMiddlewareTests: XCTestCase {
    
    // MARK: - Test Types
    
    struct CompressibleTestCommand: Command, CompressibleCommand {
        typealias Result = String
        
        var payload: Data
        var contentType: String?
        var isCompressed = false
        var compressionAlgorithm: CompressionMiddleware.CompressionAlgorithm?
        
        func execute() async throws -> String {
            "Payload size: \(payload.count), compressed: \(isCompressed)"
        }
        
        func getCompressiblePayload() -> Data {
            payload
        }
        
        mutating func setCompressedPayload(_ data: Data, algorithm: CompressionMiddleware.CompressionAlgorithm) {
            self.payload = data
            self.isCompressed = true
            self.compressionAlgorithm = algorithm
        }
    }
    
    struct CompressibleStringResult: CompressibleResult {
        var value: String
        var contentType: String? = "text/plain"
        var isCompressed = false
        
        func getCompressiblePayload() -> Data {
            Data(value.utf8)
        }
        
        mutating func setCompressedPayload(_ data: Data, algorithm: CompressionMiddleware.CompressionAlgorithm) {
            self.value = "<compressed:\(data.count)>"
            self.isCompressed = true
        }
    }
    
    struct NonCompressibleCommand: Command {
        typealias Result = String
        
        func execute() async throws -> String {
            "Non-compressible"
        }
    }
    
    // MARK: - Tests
    
    func testCompressionWithLargePayload() async throws {
        // Given
        let largeData = Data(repeating: 65, count: 2048) // 2KB of 'A's
        let middleware = CompressionMiddleware(
            algorithm: .zlib,
            compressionThreshold: 1024
        )
        
        var command = CompressibleTestCommand(
            payload: largeData,
            contentType: "text/plain"
        )
        
        let context = CommandContext()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, ctx in
            // Verify command was compressed
            XCTAssertTrue((cmd as! CompressibleTestCommand).isCompressed)
            XCTAssertLessThan((cmd as! CompressibleTestCommand).payload.count, largeData.count)
            return try await cmd.execute()
        }
        
        // Then
        XCTAssertTrue(command.payload.count == largeData.count) // Original unchanged
        XCTAssertEqual(context.metadata["compressionApplied"] as? Bool, true)
        XCTAssertEqual(context.metadata["compressionAlgorithm"] as? String, "zlib")
        XCTAssertNotNil(context.metadata["originalSize"])
        XCTAssertNotNil(context.metadata["compressedSize"])
    }
    
    func testNoCompressionForSmallPayload() async throws {
        // Given
        let smallData = Data("Hello".utf8) // < 1KB
        let middleware = CompressionMiddleware(
            algorithm: .zlib,
            compressionThreshold: 1024
        )
        
        let command = CompressibleTestCommand(
            payload: smallData,
            contentType: "text/plain"
        )
        
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            // Verify command was NOT compressed
            XCTAssertFalse((cmd as! CompressibleTestCommand).isCompressed)
            return try await cmd.execute()
        }
        
        // Then
        XCTAssertNil(context.metadata["compressionApplied"])
    }
    
    func testCompressionAlgorithms() async throws {
        let algorithms: [CompressionMiddleware.CompressionAlgorithm] = [.zlib, .lz4, .lzfse, .lzma]
        let largeData = Data(repeating: 65, count: 2048)
        
        for algorithm in algorithms {
            // Given
            let middleware = CompressionMiddleware(
                algorithm: algorithm,
                compressionThreshold: 1024
            )
            
            let command = CompressibleTestCommand(
                payload: largeData,
                contentType: "text/plain"
            )
            
            let context = CommandContext()
            
            // When
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                let compressedCommand = cmd as! CompressibleTestCommand
                XCTAssertTrue(compressedCommand.isCompressed)
                XCTAssertEqual(compressedCommand.compressionAlgorithm, algorithm)
                return try await cmd.execute()
            }
            
            // Then
            XCTAssertEqual(context.metadata["compressionAlgorithm"] as? String, algorithm.rawValue)
        }
    }
    
    func testExcludedContentTypes() async throws {
        // Given
        let largeData = Data(repeating: 255, count: 2048)
        let middleware = CompressionMiddleware(
            configuration: CompressionMiddleware.Configuration(
                compressionThreshold: 1024,
                excludedContentTypes: ["image/jpeg"]
            )
        )
        
        let command = CompressibleTestCommand(
            payload: largeData,
            contentType: "image/jpeg"
        )
        
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            // Verify command was NOT compressed due to excluded content type
            XCTAssertFalse((cmd as! CompressibleTestCommand).isCompressed)
            return try await cmd.execute()
        }
        
        // Then
        XCTAssertNil(context.metadata["compressionApplied"])
    }
    
    func testAllowedContentTypes() async throws {
        // Given
        let largeData = Data(repeating: 123, count: 2048)
        let middleware = CompressionMiddleware(
            configuration: CompressionMiddleware.Configuration(
                compressionThreshold: 1024,
                allowedContentTypes: ["application/json"]
            )
        )
        
        // Test allowed type
        var jsonCommand = CompressibleTestCommand(
            payload: largeData,
            contentType: "application/json"
        )
        
        let context1 = CommandContext()
        
        _ = try await middleware.execute(jsonCommand, context: context1) { cmd, ctx in
            XCTAssertTrue((cmd as! CompressibleTestCommand).isCompressed)
            return try await cmd.execute()
        }
        
        // Test non-allowed type
        let textCommand = CompressibleTestCommand(
            payload: largeData,
            contentType: "text/plain"
        )
        
        let context2 = CommandContext()
        
        _ = try await middleware.execute(textCommand, context: context2) { cmd, ctx in
            XCTAssertFalse((cmd as! CompressibleTestCommand).isCompressed)
            return try await cmd.execute()
        }
    }
    
    func testCompressionLevels() async throws {
        let levels: [CompressionMiddleware.CompressionLevel] = [
            .fastest,
            .balanced,
            .best,
            .custom(7)
        ]
        
        let largeData = Data(repeating: 65, count: 4096)
        
        for level in levels {
            let middleware = CompressionMiddleware(
                configuration: CompressionMiddleware.Configuration(
                    algorithm: .zlib,
                    compressionThreshold: 1024,
                    compressionLevel: level
                )
            )
            
            let command = CompressibleTestCommand(payload: largeData)
            let context = CommandContext()
            
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                XCTAssertTrue((cmd as! CompressibleTestCommand).isCompressed)
                return try await cmd.execute()
            }
            
            XCTAssertNotNil(context.metadata["compressedSize"])
        }
    }
    
    func testNonCompressibleCommand() async throws {
        // Given
        let middleware = CompressionMiddleware()
        let command = NonCompressibleCommand()
        let context = CommandContext()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then
        XCTAssertEqual(result, "Non-compressible")
        XCTAssertNil(context.metadata["compressionApplied"])
    }
    
    func testMetricsEmission() async throws {
        // Given
        let largeData = Data(repeating: 65, count: 2048)
        let middleware = CompressionMiddleware(
            configuration: CompressionMiddleware.Configuration(
                compressionThreshold: 1024,
                emitMetrics: true
            )
        )
        
        let command = CompressibleTestCommand(payload: largeData)
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then
        XCTAssertNotNil(context.metrics["compression.originalSize"])
        XCTAssertNotNil(context.metrics["compression.compressedSize"])
        XCTAssertNotNil(context.metrics["compression.ratio"])
        XCTAssertNotNil(context.metrics["compression.duration"])
        
        let ratio = context.metrics["compression.ratio"] as! Double
        XCTAssertGreaterThan(ratio, 0)
        XCTAssertLessThan(ratio, 1)
    }
    
    func testConvenienceInitializers() async throws {
        // Test JSON optimized middleware
        let jsonMiddleware = CompressionMiddleware.json()
        XCTAssertNotNil(jsonMiddleware)
        
        // Test text optimized middleware
        let textMiddleware = CompressionMiddleware.text()
        XCTAssertNotNil(textMiddleware)
        
        // Test binary optimized middleware
        let binaryMiddleware = CompressionMiddleware.binary()
        XCTAssertNotNil(binaryMiddleware)
    }
    
    func testDecompression() async throws {
        // Given
        let originalData = Data("Hello, World! ".utf8) + Data(repeating: 65, count: 1024)
        let middleware = CompressionMiddleware(algorithm: .zlib)
        
        let command = CompressibleTestCommand(payload: originalData)
        let context = CommandContext()
        
        var compressedData: Data?
        
        // When - compress
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            let compressedCommand = cmd as! CompressibleTestCommand
            compressedData = compressedCommand.payload
            return try await cmd.execute()
        }
        
        // Then - decompress
        XCTAssertNotNil(compressedData)
        let decompressed = try await CompressionMiddleware.decompress(
            compressedData!,
            algorithm: .zlib
        )
        
        XCTAssertEqual(decompressed, originalData)
    }
}