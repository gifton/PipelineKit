#if canImport(Compression)
import Compression
import Foundation
@testable import PipelineKitCache
import XCTest

final class CompressionCompletionContractTests: XCTestCase {
    // Exercise every enum case: zlib/gzip currently use raw DEFLATE,
    // lzfse/brotli use LZFSE, and lz4 uses Apple's framed LZ4.
    // The aliases and ignored compression level remain the separate SCP-08 issue.
    func testDecodeCompletesOrThrowsForEverySizeHintAndLimit() throws {
        let count = 100_000
        let fixtures = [
            ("compressible", Data(repeating: 65, count: count)),
            ("incompressible", makeIncompressibleData(count: count))
        ]
        let hints: [Int?] = [nil, 17, count - 1, count, count + 1]
        for algorithm in CompressionAlgorithm.allCases {
            for (name, original) in fixtures {
                let compressed = try CompressionUtility.compress(original, using: algorithm)
                if name == "incompressible" {
                    XCTAssertGreaterThanOrEqual(compressed.count, original.count, "\(algorithm)")
                }
                for hint in hints {
                    for limit in [count - 1, count, count + 1] {
                        let label = "\(algorithm), \(name), hint \(String(describing: hint)), limit \(limit)"
                        if limit < count {
                            assertOutputLimitError(label) {
                                try CompressionUtility.decompress(
                                    compressed, using: algorithm, originalSize: hint, maxOutputSize: limit
                                )
                            }
                        } else {
                            let decoded = try CompressionUtility.decompress(
                                compressed, using: algorithm, originalSize: hint, maxOutputSize: limit
                            )
                            XCTAssertEqual(decoded, original, label)
                        }
                    }
                }
                // Exercise an actually omitted hint as well as an explicit nil.
                XCTAssertEqual(try CompressionUtility.decompress(
                    compressed, using: algorithm, maxOutputSize: count
                ), original)
            }
        }
    }

    func testSmallPayloadRoundTrips() throws {
        for algorithm in CompressionAlgorithm.allCases {
            for count in [0, 1, 99, 100, 101] {
                for original in [Data(repeating: 65, count: count), makeIncompressibleData(count: count)] {
                    let compressed = try CompressionUtility.compress(original, using: algorithm)
                    for limit in [max(1, count), count + 1] {
                        let decoded = try CompressionUtility.decompress(
                            compressed, using: algorithm, originalSize: 0, maxOutputSize: limit
                        )
                        XCTAssertEqual(decoded, original, "\(algorithm), size \(count), limit \(limit)")
                    }
                    if count > 1 {
                        assertOutputLimitError("\(algorithm), size \(count)") {
                            try CompressionUtility.decompress(compressed, using: algorithm, maxOutputSize: count - 1)
                        }
                    }
                }
            }
        }
    }

    func testExactLimitAtWorkingBufferBoundary() throws {
        for algorithm in CompressionAlgorithm.allCases {
            for count in [65_535, 65_536, 65_537] {
                let original = makeIncompressibleData(count: count)
                let compressed = try CompressionUtility.compress(original, using: algorithm)
                XCTAssertEqual(try CompressionUtility.decompress(
                    compressed, using: algorithm, originalSize: 17, maxOutputSize: count
                ), original, "\(algorithm), size \(count)")
                assertOutputLimitError("\(algorithm), size \(count)") {
                    try CompressionUtility.decompress(compressed, using: algorithm, maxOutputSize: count - 1)
                }
            }
        }
    }

    func testInvalidArgumentsAreRejectedBeforeEmptyInputCompatibility() throws {
        for algorithm in CompressionAlgorithm.allCases {
            let compressed = try CompressionUtility.compress(Data(repeating: 65, count: 101), using: algorithm)
            for data in [Data(), compressed] {
                for hint in [-1, Int.min] {
                    assertDecodeError("negative hint \(hint), \(algorithm)") {
                        try CompressionUtility.decompress(data, using: algorithm, originalSize: hint, maxOutputSize: 101)
                    }
                }
                for limit in [0, -1, Int.min] {
                    assertDecodeError("nonpositive limit \(limit), \(algorithm)") {
                        try CompressionUtility.decompress(data, using: algorithm, maxOutputSize: limit)
                    }
                }
            }
            XCTAssertEqual(try CompressionUtility.decompress(Data(), using: algorithm, maxOutputSize: 1), Data())
        }
    }

    func testHugeHintsAndLimitsDoNotRequireHugeAllocation() throws {
        let original = Data(repeating: 65, count: 101)
        for algorithm in CompressionAlgorithm.allCases {
            let compressed = try CompressionUtility.compress(original, using: algorithm)
            for hint: Int? in [nil, 0, Int.max] {
                for limit in [101, Int.max] {
                    XCTAssertEqual(try CompressionUtility.decompress(
                        compressed, using: algorithm, originalSize: hint, maxOutputSize: limit
                    ), original, "\(algorithm), hint \(String(describing: hint)), limit \(limit)")
                }
            }
            XCTAssertEqual(try CompressionUtility.decompress(
                Data(), using: algorithm, originalSize: Int.max, maxOutputSize: 1
            ), Data())
        }
    }

