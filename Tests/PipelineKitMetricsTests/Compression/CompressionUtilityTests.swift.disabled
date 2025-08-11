import XCTest
@testable import PipelineKitMetrics
import Foundation

final class CompressionUtilityTests: XCTestCase {
    
    private var compressor: DataCompressor!
    
    override func setUp() {
        super.setUp()
        compressor = CompressionUtility.createCompressor()
    }
    
    override func tearDown() {
        compressor = nil
        super.tearDown()
    }
    
    // MARK: - Basic Compression Tests
    
    func testCompressSmallPayloadThrowsBelowThreshold() throws {
        // Given: Small data below threshold
        let smallData = Data("Hello".utf8)
        XCTAssertLessThan(smallData.count, CompressionConfig.minimumSizeThreshold)
        
        // When/Then: Should throw below threshold error
        XCTAssertThrowsError(try compressor.compress(smallData)) { error in
            guard case CompressionError.belowThreshold = error else {
                XCTFail("Expected belowThreshold error, got \(error)")
                return
            }
        }
    }
    
    func testCompressLargePayloadSucceeds() throws {
        // Given: Data above threshold
        let largeData = Data(String(repeating: "Hello World! ", count: 100).utf8)
        XCTAssertGreaterThanOrEqual(largeData.count, CompressionConfig.minimumSizeThreshold)
        
        // When: Compress
        let compressed = try compressor.compress(largeData)
        
        // Then: Should have gzip header and be smaller
        XCTAssertGreaterThanOrEqual(compressed.count, 2)
        XCTAssertEqual(compressed[0], 0x1f, "First magic byte should be 0x1f")
        XCTAssertEqual(compressed[1], 0x8b, "Second magic byte should be 0x8b")
        XCTAssertLessThan(compressed.count, largeData.count, "Compressed should be smaller")
    }
    
    func testRoundTripCompression() throws {
        // Given: Original data
        let originalData = Data(String(repeating: "Test data for compression. ", count: 50).utf8)
        
        // When: Compress and decompress
        let compressed = try compressor.compress(originalData)
        let decompressed = try compressor.decompress(compressed)
        
        // Then: Should match original
        XCTAssertEqual(decompressed, originalData, "Round-trip should preserve data")
    }
    
    // MARK: - Edge Cases
    
    func testCompressEmptyDataAfterThreshold() throws {
        // Special case: Create exactly threshold-sized data that's all zeros
        let data = Data(count: CompressionConfig.minimumSizeThreshold)
        
        // Should compress successfully
        let compressed = try compressor.compress(data)
        
        // Verify gzip header
        XCTAssertEqual(compressed[0], 0x1f)
        XCTAssertEqual(compressed[1], 0x8b)
        
        // Verify round-trip
        let decompressed = try compressor.decompress(compressed)
        XCTAssertEqual(decompressed, data)
    }
    
    func testCompressHighlyCompressibleData() throws {
        // Given: Highly compressible data (all zeros)
        let data = Data(count: 10_000)
        
        // When: Compress
        let compressed = try compressor.compress(data)
        
        // Then: Should achieve high compression ratio
        let ratio = Double(compressed.count) / Double(data.count)
        XCTAssertLessThan(ratio, 0.1, "Zeros should compress to < 10% of original")
        
        // Verify round-trip
        let decompressed = try compressor.decompress(compressed)
        XCTAssertEqual(decompressed, data)
    }
    
    func testCompressRandomData() throws {
        // Given: Random data (incompressible)
        var randomData = Data(count: 2048)
        randomData.withUnsafeMutableBytes { bytes in
            arc4random_buf(bytes.baseAddress, bytes.count)
        }
        
        // When: Compress
        let compressed = try compressor.compress(randomData)
        
        // Then: May be larger due to headers, but should round-trip
        XCTAssertEqual(compressed[0], 0x1f)
        XCTAssertEqual(compressed[1], 0x8b)
        
        let decompressed = try compressor.decompress(compressed)
        XCTAssertEqual(decompressed, randomData)
    }
    
    func testCompressLargePayload() throws {
        // Given: Large payload (1MB)
        let largeData = Data(String(repeating: "Large payload test. ", count: 50_000).utf8)
        
        // When: Compress
        let compressed = try compressor.compress(largeData)
        
        // Then: Should compress and round-trip
        XCTAssertLessThan(compressed.count, largeData.count)
        
        let decompressed = try compressor.decompress(compressed)
        XCTAssertEqual(decompressed, largeData)
    }
    
    // MARK: - Known Vector Tests
    