    func testTruncatedCorruptAndStalledStreamsNeverReturnPrefixes() throws {
        let original = Data(repeating: 65, count: 100_000)
        for algorithm in CompressionAlgorithm.allCases {
            let compressed = try CompressionUtility.compress(original, using: algorithm)
            let incompleteHeader = Data(compressed.prefix(1))
            XCTAssertTrue(try stallsWithoutFinalize(incompleteHeader, algorithm: algorithm), "\(algorithm)")
            let malformed = [
                incompleteHeader,
                Data(compressed.prefix(compressed.count / 2)),
                Data(compressed.dropLast()),
                Data(repeating: 0xFF, count: 32),
                Data(repeating: 0xFF, count: 4) + compressed.dropFirst(4)
            ]
            for (index, data) in malformed.enumerated() {
                for hint: Int? in [nil, 17, original.count] {
                    assertDecodeError("\(algorithm), malformed \(index), hint \(String(describing: hint))") {
                        try CompressionUtility.decompress(
                            data, using: algorithm, originalSize: hint, maxOutputSize: original.count + 1
                        )
                    }
                }
            }
        }
    }

    func testTrailingAndConcatenatedStreamsAreRejected() throws {
        for algorithm in CompressionAlgorithm.allCases {
            for count in [1, 100, 100_000] {
                for original in [Data(repeating: 65, count: count), makeIncompressibleData(count: count)] {
                    let compressed = try CompressionUtility.compress(original, using: algorithm)
                    for trailing in [Data([0]), Data([0xFF, 0x13]), compressed] {
                        for limit in [original.count, original.count * 2] {
                            assertDecodeError("\(algorithm), size \(count), trailing \(trailing.count) bytes, limit \(limit)") {
                                try CompressionUtility.decompress(
                                    compressed + trailing, using: algorithm, maxOutputSize: limit
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    func testEncodedEmptyStreamRequiresCompletionAndRejectsTrailingInput() throws {
        for algorithm in CompressionAlgorithm.allCases {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            defer { destination.deallocate() }
            var unusedSource: UInt8 = 0
            let count = compression_encode_buffer(destination, 64, &unusedSource, 0, nil, algorithm.foundationAlgorithm)
            XCTAssertGreaterThan(count, 0, "\(algorithm)")
            let compressed = Data(bytes: destination, count: count)
            XCTAssertEqual(try CompressionUtility.decompress(compressed, using: algorithm, maxOutputSize: 1), Data())
            assertDecodeError("\(algorithm), encoded empty stream with trailing byte") {
                try CompressionUtility.decompress(compressed + Data([0]), using: algorithm, maxOutputSize: 1)
            }
            assertDecodeError("\(algorithm), truncated encoded empty stream") {
                try CompressionUtility.decompress(Data(compressed.dropLast()), using: algorithm, maxOutputSize: 1)
            }
        }
    }

    private func assertOutputLimitError(
        _ label: String, file: StaticString = #filePath, line: UInt = #line,
        _ decode: () throws -> Data
    ) {
        XCTAssertThrowsError(try decode(), label, file: file, line: line) { error in
            guard case CompressionError.dataTooLarge = error else {
                return XCTFail("Expected output-limit error, got \(error): \(label)", file: file, line: line)
            }
        }
    }

    private func assertDecodeError(
        _ label: String, file: StaticString = #filePath, line: UInt = #line,
        _ decode: () throws -> Data
    ) {
        XCTAssertThrowsError(try decode(), label, file: file, line: line) { error in
            guard case CompressionError.decompressionFailed = error else {
                return XCTFail("Expected decode error, got \(error): \(label)", file: file, line: line)
            }
        }
    }

    // Independent of CompressionUtility and every codec: deterministic xorshift64* bytes.
    // The 100,000-byte matrix asserts that these bytes do not compress below their input size.
    private func makeIncompressibleData(count: Int) -> Data {
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        return Data((0..<count).map { _ in
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 56)
        })
    }

    // Characterize a real incomplete fixture that can stall if FINALIZE is omitted.
    // The public-API assertion above requires an explicit error for the same fixture.
    private func stallsWithoutFinalize(_ data: Data, algorithm: CompressionAlgorithm) throws -> Bool {
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            let sourcePointer = try XCTUnwrap(source.bindMemory(to: UInt8.self).baseAddress)
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            defer { destination.deallocate() }
            var stream = compression_stream(
                dst_ptr: destination, dst_size: 0, src_ptr: sourcePointer, src_size: 0, state: nil
            )
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm.foundationAlgorithm) == COMPRESSION_STATUS_OK else {
                throw CompressionError.decompressionFailed("Fixture stream initialization failed")
            }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = sourcePointer
            stream.src_size = data.count
            for _ in 0..<4 {
                let before = stream.src_size
                stream.dst_ptr = destination
                stream.dst_size = 64
                guard compression_stream_process(&stream, 0) == COMPRESSION_STATUS_OK else { return false }
                if stream.src_size == before && stream.dst_size == 64 { return true }
            }
            return false
        }
    }
}
#endif