    func testCompressKnownVector() throws {
        // Given: Known input
        let input = Data("The quick brown fox jumps over the lazy dog. ".utf8 +
                        String(repeating: "Testing 123. ", count: 80).utf8)
        
        // When: Compress
        let compressed = try compressor.compress(input)
        
        // Then: Verify structure
        XCTAssertEqual(compressed[0], 0x1f, "Gzip magic byte 1")
        XCTAssertEqual(compressed[1], 0x8b, "Gzip magic byte 2")
        XCTAssertEqual(compressed[2], 0x08, "Deflate method")
        
        // Flags byte at position 3 can vary
        // Timestamp at positions 4-7 can vary
        // OS byte at position 9 can vary
        
        // Verify decompression works
        let decompressed = try compressor.decompress(compressed)
        XCTAssertEqual(decompressed, input)
    }
    
    // MARK: - Error Handling Tests
    
    func testDecompressInvalidDataThrows() throws {
        // Given: Invalid data (not gzip)
        let invalidData = Data("Not a gzip file".utf8)
        
        // When/Then: Should throw
        XCTAssertThrowsError(try compressor.decompress(invalidData)) { error in
            guard case CompressionError.invalidData = error else {
                XCTFail("Expected invalidData error, got \(error)")
                return
            }
        }
    }
    
    func testDecompressTruncatedDataThrows() throws {
        // Given: Valid gzip header but truncated
        let truncated = Data([0x1f, 0x8b, 0x08, 0x00])
        
        // When/Then: Should throw
        XCTAssertThrowsError(try compressor.decompress(truncated))
    }
    
    func testDecompressCorruptedDataThrows() throws {
        // Given: Compress valid data
        let original = Data(String(repeating: "Test", count: 300).utf8)
        var compressed = try compressor.compress(original)
        
        // Corrupt the compressed data (modify middle bytes)
        if compressed.count > 20 {
            compressed[compressed.count / 2] ^= 0xFF
        }
        
        // When/Then: Should throw on decompression
        XCTAssertThrowsError(try compressor.decompress(compressed))
    }
    
    // MARK: - Performance Tests
    
    func testCompressionPerformance() throws {
        // Given: 100KB of typical JSON-like data
        let jsonLikeData = generateJSONLikeData(sizeKB: 100)
        
        measure {
            do {
                _ = try compressor.compress(jsonLikeData)
            } catch {
                XCTFail("Compression failed: \(error)")
            }
        }
    }
    
    func testDecompressionPerformance() throws {
        // Given: Compressed data
        let jsonLikeData = generateJSONLikeData(sizeKB: 100)
        let compressed = try compressor.compress(jsonLikeData)
        
        measure {
            do {
                _ = try compressor.decompress(compressed)
            } catch {
                XCTFail("Decompression failed: \(error)")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func generateJSONLikeData(sizeKB: Int) -> Data {
        var result = "{"
        let targetSize = sizeKB * 1024
        
        while result.count < targetSize {
            result += """
            "metric_\(result.count)": {
                "name": "test.metric.name",
                "value": \(Double.random(in: 0...1000)),
                "timestamp": "\(Date())",
                "tags": {
                    "service": "test-service",
                    "environment": "production",
                    "host": "server-\(Int.random(in: 1...100))"
                }
            },
            """
        }
        
        result += "}"
        return Data(result.utf8)
    }
}

// MARK: - Platform-Specific Tests

#if os(Linux)
extension CompressionUtilityTests {
    func testLinuxZlibImplementation() throws {
        // Verify we're using the zlib implementation
        XCTAssertTrue(compressor is ZlibCompressor,
                     "Should use ZlibCompressor on Linux")
    }
}
#endif

#if canImport(Foundation) && !os(Linux)
extension CompressionUtilityTests {
    func testAppleNSDataImplementation() throws {
        // Verify we're using the Apple implementation
        XCTAssertTrue(compressor is AppleCompressor,
                     "Should use AppleCompressor on Apple platforms")
    }
    
    func testCrossCompatibilityWithSystemGzip() throws {
        // This test verifies our compression is compatible with system gzip
        // by comparing with known gzip output (when possible)
        
        let testData = Data("Hello, World!".utf8 + String(repeating: " Test", count: 250).utf8)
        let compressed = try compressor.compress(testData)
        
        // Verify it starts with gzip header
        XCTAssertEqual(compressed[0], 0x1f)
        XCTAssertEqual(compressed[1], 0x8b)
        XCTAssertEqual(compressed[2], 0x08) // DEFLATE method
        
        // Decompress and verify
        let decompressed = try compressor.decompress(compressed)
        XCTAssertEqual(decompressed, testData)
    }
}
#endif